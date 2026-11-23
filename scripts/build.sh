#!/bin/bash
# [INPUT]: Swift Package Manager、Sparkle、Resources、开发或 Universal 构建选项与签名身份。
# [OUTPUT]: 带源码修订、完整许可与签名的主应用和独立遥控器插件；不安装、不注册登录项。
# [POS]: 先在临时目录装配并验证，再替换构建产物，不保留旧包残留。
# [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
BUILD_ARGS=(-c release)
DEVELOPMENT=false
case "$*" in
    --universal) BUILD_ARGS+=(--arch arm64 --arch x86_64) ;;
    --development) BUILD_ARGS=(-c debug); DEVELOPMENT=true ;;
    "") ;;
    *) printf 'Usage: bash scripts/build.sh [--universal | --development]\n' >&2; exit 2 ;;
esac
if "$DEVELOPMENT" && [[ -z "${VORSMATE_DIST_DIR:-}" ]]; then
    VORSMATE_DIST_DIR="$PROJECT_ROOT/artifacts/dev/build"
fi
swift build "${BUILD_ARGS[@]}"
BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
DIST_DIR="${VORSMATE_DIST_DIR:-$PROJECT_ROOT/dist}"
mkdir -p "$DIST_DIR"
DIST_DIR="$(cd "$DIST_DIR" && pwd -P)"
if [[ "$DIST_DIR" == "/Applications" ]]; then
    echo "Choose a build directory outside /Applications." >&2
    exit 2
fi
APP_PATH="$DIST_DIR/Vorsmate.app"
STAGING_ROOT="$(mktemp -d "$DIST_DIR/.vorsmate-build.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
STAGED_APP="$STAGING_ROOT/Vorsmate.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources/License/LICENSES" "$STAGED_APP/Contents/Library/LaunchDaemons" "$STAGED_APP/Contents/Frameworks"
cp "$BIN_PATH/Vorsmate" "$STAGED_APP/Contents/MacOS/Vorsmate"
cp "$BIN_PATH/VorsmateFanHelper" "$STAGED_APP/Contents/MacOS/VorsmateFanHelper"
cp "$PROJECT_ROOT/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
if "$DEVELOPMENT"; then
    /usr/libexec/PlistBuddy -c 'Add :VorsmateDevelopmentBuild bool true' "$STAGED_APP/Contents/Info.plist"
fi
if REVISION="$(git rev-parse HEAD 2>/dev/null)"; then
    if [[ -n "$(git status --porcelain)" ]]; then REVISION="$REVISION-dirty"; fi
    /usr/libexec/PlistBuddy -c "Add :VorsmateSourceRevision string $REVISION" "$STAGED_APP/Contents/Info.plist"
fi
cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/"
cp "$PROJECT_ROOT/Resources/StatusIcon.pdf" "$STAGED_APP/Contents/Resources/"
cp "$PROJECT_ROOT/Resources/LaunchDaemons/app.vorsmate.fan-helper.plist" "$STAGED_APP/Contents/Library/LaunchDaemons/"
cp "$PROJECT_ROOT/LICENSE" "$PROJECT_ROOT/THIRD_PARTY_NOTICES.md" "$STAGED_APP/Contents/Resources/License/"
cp "$PROJECT_ROOT/LICENSES/macos-fan-control-MIT.txt" "$STAGED_APP/Contents/Resources/License/LICENSES/"
cp "$PROJECT_ROOT/LICENSES/Sparkle-LICENSE.txt" "$STAGED_APP/Contents/Resources/License/LICENSES/"
SPARKLE="$STAGED_APP/Contents/Frameworks/Sparkle.framework"
ditto "$PROJECT_ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$SPARKLE"
# SwiftPM 会写入本机 Framework 搜索路径，发行包只从自己的 Frameworks 目录加载。
python3 - "$STAGED_APP/Contents/MacOS/Vorsmate" "$STAGED_APP/Contents/MacOS/VorsmateFanHelper" <<'PY'
import re, subprocess, sys
for binary in sys.argv[1:]:
    output = subprocess.check_output(['otool', '-l', binary], text=True)
    paths = set(re.findall(r'\bpath (/[^\n]+) \(offset \d+\)', output))
    for path in paths:
        if not path.startswith(('/usr/lib/', '/System/Library/')):
            subprocess.run(['install_name_tool', '-delete_rpath', path, binary], check=True)
PY
VORSMATE_SIGN_IDENTITY="${VORSMATE_SIGN_IDENTITY:--}"
SIGN_ARGS=(--force --sign "$VORSMATE_SIGN_IDENTITY")
# 临时签名仅供本地开发；已签名发行包使用 hardened runtime，嵌套框架采用同一身份。
if [[ "$VORSMATE_SIGN_IDENTITY" != "-" ]]; then
    SIGN_ARGS+=(--options runtime)
    if "$DEVELOPMENT"; then SIGN_ARGS+=(--timestamp=none); else SIGN_ARGS+=(--timestamp); fi
fi
# 可选插件只放在主应用旁，主应用的 DMG 不隐式安装它。
REMOTE="$STAGING_ROOT/VorsmateRemote.app"
mkdir -p "$REMOTE/Contents/MacOS" "$REMOTE/Contents/Resources"
cp "$BIN_PATH/VorsmateRemote" "$REMOTE/Contents/MacOS/"
cp "$PROJECT_ROOT/Resources/Remote/Info.plist" "$REMOTE/Contents/"
cp "$PROJECT_ROOT/Resources/Remote/RC003.png" "$PROJECT_ROOT/LICENSE" "$REMOTE/Contents/Resources/"
codesign "${SIGN_ARGS[@]}" "$REMOTE"
codesign --verify --strict "$REMOTE"
if [[ "$VORSMATE_SIGN_IDENTITY" == "-" ]]; then
    /usr/libexec/PlistBuddy -c 'Add :VorsmateRemoteDevelopmentHashes array' "$STAGED_APP/Contents/Info.plist"
    for arch in $(lipo -archs "$REMOTE/Contents/MacOS/VorsmateRemote"); do
        hash="$(codesign -dvvv --arch "$arch" "$REMOTE" 2>&1 | sed -n 's/^CDHash=//p')"
        [[ -n "$hash" ]]
        /usr/libexec/PlistBuddy -c "Add :VorsmateRemoteDevelopmentHashes: string $hash" "$STAGED_APP/Contents/Info.plist"
    done
fi
for SERVICE in "$SPARKLE"/Versions/B/XPCServices/*.xpc; do codesign "${SIGN_ARGS[@]}" "$SERVICE"; done
codesign "${SIGN_ARGS[@]}" "$SPARKLE/Versions/B/Autoupdate"
codesign "${SIGN_ARGS[@]}" "$SPARKLE/Versions/B/Updater.app"
codesign "${SIGN_ARGS[@]}" "$SPARKLE"
codesign "${SIGN_ARGS[@]}" --identifier app.vorsmate.fan-helper "$STAGED_APP/Contents/MacOS/VorsmateFanHelper"
if "$DEVELOPMENT" && [[ "${VORSMATE_FOLLOW_FAN_HELPER:-false}" == true ]]; then
    helper_hash="$(codesign -dvvv "$STAGED_APP/Contents/MacOS/VorsmateFanHelper" 2>&1 | sed -n 's/^CDHash=//p')"
    [[ "$helper_hash" =~ ^[[:xdigit:]]{40}$ ]]
    /usr/libexec/PlistBuddy -c "Add :VorsmateDevelopmentFanHelperHash string $helper_hash" "$STAGED_APP/Contents/Info.plist"
fi
codesign "${SIGN_ARGS[@]}" --entitlements "$PROJECT_ROOT/Resources/Vorsmate.entitlements" "$STAGED_APP"
codesign --verify --strict "$STAGED_APP/Contents/MacOS/VorsmateFanHelper"
codesign --verify --strict "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
rm -rf "$APP_PATH"
mv "$STAGED_APP" "$APP_PATH"
rm -rf "$DIST_DIR/VorsmateRemote.app"
mv "$REMOTE" "$DIST_DIR/VorsmateRemote.app"
printf '%s\n' "$APP_PATH"
