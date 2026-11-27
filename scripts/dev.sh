#!/bin/bash
# [INPUT]: 工作区源码、签名身份、本机 vorsmate.followFanHelper 选择、可选 --build-only。
# [OUTPUT]: 项目内的开发版主应用及配套插件，构建通过后可重开自身。
# [POS]: 交接固定路径的开发实例，通过其签名程序同步已选择的风扇助手。
# [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DEV_ROOT="$PROJECT_ROOT/artifacts/dev"
case "$*" in
    --build-only) BUILD_ONLY=true ;;
    "") BUILD_ONLY=false ;;
    *) printf 'Usage: bash scripts/dev.sh [--build-only]\n' >&2; exit 2 ;;
esac

mkdir -p "$DEV_ROOT"
if [[ "$(cd "$DEV_ROOT" && pwd -P)" != "$DEV_ROOT" ]]; then
    printf '开发版目录必须位于当前工作区内。\n' >&2
    exit 1
fi
exec 9>"$DEV_ROOT/reload.lock"
if ! /usr/bin/lockf -s -t 0 9; then
    printf '已有一次 Vorsmate 开发版重载正在进行。\n' >&2
    exit 1
fi
export VORSMATE_SIGN_IDENTITY="${VORSMATE_SIGN_IDENTITY:-$(git -C "$PROJECT_ROOT" config --local --get vorsmate.signIdentity || true)}"
if "$BUILD_ONLY"; then
    VORSMATE_DIST_DIR="$DEV_ROOT/build" exec bash "$PROJECT_ROOT/scripts/build.sh" --development
fi
FOLLOW_HELPER="$(git -C "$PROJECT_ROOT" config --local --type=bool --default false --get vorsmate.followFanHelper)"
export VORSMATE_FOLLOW_FAN_HELPER="$FOLLOW_HELPER"
RUN_DIR="$DEV_ROOT/run"
RUN_APP="$RUN_DIR/Vorsmate.app"
RUN_BIN="$RUN_APP/Contents/MacOS/Vorsmate"
if [[ -L "$RUN_DIR" || -L "$RUN_APP" ]]; then
    printf '开发版运行目录不能是符号链接。\n' >&2
    exit 1
fi
WORK_DIR=""
HELPER_TOUCHED=false
cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR/previous" ]]; then
        if [[ -e "$RUN_DIR" ]] && ! mv "$RUN_DIR" "$WORK_DIR/rejected"; then
            printf '上次开发版保存在 %s\n' "$WORK_DIR/previous" >&2
            return
        fi
        if ! mv "$WORK_DIR/previous" "$RUN_DIR"; then
            printf '上次开发版保存在 %s\n' "$WORK_DIR/previous" >&2
            return
        fi
        if "$HELPER_TOUCHED" && /usr/libexec/PlistBuddy -c 'Print :VorsmateDevelopmentFanHelperHash' "$RUN_APP/Contents/Info.plist" >/dev/null 2>&1; then
            "$RUN_BIN" --development-fan-helper sync || printf '请复查已恢复的开发版风扇助手。\n' >&2
        fi
        open -g "$RUN_APP" 9>&- || printf '请重新打开 %s\n' "$RUN_APP" >&2
    fi
    if [[ -n "$WORK_DIR" ]]; then rm -rf "$WORK_DIR"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

WORK_DIR="$(mktemp -d "$DEV_ROOT/.reload.XXXXXX")"
VORSMATE_DIST_DIR="$WORK_DIR/next" bash "$PROJECT_ROOT/scripts/build.sh" --development
next_app="$WORK_DIR/next/Vorsmate.app"
refresh_helper=false
if "$FOLLOW_HELPER"; then
    team="$(codesign -dv "$next_app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    if [[ ! "$team" =~ ^[A-Z0-9]{10}$ ]]; then
        printf '随开发版更新风扇助手需要本机 Apple 签名身份。\n' >&2
        exit 1
    fi
    old_hash="$(/usr/libexec/PlistBuddy -c 'Print :VorsmateDevelopmentFanHelperHash' "$RUN_APP/Contents/Info.plist" 2>/dev/null || true)"
    new_hash="$(/usr/libexec/PlistBuddy -c 'Print :VorsmateDevelopmentFanHelperHash' "$next_app/Contents/Info.plist")"
    daemon_plist=Contents/Library/LaunchDaemons/app.vorsmate.fan-helper.plist
    if [[ "$old_hash" != "$new_hash" ]] || ! cmp -s "$RUN_APP/$daemon_plist" "$next_app/$daemon_plist"; then
        refresh_helper=true
    fi
fi
if [[ -e "$RUN_DIR" ]]; then
    # 只有已标记的开发包能执行此命令。构建失败时完全不会走到交接步骤。
    "$RUN_APP/Contents/MacOS/Vorsmate" --development-stop
    mv "$RUN_DIR" "$WORK_DIR/previous"
else
    "$WORK_DIR/next/Vorsmate.app/Contents/MacOS/Vorsmate" --development-stop
fi
mv "$WORK_DIR/next" "$RUN_DIR"
helper_result=0
if "$FOLLOW_HELPER"; then
    if ! "$refresh_helper"; then
        "$RUN_BIN" --development-fan-helper verify || helper_result=$?
        if [[ "$helper_result" == 1 ]]; then refresh_helper=true; fi
    fi
    if "$refresh_helper"; then
        HELPER_TOUCHED=true
        helper_result=0
        "$RUN_BIN" --development-fan-helper sync || helper_result=$?
    fi
fi
open -g -n "$RUN_APP" 9>&-
for (( attempt=0; attempt<100; attempt++ )); do
    if [[ -n "$(/usr/bin/lsappinfo find "bundlepath=$RUN_APP")" ]]; then break; fi
    sleep 0.1
done
if [[ -z "$(/usr/bin/lsappinfo find "bundlepath=$RUN_APP")" ]]; then
    printf '系统未找到新启动的开发版。\n' >&2
    exit 1
fi
if [[ "$helper_result" -eq 0 ]]; then
    if [[ -d "$WORK_DIR/previous" ]]; then rm -rf "$WORK_DIR/previous"; fi
else
    if [[ -d "$WORK_DIR/previous" ]]; then
        printf '风扇助手同步失败（退出码 %s），已保留上一版开发备份：%s\n' "$helper_result" "$WORK_DIR/previous" >&2
    else
        printf '风扇助手同步失败（退出码 %s）。\n' "$helper_result" >&2
    fi
    WORK_DIR=""
fi
printf 'Vorsmate 开发版已启动。\n%s\n' "$RUN_APP"
exit "$helper_result"
