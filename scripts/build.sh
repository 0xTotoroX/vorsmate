#!/bin/bash
# [INPUT]: Swift Package Manager、Resources 元数据、可选 --universal 与签名身份。
# [OUTPUT]: 带源码修订、完整许可与签名的 dist/Vorsmate.app；不安装、不注册登录项。
# [POS]: 先在临时目录装配并验证，再替换构建产物，不保留旧包残留。
# [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
BUILD_ARGS=(-c release)
case "${1:-}" in
    --universal) BUILD_ARGS+=(--arch arm64 --arch x86_64) ;;
    "") ;;
    *) printf 'Usage: bash scripts/build.sh [--universal]\n' >&2; exit 2 ;;
esac
swift build "${BUILD_ARGS[@]}"
BIN_PATH="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
APP_PATH="$PROJECT_ROOT/dist/Vorsmate.app"
mkdir -p "$PROJECT_ROOT/dist"
STAGING_ROOT="$(mktemp -d "$PROJECT_ROOT/dist/.vorsmate-build.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
STAGED_APP="$STAGING_ROOT/Vorsmate.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources/License/LICENSES" "$STAGED_APP/Contents/Library/LaunchDaemons"
cp "$BIN_PATH/Vorsmate" "$STAGED_APP/Contents/MacOS/Vorsmate"
cp "$BIN_PATH/VorsmateFanHelper" "$STAGED_APP/Contents/MacOS/VorsmateFanHelper"
cp "$PROJECT_ROOT/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
if REVISION="$(git rev-parse HEAD 2>/dev/null)"; then
    if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then REVISION="$REVISION-dirty"; fi
    /usr/libexec/PlistBuddy -c "Add :VorsmateSourceRevision string $REVISION" "$STAGED_APP/Contents/Info.plist"
fi
cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$STAGED_APP/Contents/Resources/"
cp "$PROJECT_ROOT/Resources/StatusIcon.pdf" "$STAGED_APP/Contents/Resources/"
cp "$PROJECT_ROOT/Resources/LaunchDaemons/app.vorsmate.fan-helper.plist" "$STAGED_APP/Contents/Library/LaunchDaemons/"
cp "$PROJECT_ROOT/LICENSE" "$PROJECT_ROOT/THIRD_PARTY_NOTICES.md" "$STAGED_APP/Contents/Resources/License/"
cp "$PROJECT_ROOT/LICENSES/macos-fan-control-MIT.txt" "$STAGED_APP/Contents/Resources/License/LICENSES/"
VORSMATE_SIGN_IDENTITY="${VORSMATE_SIGN_IDENTITY:--}"
SIGN_ARGS=(--force --options runtime --sign "$VORSMATE_SIGN_IDENTITY")
if [[ "$VORSMATE_SIGN_IDENTITY" != "-" ]]; then SIGN_ARGS+=(--timestamp); fi
codesign "${SIGN_ARGS[@]}" --identifier app.vorsmate.fan-helper "$STAGED_APP/Contents/MacOS/VorsmateFanHelper"
codesign "${SIGN_ARGS[@]}" "$STAGED_APP"
codesign --verify --strict "$STAGED_APP/Contents/MacOS/VorsmateFanHelper"
codesign --verify --strict "$STAGED_APP"
rm -rf "$APP_PATH"
mv "$STAGED_APP" "$APP_PATH"
printf '%s\n' "$APP_PATH"
