#!/bin/zsh
# 构建 LangFix：swift build 产出可执行文件 → 组装成 .app bundle（含 Info.plist）→ ad-hoc 签名。
# 用法：
#   ./build.sh            # release 构建并组装到 build/LangFix.app
#   ./build.sh debug      # debug 构建
#   ./build.sh install    # release 构建 + 安装到 /Applications 并注册 Service
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="release"
DO_INSTALL="no"
case "${1:-}" in
  debug) CONFIG="debug" ;;
  install) CONFIG="release"; DO_INSTALL="yes" ;;
  "" ) ;;
  *) echo "未知参数: $1（可选 debug|install）" >&2; exit 2 ;;
esac

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/LangFix"
[ -x "$BIN" ] || { echo "未找到可执行文件: $BIN" >&2; exit 1; }

APP="build/LangFix.app"
echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LangFix"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "==> ad-hoc 代码签名"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || \
  echo "（codesign 失败，可忽略；首次运行可能需在系统设置里放行）"

echo "==> 完成：$APP"

if [ "$DO_INSTALL" = "yes" ]; then
  DEST="/Applications/LangFix.app"
  echo "==> 安装到 $DEST"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  # 注册 Launch Services + 刷新 Services 缓存，让 macOS Service 可被 PopClip 调用
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" || true
  /System/Library/CoreServices/pbs -update || true
  echo "==> 已安装。首次请手动启动一次 LangFix，并在其设置里开启 Launch at Login。"
fi
