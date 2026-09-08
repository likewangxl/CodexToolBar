# Contributing

The project focuses on two-task Touch Bar monitoring, reliable status/quota data,
and explicit voice input with low background resource use.

Run `swift test`, `./scripts/build-app.sh`, and
`python3 scripts/smoke-ipc.py .build/release/CodexTouchBar` before submitting changes.
CI uses an Intel macOS runner and UTC to expose accidental local-time assumptions.
No account credentials or real speech/desktop access are needed for fixture tests.

Keep private API calls isolated, preserve protocol/version checks, and add fixtures
for failure modes when changing account, stream or submission behavior. Do not
replace unknown data with zero or automatically retry an uncertain submission.

Use synthetic task names and data in screenshots/tests. Do not commit credentials,
Codex logs, private diagnostics, binaries, personal artwork or historical backups.
Use `scripts/export-source.py` for a new reviewable directory before first publication.

Hardware acceptance is separate from CI. Describe what was tested on a real
Touch Bar device and what remains unverified. See docs/ACCEPTANCE.md.
