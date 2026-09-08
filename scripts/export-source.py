#!/usr/bin/env python3
"""Produce a reviewable source-only directory; never publishes or initializes Git."""
import argparse
from pathlib import Path
import shutil

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('destination', type=Path, help='A NEW directory for public source review')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
dest = args.destination.expanduser().absolute()
if dest.exists():
    raise SystemExit('Destination already exists; choose a new directory.')
allowed_files = ['Package.swift', 'Info.plist', 'README.md', 'LICENSE', 'NOTICE.md', 'CONTRIBUTING.md', '.gitignore',
                 'docs/INSTALL.md', 'docs/COMPATIBILITY.md', 'docs/ACCEPTANCE.md']
allowed_dirs = ['Sources', 'Tests', 'scripts', '.github', 'docs/screenshots']
def ignored(folder, names):
    return [name for name in names if name in ['QuotaIcon.png', '__pycache__', '.DS_Store'] or (Path(folder) / name).is_symlink()]
dest.mkdir(parents=True)
for name in allowed_files:
    source = root / name
    if source.is_symlink(): raise SystemExit('Unexpected symlink: ' + name)
    target = dest / name; target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(source, target)
for name in allowed_dirs:
    shutil.copytree(root / name, dest / name, ignore=ignored)
print('Source export prepared:', dest)
print('Excluded: builds/backups, private diagnostics, personal screenshots, personal artwork and design references.')
print('Review before publishing. No repository, upload or release was created.')
