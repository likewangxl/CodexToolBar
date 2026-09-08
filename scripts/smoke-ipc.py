#!/usr/bin/env python3
"""End-to-end observer tests against a disposable local Codex router fixture."""
import json
import os
from pathlib import Path
import socket
import sqlite3
import struct
import subprocess
import sys
import tempfile
import threading
import time

BINARY = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/CodexTouchBar").resolve()
THREAD = "11111111-2222-4333-8444-555555555555"


def run_case(mode):
    with tempfile.TemporaryDirectory(prefix="codex-touchbar-fixture-") as root:
        home = Path(root)
        (home / "sessions").mkdir()
        (home / "ipc").mkdir(mode=0o700)
        transcript = home / "sessions" / "fixture.jsonl"
        transcript.write_text(json.dumps({"type": "event_msg", "payload": {"type": "task_started"}}) + "\n")
        db = sqlite3.connect(home / "state_5.sqlite")
        db.execute("CREATE TABLE threads (id TEXT, title TEXT, rollout_path TEXT, source TEXT, archived INTEGER, updated_at INTEGER)")
        db.execute("INSERT INTO threads VALUES (?,?,?,?,?,?)", (THREAD, "夹具任务", str(transcript), "vscode", 0, int(time.time())))
        db.commit()
        db.close()
        server = socket.socket(socket.AF_UNIX)
        server.bind(str(home / "ipc" / "ipc.sock"))
        os.chmod(home / "ipc" / "ipc.sock", 0o600)
        server.listen(1)
        allowed = []
        errors = []
        follow_count = [0]

        def worker():
            connection, _ = server.accept()
            connection.settimeout(0.05)
            buffer = b""
            deadline = None
            changed = False

            def send(obj):
                data = json.dumps(obj, ensure_ascii=False).encode()
                frame = struct.pack("<I", len(data)) + data
                # Deliberately split the frame header and payload across writes.
                connection.sendall(frame[:2])
                connection.sendall(frame[2:19])
                connection.sendall(frame[19:])

            def state_change(change):
                send({"type": "broadcast", "method": "thread-stream-state-changed", "version": 12 if mode == "incompatible" else 11,
                      "sourceClientId": "fixture-owner", "params": {"conversationId": THREAD, "hostId": "local", "change": change}})

            def snapshot(recovered=False):
                state_change({"type": "snapshot", "revision": 7 if recovered else 1, "conversationState": {
                    "id": THREAD, "title": "实时夹具任务", "threadRuntimeStatus": {"type": "active", "activeFlags": ["waitingOnApproval"] if recovered else []},
                    "latestTokenUsageInfo": {"last": {"totalTokens": 195727}, "total": {"totalTokens": 9207896}, "modelContextWindow": 258400},
                    "requests": [], "turns": [{"status": "inProgress", "items": [{"type": "agentMessage", "text": "初始回复"}]}]
                }})

            try:
                while True:
                    if deadline and time.monotonic() >= deadline and not changed:
                        changed = True
                        if mode == "disconnect":
                            connection.close()
                            return
                        if mode in ("idle", "incompatible"):
                            continue
                        if mode == "stream":
                            state_change({"type": "patches", "baseRevision": 1, "revision": 2, "patches": [
                                {"op": "add", "path": ["turns", 0, "items", 0, "aggregatedOutput"], "value": "ignored" * 100000}
                            ]})
                        patches = [
                            {"op": "replace", "path": ["turns", 0, "items", 0, "text"], "value": "实时回复 👨‍💻"},
                            {"op": "add", "path": ["turns", 0, "items", 1], "value": {"type": "subAgentActivity", "id": "agent-event", "agentPath": "/root/luna_ui", "agentThreadId": "ui", "kind": "completed"}},
                            {"op": "replace", "path": ["threadRuntimeStatus", "type"], "value": "idle"},
                            {"op": "replace", "path": ["turns", 0, "status"], "value": "completed"},
                        ]
                        state_change({"type": "patches", "baseRevision": 999 if mode == "gap" else 2 if mode == "stream" else 1, "revision": 3, "patches": patches})
                    try:
                        chunk = connection.recv(65536)
                    except socket.timeout:
                        continue
                    if not chunk:
                        return
                    buffer += chunk
                    while len(buffer) >= 4:
                        size = struct.unpack("<I", buffer[:4])[0]
                        if len(buffer) < size + 4:
                            break
                        obj = json.loads(buffer[4:size + 4])
                        buffer = buffer[size + 4:]
                        method = obj.get("method")
                        allowed.append(method)
                        if method == "initialize":
                            send({"type": "response", "method": "initialize", "resultType": "success", "requestId": obj["requestId"], "result": {"clientId": "fixture-observer"}})
                        elif method == "thread-stream-following-changed" and obj["params"]["following"]:
                            follow_count[0] += 1
                            snapshot(mode == "gap" and follow_count[0] > 1)
                            deadline = time.monotonic() + 0.3
            except (BrokenPipeError, ConnectionResetError):
                pass
            except Exception as error:
                errors.append(str(error))
            finally:
                connection.close()

        thread = threading.Thread(target=worker, daemon=True)
        thread.start()
        process = subprocess.run([str(BINARY), "--probe", "--seconds", "4", "--codex-home", root], capture_output=True, text=True, timeout=12)
        thread.join(timeout=1)
        server.close()
        assert process.returncode == 0, process.stderr
        assert not errors, errors
        assert set(allowed) <= {"initialize", "thread-stream-following-changed"}, allowed
        result = json.loads(process.stdout)
        task = result["tasks"][0]
        if mode not in ("disconnect", "incompatible"):
            assert abs(task["ctxPercent"] - 75.7457) < 0.001, task
        if mode == "incompatible":
            assert not task["live"], task
            assert "协议不兼容" in result["connection"], result
        if mode == "idle":
            assert result["uiUpdates"] <= 2, result
            assert task["live"] and task["status"] == "replying", task
        if mode == "stream":
            assert task["status"] == "completed" and task["live"], task
            assert task["replyCharacters"] == 6, task  # Four CJK characters, a space, one emoji grapheme.
            assert task["agentBadges"] == ["Luna ui"], task
        elif mode == "gap":
            assert follow_count[0] >= 2, follow_count
            assert task["status"] == "waiting" and task["live"], task
        elif mode == "disconnect":
            assert not task["live"] and task["status"] == "unknown", task
        print("PASS", mode)


for scenario in ("stream", "gap", "disconnect", "idle", "incompatible"):
    run_case(scenario)
