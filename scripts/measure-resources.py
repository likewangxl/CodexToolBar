#!/usr/bin/env python3
"""Read-only process CPU/RSS sample. Percent is relative to one CPU core."""
import argparse
import json
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("pid", type=int)
parser.add_argument("--seconds", type=int, default=30)
args = parser.parse_args()

def read():
    values = subprocess.check_output(["ps", "-p", str(args.pid), "-o", "time=,rss=,%cpu="], text=True).split()
    parts = values[0].split(":")
    seconds = float(parts[-1]) + int(parts[-2]) * 60
    if len(parts) > 2:
        seconds += int(parts[-3]) * 3600
    return seconds, int(values[1]), float(values[2])

start = read()
time_start = time.monotonic()
samples = []
for _ in range(max(1, args.seconds // 5)):
    time.sleep(5)
    samples.append(read())
elapsed = time.monotonic() - time_start
print(json.dumps({
    "pid": args.pid,
    "durationSeconds": round(elapsed, 2),
    "cpuSeconds": round(samples[-1][0] - start[0], 2),
    "meanCPUPercentOfOneCore": round((samples[-1][0] - start[0]) / elapsed * 100, 2),
    "rssMiBMin": round(min(s[1] for s in samples) / 1024, 1),
    "rssMiBMax": round(max(s[1] for s in samples) / 1024, 1),
    "instantCPUPercentSamples": [s[2] for s in samples]
}, indent=2))
