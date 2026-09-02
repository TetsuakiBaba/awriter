#!/bin/bash
#
# AWriter リリースビルド
#
#   scripts/release.sh                … ビルド → 署名 → 公証 → DMG 作成
#   scripts/release.sh --skip-notarize … 公証を飛ばす(手元確認用)
#   scripts/release.sh --publish       … 公証まで通した DMG を GitHub Releases に上げる
#
# 公証には初回だけ資格情報の登録が必要(App 用パスワードは appleid.apple.com で発行):
#   xcrun notarytool store-credentials "AWriter" \
#     --apple-id <Apple ID> --team-id ZE8M4T49DP --password <App 用パスワード>

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

TEAM_ID="ZE8M4T49DP"
IDENTITY="Developer ID Application: TETSUAKI BABA ($TEAM_ID)"
KEYCHAIN_PROFILE="AWriter"

BUILD_DIR="$PROJECT_DIR/build"
DIST_DIR="$PROJECT_DIR/dist"
APP="$BUILD_DIR/Release/AWriter.app"

SKIP_NOTARIZE=0
PUBLISH=0
for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE=1 ;;
        --publish) PUBLISH=1 ;;
        *) echo "不明なオプション: $arg" >&2; exit 1 ;;
    esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- ビルド

step "ビルド(arm64 + x86_64 ユニバーサル)"
rm -rf "$BUILD_DIR/Release"
xcodebuild -project AWriter.xcodeproj -target AWriter -configuration Release \
    -arch arm64 -arch x86_64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    SYMROOT="$BUILD_DIR" \
    build | grep -E '^\*\* |error:' || true

[ -d "$APP" ] || { echo "ビルドに失敗しました" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$DIST_DIR/AWriter-$VERSION.dmg"
mkdir -p "$DIST_DIR"

step "署名の確認"
codesign --verify --strict --verbose=2 "$APP"
lipo -info "$APP/Contents/MacOS/AWriter"

# ---------------------------------------------------------------- 公証

has_credentials() {
    xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1
}

if [ "$SKIP_NOTARIZE" -eq 0 ] && ! has_credentials; then
    cat >&2 <<EOS

公証の資格情報が見つかりません。初回だけ次を実行してください:

  xcrun notarytool store-credentials "$KEYCHAIN_PROFILE" \\
    --apple-id <Apple ID> --team-id $TEAM_ID --password <App 用パスワード>

公証なしで続ける場合は --skip-notarize を付けて実行してください。
EOS
    exit 1
fi

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    step "アプリを公証"
    ZIP="$DIST_DIR/AWriter-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait
    rm -f "$ZIP"

    step "アプリにチケットを添付"
    xcrun stapler staple "$APP"
fi

# ---------------------------------------------------------------- DMG

step "DMG を作成"
STAGING="$DIST_DIR/staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "AWriter" -srcfolder "$STAGING" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGING"

step "DMG に署名"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

if [ "$SKIP_NOTARIZE" -eq 0 ]; then
    step "DMG を公証"
    xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait
    xcrun stapler staple "$DMG"

    step "Gatekeeper の判定"
    spctl -a -vvv -t install "$DMG" || true
fi

printf '\n\033[1m完成: %s\033[0m\n' "$DMG"

# ---------------------------------------------------------------- 公開

if [ "$PUBLISH" -eq 1 ]; then
    if [ "$SKIP_NOTARIZE" -eq 1 ]; then
        echo "公証していない DMG は公開しません" >&2
        exit 1
    fi
    step "GitHub Releases に公開 (v$VERSION)"
    gh release create "v$VERSION" "$DMG" \
        --title "AWriter $VERSION" \
        --notes "macOS 14 以降。ダウンロードして AWriter.app を「アプリケーション」へドラッグしてください。"
    echo "公開しました"
else
    cat <<EOS

GitHub Releases に上げるには:

  gh release create v$VERSION "$DMG" --title "AWriter $VERSION" --notes "..."

または scripts/release.sh --publish
EOS
fi
