#!/bin/bash
# 把 SwiftPM 的 executable target 打包成可安装的 XClip.app。
#
# 用法：
#   scripts/package-app.sh                 只打包到 .build/app/XClip.app
#   scripts/package-app.sh --install        打包并复制到 /Applications，
#                                           同时把 xclip CLI 装到 ~/.local/bin/xclip
#   scripts/package-app.sh --install --launch   再启动一次，验证能跑
#
# 产物在 .build/app/ 下，被 .gitignore 忽略；目录带 .metadata_never_index，
# Spotlight 不索引，避免和 /Applications 里的安装副本同时出现在搜索结果里。

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="XClip"
BUILD_DIR=".build/app"
BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
ICONSET="${BUILD_DIR}/AppIcon.iconset"

INSTALL=0
LAUNCH=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --launch)  LAUNCH=1 ;;
    *) echo "未知参数: $arg" >&2; exit 64 ;;
  esac
done

echo "→ 构建 release"
swift build -c release

echo "→ 渲染图标"
rm -rf "${ICONSET}"
swift tools/render-icon.swift "${BUILD_DIR}"

echo "→ 生成 icns"
iconutil -c icns "${ICONSET}" -o "${BUILD_DIR}/AppIcon.icns"

echo "→ 组装 bundle"
rm -rf "${BUNDLE}"
mkdir -p "${BUILD_DIR}" "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
touch "${BUILD_DIR}/.metadata_never_index"
cp ".build/release/XClipApp" "${BUNDLE}/Contents/MacOS/"
cp "${BUILD_DIR}/AppIcon.icns" "${BUNDLE}/Contents/Resources/"
# 母版 SVG 一并带上，将来改图标有据可查
cp "designs/xclip-logo/app-icon.svg" "${BUNDLE}/Contents/Resources/AppIcon.svg"

cat > "${BUNDLE}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleDisplayName</key>
	<string>xclip</string>
	<key>CFBundleExecutable</key>
	<string>XClipApp</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>dev.xclip.XClip</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>xclip</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

echo "→ ad-hoc 签名（本机运行够用，不上架）"
codesign --force --sign - "${BUNDLE}"

echo "✓ 打包完成: ${BUNDLE}"

if [ "${INSTALL}" -eq 1 ]; then
  echo "→ 安装到 /Applications"
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "${BUNDLE}" "/Applications/${APP_NAME}.app"
  echo "✓ 已安装: /Applications/${APP_NAME}.app"

  echo "→ 安装 xclip CLI 到 ~/.local/bin"
  mkdir -p "${HOME}/.local/bin"
  cp -f ".build/release/xclip" "${HOME}/.local/bin/xclip"
  echo "✓ 已安装: ${HOME}/.local/bin/xclip（确保 ~/.local/bin 在 PATH 里）"
fi

if [ "${LAUNCH}" -eq 1 ]; then
  TARGET="${BUNDLE}"
  [ "${INSTALL}" -eq 1 ] && TARGET="/Applications/${APP_NAME}.app"
  echo "→ 启动 ${TARGET}"
  open "${TARGET}"
  sleep 2
  if pgrep -f "XClip.app/Contents/MacOS/XClipApp" > /dev/null; then
    echo "✓ 已在运行"
  else
    echo "✗ 启动后进程不在，看 Console 里的崩溃日志" >&2
    exit 1
  fi
fi
