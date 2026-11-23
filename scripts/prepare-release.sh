#!/bin/bash
# [INPUT]: 已有的 vX.Y.Z 标签、Apple 签名身份和本机 Sparkle 更新密钥。
# [OUTPUT]: artifacts/releases/<标签>/ 下核验过的主应用、DMG 和 appcast.xml。
# [POS]: 在独立 Git 工作树内构建标签指向的源码，日常开发版可继续运行。
# [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(pwd -P)"
tag="${1:-}"
if [[ $# != 1 || ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'Usage: bash scripts/prepare-release.sh vX.Y.Z\n' >&2
    exit 2
fi
revision="$(git rev-parse --verify "refs/tags/$tag^{commit}")"
identity="${VORSMATE_SIGN_IDENTITY:-$(git config --local --get vorsmate.signIdentity || true)}"
if [[ -z "$identity" || "$identity" == "-" ]]; then
    printf '请指定 VORSMATE_SIGN_IDENTITY 或配置本仓库的 vorsmate.signIdentity。\n' >&2
    exit 1
fi
output="$root/artifacts/releases"
mkdir -p "$output"
exec 9>"$output/prepare.lock"
if ! /usr/bin/lockf -s -t 0 9; then
    printf '另一次发行打包正在进行。\n' >&2
    exit 1
fi
if [[ -e "$output/$tag" || -L "$output/$tag" ]]; then
    printf '已有发行产物：%s\n' "$output/$tag" >&2
    exit 1
fi
stage="$(mktemp -d "$output/.prepare.XXXXXX")"
checkout="$stage/source"
cleanup() {
    if [[ -f "$checkout/.git" ]]; then
        git -C "$root" worktree remove --force "$checkout" || return 1
    fi
    rm -rf "$stage"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
git worktree add --detach "$checkout" "$revision"
(
    cd "$checkout"
    version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
    if [[ "v$version" != "$tag" ]]; then
        printf '标签 %s 与源码版本 %s 不一致。\n' "$tag" "$version" >&2
        exit 1
    fi
    export VORSMATE_SIGN_IDENTITY="$identity" VORSMATE_DIST_DIR="$checkout/dist"
    bash scripts/build.sh --universal
    app=dist/Vorsmate.app
    if [[ "$(/usr/libexec/PlistBuddy -c 'Print :VorsmateSourceRevision' "$app/Contents/Info.plist")" != "$revision" ]]; then
        printf '构建产物的源码修订与标签不符。\n' >&2
        exit 1
    fi
    bash scripts/package.sh
    bash scripts/appcast.sh
    dmg="dist/release/Vorsmate-$version.dmg"
    swift scripts/verify-update.swift dist/updates/appcast.xml "$app" "$dmg"
    mkdir "$stage/verified"
    mv "$app" "$dmg" dist/updates/appcast.xml "$stage/verified/"
)
mv "$stage/verified" "$output/$tag"
printf '%s\n' "$output/$tag"
