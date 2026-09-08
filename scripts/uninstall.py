#!/usr/bin/env python3
"""Preview removal, or move this app to Trash. Codex data and app preferences stay intact."""
import argparse
import datetime
import plistlib
from pathlib import Path
import subprocess
import shutil

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--apply', action='store_true', help='Move the stopped application to Trash')
args = parser.parse_args()
app = Path.home() / 'Applications/CodexTouchBar.app'
print('Before removal: turn off Login at launch in the app menu, then Quit.')
print('Application:', app)
print('Preserved: Codex tasks/login, tool preferences, caches and earlier app backups.')
if not app.exists():
    print('Application is not installed here.'); raise SystemExit(0)
if app.is_symlink():
    raise SystemExit('Refusing a symlink application path.')
with (app / 'Contents/Info.plist').open('rb') as source:
    if plistlib.load(source).get('CFBundleIdentifier') != 'local.codex.touchbar':
        raise SystemExit('Bundle identity mismatch; nothing changed.')
if not args.apply:
    print('Preview only. Run with --apply after disabling login launch and quitting.'); raise SystemExit(0)
processes = subprocess.run(['pgrep', '-x', 'CodexTouchBar'], capture_output=True, text=True).stdout.split()
if processes:
    raise SystemExit('Please quit all CodexTouchBar app/preview processes before removal.')
trash = Path.home() / '.Trash'
trash.mkdir(exist_ok=True)
target = trash / ('CodexTouchBar-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f') + '.app')
shutil.move(str(app), str(target))
print('Moved to Trash:', target)
