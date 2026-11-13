#!/bin/bash
# [INPUT]: 已验证 Universal DMG、应用元数据与登录钥匙串中的项目更新密钥。
# [OUTPUT]: 与 GitHub Release 资产对应的 Ed25519 签名 appcast.xml；不上传。
# [POS]: 本地发布的最后一步，所有新版本与 DMG 一同发布。
# [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/Vorsmate.app/Contents/Info.plist)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'Invalid version\n' >&2; exit 1; }
DMG="dist/release/Vorsmate-$VERSION-universal.dmg"
PUBLIC_KEY="$(.build/artifacts/sparkle/Sparkle/bin/generate_keys --account app.vorsmate.mac -p)"
EXPECTED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' dist/Vorsmate.app/Contents/Info.plist)"
[[ "$PUBLIC_KEY" == "$EXPECTED_KEY" ]] || { printf 'Update key does not match application\n' >&2; exit 1; }
SIGNATURE="$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account app.vorsmate.mac "$DMG")"
python3 - "$VERSION" "$SIGNATURE" <<'PY'
import datetime, email.utils, pathlib, plistlib, sys, xml.etree.ElementTree as ET
version, signature = sys.argv[1:]
namespace = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', namespace)
info = plistlib.loads(pathlib.Path('dist/Vorsmate.app/Contents/Info.plist').read_bytes())
enclosure = ET.fromstring(f'<enclosure xmlns:sparkle="{namespace}" {signature}/>')
assert enclosure.attrib[f'{{{namespace}}}edSignature']
filename = f'Vorsmate-{version}-universal.dmg'
assert int(enclosure.attrib['length']) == pathlib.Path('dist/release', filename).stat().st_size
rss = ET.Element('rss', version='2.0')
channel = ET.SubElement(rss, 'channel')
ET.SubElement(channel, 'title').text = 'Vorsmate'
item = ET.SubElement(channel, 'item')
ET.SubElement(item, 'title').text = f'Vorsmate {version}'
ET.SubElement(item, 'link').text = f'https://github.com/0xTotoroX/vorsmate/releases/tag/v{version}'
ET.SubElement(item, f'{{{namespace}}}version').text = info['CFBundleVersion']
ET.SubElement(item, f'{{{namespace}}}shortVersionString').text = version
ET.SubElement(item, f'{{{namespace}}}minimumSystemVersion').text = info['LSMinimumSystemVersion']
ET.SubElement(item, 'pubDate').text = email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc))
enclosure.set('url', f'https://github.com/0xTotoroX/vorsmate/releases/download/v{version}/{filename}')
enclosure.set('type', 'application/octet-stream')
item.append(enclosure)
ET.indent(rss)
pathlib.Path('dist/release/appcast.xml').write_bytes(ET.tostring(rss, encoding='utf-8', xml_declaration=True))
print('dist/release/appcast.xml')
PY
