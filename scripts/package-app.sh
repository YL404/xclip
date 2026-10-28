#!/bin/bash
# Build and optionally install the MyGo app and the xclip CLI.
#
# Usage:
#   scripts/package-app.sh                 build the app into .build/mygo/<os>-<arch>/
#   scripts/package-app.sh --install       copy the app to /Applications and the CLI to ~/.local/bin
#   scripts/package-app.sh --launch        open the app after building

set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=0
LAUNCH=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --launch)  LAUNCH=1 ;;
    *) echo "未知参数: $arg" >&2; exit 64 ;;
  esac
done

echo "→ 构建 MyGo 应用"
npm run build -- -skip-dmg

BUNDLE=".build/mygo/darwin-arm64/XClip.app"
if [ ! -d "${BUNDLE}" ]; then
  echo "✗ 未找到 ${BUNDLE}" >&2
  exit 1
fi

echo "→ 构建 xclip CLI"
go build -trimpath -ldflags="-s -w" -o .build/xclip ./cmd/xclip

if [ "${INSTALL}" -eq 1 ]; then
  echo "→ 安装到 /Applications"
  rm -rf "/Applications/XClip.app"
  cp -R "${BUNDLE}" "/Applications/XClip.app"

  echo "→ 安装 xclip CLI 到 ~/.local/bin"
  mkdir -p "${HOME}/.local/bin"
  cp -f .build/xclip "${HOME}/.local/bin/xclip"
  echo "✓ 已安装: ${HOME}/.local/bin/xclip（确保 ~/.local/bin 在 PATH 里）"
fi

if [ "${LAUNCH}" -eq 1 ]; then
  TARGET="${BUNDLE}"
  [ "${INSTALL}" -eq 1 ] && TARGET="/Applications/XClip.app"
  echo "→ 启动 ${TARGET}"
  open "${TARGET}"
fi

echo "✓ 完成: ${BUNDLE}"
