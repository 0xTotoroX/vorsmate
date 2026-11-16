#!/bin/bash
# [INPUT]: 已公开发行的签名 feed、对应应用与 DMG；GitHub / Git 的既有维护权限。
# [OUTPUT]: 固定 updates 分支上的 appcast.xml；拒绝未发布或字节不匹配的载荷。
# [POS]: Release 公开且回验后显式调用；不修改主分支、不强推、不自动创建 Release。
# [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
FEED="${1:-dist/updates/appcast.xml}"
APP="${2:-dist/Vorsmate.app}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCHIVE="${3:-dist/release/Vorsmate-$VERSION.dmg}"
swift scripts/verify-update.swift "$FEED" "$APP" "$ARCHIVE"
python3 - "$FEED" "$APP" "$ARCHIVE" <<'PY'
import hashlib, json, os, pathlib, plistlib, subprocess, sys, tempfile, xml.etree.ElementTree as ET
feed, app, archive = map(pathlib.Path, sys.argv[1:])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
version = info['CFBundleShortVersionString']
repo = '0xTotoroX/vorsmate'
filename = f'Vorsmate-{version}.dmg'
release = json.loads(subprocess.check_output(['gh', 'release', 'view', f'v{version}', '--repo', repo,
    '--json', 'tagName,isDraft,assets']))
assert release['tagName'] == f'v{version}' and not release['isDraft'], 'Release must be public before updating the feed'
asset = next(item for item in release['assets'] if item['name'] == filename)
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
assert asset['size'] == archive.stat().st_size and asset['digest'] == 'sha256:' + digest, 'Published archive differs'
enclosure = ET.fromstring(feed.read_bytes()).find('./channel/item/enclosure')
assert enclosure is not None and enclosure.attrib['url'] == f'https://github.com/{repo}/releases/download/v{version}/{filename}'
remote = subprocess.check_output(['git', 'ls-remote', 'origin', 'refs/heads/updates'], text=True).strip()
parent = None
if remote:
    subprocess.run(['git', 'fetch', '--no-tags', 'origin', 'refs/heads/updates:refs/remotes/origin/updates'], check=True)
    parent = subprocess.check_output(['git', 'rev-parse', 'refs/remotes/origin/updates'], text=True).strip()
with tempfile.TemporaryDirectory(prefix='vorsmate-feed-index-') as temporary:
    env = os.environ.copy()
    env['GIT_INDEX_FILE'] = str(pathlib.Path(temporary) / 'index')
    subprocess.run(['git', 'read-tree', parent or '--empty'], env=env, check=True)
    blob = subprocess.check_output(['git', 'hash-object', '-w', str(feed)], text=True).strip()
    subprocess.run(['git', 'update-index', '--add', '--cacheinfo', f'100644,{blob},appcast.xml'], env=env, check=True)
    tree = subprocess.check_output(['git', 'write-tree'], env=env, text=True).strip()
    if parent and tree == subprocess.check_output(['git', 'rev-parse', parent + '^{tree}'], text=True).strip():
        print('Fixed signed feed is already up to date.')
        sys.exit(0)
    command = ['git', 'commit-tree', tree]
    if parent:
        command += ['-p', parent]
    commit = subprocess.check_output(command + ['-m', f'chore(updates): publish signed v{version} feed'], text=True).strip()
    subprocess.run(['git', 'push', 'origin', f'{commit}:refs/heads/updates'], check=True)
    actual = subprocess.check_output(['git', 'ls-remote', 'origin', 'refs/heads/updates'], text=True).split()[0]
    assert actual == commit, 'Remote update feed commit changed; verify before retrying'
print('Published fixed signed feed: https://raw.githubusercontent.com/0xTotoroX/vorsmate/updates/appcast.xml')
PY
