#!/bin/bash
# [INPUT]: 已构建且签名的 Universal Vorsmate.app、安装说明与系统磁盘镜像工具。
# [OUTPUT]: dist/release/ 下的拖放安装 DMG 与 SHA256SUMS；不上传、不安装、不公证。
# [POS]: 构建后的发行打包；检查两种架构、签名、版本和随包许可。
# [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$PROJECT_ROOT/dist/Vorsmate.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'Invalid app version\n' >&2; exit 1; }
for BINARY in Vorsmate VorsmateFanHelper; do
    ARCHS=" $(lipo -archs "$APP_PATH/Contents/MacOS/$BINARY") "
    if [[ "$ARCHS" != *" arm64 "* || "$ARCHS" != *" x86_64 "* ]]; then
        printf 'Universal build required: %s\n' "$BINARY" >&2
        exit 1
    fi
done
codesign --verify --strict "$APP_PATH/Contents/MacOS/VorsmateFanHelper"
codesign --verify --strict "$APP_PATH"
cmp "$PROJECT_ROOT/LICENSE" "$APP_PATH/Contents/Resources/License/LICENSE"
cmp "$PROJECT_ROOT/THIRD_PARTY_NOTICES.md" "$APP_PATH/Contents/Resources/License/THIRD_PARTY_NOTICES.md"
cmp "$PROJECT_ROOT/LICENSES/macos-fan-control-MIT.txt" "$APP_PATH/Contents/Resources/License/LICENSES/macos-fan-control-MIT.txt"
OUTPUT="$PROJECT_ROOT/dist/release"
mkdir -p "$OUTPUT"
STAGING_ROOT="$(mktemp -d "$PROJECT_ROOT/dist/.vorsmate-package.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
mkdir "$STAGING_ROOT/image"
ditto "$APP_PATH" "$STAGING_ROOT/image/Vorsmate.app"
ln -s /Applications "$STAGING_ROOT/image/Applications"
cp "$PROJECT_ROOT/Resources/Install.txt" "$STAGING_ROOT/image/Install.txt"
DMG_NAME="Vorsmate-$VERSION-universal.dmg"
hdiutil create -volname "Vorsmate $VERSION" -srcfolder "$STAGING_ROOT/image" -format UDZO "$STAGING_ROOT/$DMG_NAME"
hdiutil verify "$STAGING_ROOT/$DMG_NAME"
mv "$STAGING_ROOT/$DMG_NAME" "$OUTPUT/$DMG_NAME"
(cd "$OUTPUT" && shasum -a 256 "$DMG_NAME" > SHA256SUMS)
printf '%s\n' "$OUTPUT/$DMG_NAME"
