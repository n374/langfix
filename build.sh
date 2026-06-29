#!/bin/zsh
# 构建 LangFix：swift build 产出可执行文件 → 组装成 .app bundle（含 Info.plist）→ ad-hoc 签名。
# 用法：
#   ./build.sh            # release 构建并组装到 build/LangFix.app
#   ./build.sh debug      # debug 构建
#   ./build.sh dmg        # 构建 + 打包成可拖拽安装的 dist/LangFix-<版本>.dmg（推荐交付物）
#   ./build.sh install    # 构建 + 安装到 /Applications 并注册 Service
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-app}"
CONFIG="release"
[ "$MODE" = "debug" ] && CONFIG="debug"

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

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0.0)"
echo "==> 完成：$APP (v$VERSION)"

case "$MODE" in
  dmg)
    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"   # 拖拽目标
    mkdir -p dist
    DMG="dist/LangFix-$VERSION.dmg"
    rm -f "$DMG"
    echo "==> 打包 $DMG"
    hdiutil create -volname "LangFix" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGE"
    echo "==> 交付物：$DMG"
    echo "    打开后把 LangFix 拖到 Applications 即装；首次启动若被拦，右键 → 打开。"
    ;;
  install)
    DEST="/Applications/LangFix.app"
    echo "==> 安装到 $DEST"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" || true
    /System/Library/CoreServices/pbs -update || true
    echo "==> 已安装。请手动启动一次 LangFix，并在设置里开启 Launch at Login。"
    ;;
  app|debug)
    ;;
  *)
    echo "未知参数: $MODE（可选 debug|dmg|install）" >&2; exit 2 ;;
esac
