#!/bin/bash
# Reuse a completed build; validate the binary platform; normalize display metadata on a COPY.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."
REUSE_LATEST=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root)
      [[ $# -ge 2 ]] || { printf '%s\n' '--project-root 后需要项目目录。' >&2; exit 1; }
      PROJECT_ROOT="$2"; shift 2 ;;
    --reuse-latest) REUSE_LATEST=true; shift ;;
    *) printf '不支持的参数：%s\n' "$1" >&2; exit 1 ;;
  esac
done
[[ "$(uname -s)" == 'Darwin' ]] || { printf '%s\n' '请在装有完整 Xcode 的 Mac 上运行。' >&2; exit 1; }
cd "$PROJECT_ROOT"
PROJECT="L'écho.xcodeproj"
APP_NAME="L'écho"
[[ -f "$PROJECT/project.pbxproj" ]] || { printf '未找到工程：%s/%s\n' "$PWD" "$PROJECT" >&2; exit 1; }
if ! xcodebuild -version >/dev/null 2>&1; then
  printf '%s\n' '请先打开完整 Xcode，完成首次组件安装，并在设置中选择 Command Line Tools。' >&2
  exit 1
fi
APP_BUNDLE=''
if [[ "$REUSE_LATEST" == true ]]; then
  for candidate in "$PWD"/work/Sideload-*/DerivedData/Build/Products/Release-iphoneos/*.app; do
    [[ -f "$candidate/Info.plist" ]] || continue
    if [[ -z "$APP_BUNDLE" || "$candidate" -nt "$APP_BUNDLE" ]]; then APP_BUNDLE="$candidate"; fi
  done
  if [[ -z "$APP_BUNDLE" ]]; then
    printf '%s\n' '未找到之前编译好的真机 .app。请确认项目目录；需要新编译时去掉 --reuse-latest。' >&2
    exit 1
  fi
  printf '复用已编译程序（不重新编译）：%s\n' "$APP_BUNDLE"
fi
RUN_ROOT="$PWD/work/Sideload-$(date +%Y%m%d-%H%M%S)-$$"
[[ ! -e "$RUN_ROOT" ]] || { printf '%s\n' '输出目录已存在，原文件未覆盖。' >&2; exit 1; }
mkdir -p "$RUN_ROOT"
if [[ "$REUSE_LATEST" == false ]]; then
  printf '%s\n' '正在编译 iPad 真机 Release；无需填写开发者团队或购买会员。'
  if ! xcodebuild -project "$PROJECT" -scheme "$APP_NAME" \
    -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$RUN_ROOT/DerivedData" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build \
    >"$RUN_ROOT/build.log" 2>&1; then
    printf '%s\n' '编译未通过，尚未生成 IPA。' >&2
    tail -n 100 "$RUN_ROOT/build.log" >&2
    printf '完整日志：%s\n' "$RUN_ROOT/build.log" >&2
    exit 1
  fi
  APP_BUNDLE="$RUN_ROOT/DerivedData/Build/Products/Release-iphoneos/$APP_NAME.app"
fi
PLIST="$APP_BUNDLE/Info.plist"
[[ -f "$PLIST" ]] || { printf '%s\n' '没有找到编译后的 .app，未生成 IPA。' >&2; exit 1; }
plutil -lint "$PLIST" >/dev/null
APP_EXECUTABLE=$(plutil -extract CFBundleExecutable raw -o - "$PLIST")
APP_VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")
APP_IDENTIFIER=$(plutil -extract CFBundleIdentifier raw -o - "$PLIST")
APP_PLATFORM=$(plutil -extract CFBundleSupportedPlatforms.0 raw -o - "$PLIST" 2>/dev/null || printf '%s' '(missing)')
APP_DISPLAY=$(plutil -extract CFBundleDisplayName raw -o - "$PLIST" 2>/dev/null || printf '%s' '(missing)')
printf '原平台字段：<%s>\n原显示名：<%s>\n' "$APP_PLATFORM" "$APP_DISPLAY"
[[ "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { printf '%s\n' '版本号无效。' >&2; exit 1; }
[[ -f "$APP_BUNDLE/$APP_EXECUTABLE" ]] || { printf '%s\n' '缺少真实编译程序。' >&2; exit 1; }
APP_ARCHS=$(xcrun lipo -archs "$APP_BUNDLE/$APP_EXECUTABLE")
[[ "$APP_ARCHS" == 'arm64' ]] || { printf '需要 arm64 真机程序，实际为：%s\n' "$APP_ARCHS" >&2; exit 1; }
BUILD_DETAILS=$(xcrun vtool -show-build "$APP_BUNDLE/$APP_EXECUTABLE")
printf '%s\n' "$BUILD_DETAILS" >"$RUN_ROOT/macho-build.txt"
# arm64 alone cannot distinguish an iPad binary from an Apple-silicon simulator binary.
if [[ ! "$BUILD_DETAILS" =~ (^|[[:space:]])platform[[:space:]]+(IOS|2)([[:space:]]|$) ]]; then
  printf '%s\n' '二进制不是 iOS/iPadOS 真机平台，未生成 IPA。实际信息：' "$BUILD_DETAILS" >&2
  exit 1
fi
mkdir -p "$RUN_ROOT/staging/Payload"
STAGED_APP="$RUN_ROOT/staging/Payload/$APP_NAME.app"
ditto "$APP_BUNDLE" "$STAGED_APP"
STAGED_PLIST="$STAGED_APP/Info.plist"
# Separate UTF-8 value arguments preserve the apostrophe; do not compare Unicode normalization forms.
plutil -replace CFBundleDisplayName -string "$APP_NAME" "$STAGED_PLIST" 2>/dev/null || \
  plutil -insert CFBundleDisplayName -string "$APP_NAME" "$STAGED_PLIST"
plutil -replace CFBundleName -string "$APP_NAME" "$STAGED_PLIST" 2>/dev/null || \
  plutil -insert CFBundleName -string "$APP_NAME" "$STAGED_PLIST"
plutil -replace CFBundleSupportedPlatforms -json '["iPhoneOS"]' "$STAGED_PLIST" 2>/dev/null || \
  plutil -insert CFBundleSupportedPlatforms -json '["iPhoneOS"]' "$STAGED_PLIST"
plutil -lint "$STAGED_PLIST" >/dev/null
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$STAGED_PLIST")" == "$APP_IDENTIFIER" ]] || {
  printf '%s\n' '应用身份发生异常变化，已停止。' >&2; exit 1;
}
IPA="$RUN_ROOT/Lecho-$APP_VERSION-unsigned.ipa"
TEMP_IPA="$IPA.partial"
ditto -c -k --norsrc --keepParent "$RUN_ROOT/staging/Payload" "$TEMP_IPA"
unzip -tq "$TEMP_IPA"
unzip -p "$TEMP_IPA" "Payload/$APP_NAME.app/Info.plist" >/dev/null
[[ ! -e "$IPA" ]] || { printf '%s\n' '目标文件已存在，未覆盖。' >&2; exit 1; }
mv "$TEMP_IPA" "$IPA"
shasum -a 256 "$IPA" >"$IPA.sha256"
printf '\n%s\n%s\n' 'IPA 已生成（未签名，交给侧载工具处理）：' "$IPA"
open -R "$IPA" >/dev/null 2>&1 || true
