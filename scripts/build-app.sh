#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"

swift build --build-system native -c release
bash "$repo_dir/scripts/build-icon.sh"
binary_dir="$(swift build --build-system native -c release --show-bin-path)"
app_dir="$repo_dir/dist/FS Code.app"
sparkle_framework="$repo_dir/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
feed_url="${FS_CODE_SU_FEED_URL:-}"
public_key="${FS_CODE_SU_PUBLIC_ED_KEY:-}"
signing_identity="${FS_CODE_SIGN_IDENTITY:-}"
signing_keychain="${FS_CODE_SIGN_KEYCHAIN:-}"

if [[ -n "$feed_url" || -n "$public_key" ]]; then
    if [[ -z "$feed_url" || -z "$public_key" || ! "$feed_url" =~ ^https://[^[:space:]/?#]+(/|$) ]]; then
        printf 'FS_CODE_SU_FEED_URL (HTTPS) and FS_CODE_SU_PUBLIC_ED_KEY must be configured together.\n' >&2
        exit 1
    fi
    if ! public_key_length="$(printf '%s' "$public_key" | base64 -D | wc -c | tr -d '[:space:]')" || [[ "$public_key_length" != "32" ]]; then
        printf 'FS_CODE_SU_PUBLIC_ED_KEY must be a Base64-encoded 32-byte Ed25519 public key.\n' >&2
        exit 1
    fi
fi

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Frameworks"
cp "$binary_dir/FSCode" "$app_dir/Contents/MacOS/FSCode.next"
mv -f "$app_dir/Contents/MacOS/FSCode.next" "$app_dir/Contents/MacOS/FSCode"
ditto "$binary_dir/SwiftTerm_SwiftTerm.bundle" "$app_dir/Contents/Resources/SwiftTerm_SwiftTerm.bundle"
cp "$repo_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$repo_dir/.build/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
cp "$repo_dir/LICENSE.txt" "$app_dir/Contents/Resources/LICENSE.txt"
cp "$repo_dir/Resources/ThirdPartyNotices.txt" "$app_dir/Contents/Resources/ThirdPartyNotices.txt"
ditto "$sparkle_framework" "$app_dir/Contents/Frameworks/Sparkle.framework"

if [[ -n "$feed_url" || -n "$public_key" ]]; then
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $feed_url" "$app_dir/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $public_key" "$app_dir/Contents/Info.plist"
fi

rpaths="$(otool -l "$app_dir/Contents/MacOS/FSCode")"
if ! grep -F '@executable_path/../Frameworks' <<< "$rpaths" > /dev/null; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$app_dir/Contents/MacOS/FSCode"
fi

if [[ -z "$signing_identity" ]]; then
    codesign --force --deep --sign - "$app_dir/Contents/Frameworks/Sparkle.framework"
    codesign --force --sign - "$app_dir"
    printf 'Aplicación ad-hoc: %s\n' "$app_dir"
    exit 0
fi

sign_runtime() {
    if [[ -n "$signing_keychain" ]]; then
        codesign --force --sign "$signing_identity" --options runtime --timestamp \
            --keychain "$signing_keychain" "$1"
    else
        codesign --force --sign "$signing_identity" --options runtime --timestamp "$1"
    fi
}

sign_downloader_service() {
    if [[ -n "$signing_keychain" ]]; then
        codesign --force --sign "$signing_identity" --options runtime --timestamp \
            --preserve-metadata=entitlements --keychain "$signing_keychain" "$1"
    else
        codesign --force --sign "$signing_identity" --options runtime --timestamp \
            --preserve-metadata=entitlements "$1"
    fi
}

sparkle_dir="$app_dir/Contents/Frameworks/Sparkle.framework/Versions/B"
sign_runtime "$sparkle_dir/XPCServices/Installer.xpc"
sign_downloader_service "$sparkle_dir/XPCServices/Downloader.xpc"
sign_runtime "$sparkle_dir/Autoupdate"
sign_runtime "$sparkle_dir/Updater.app"
sign_runtime "$app_dir/Contents/Resources/SwiftTerm_SwiftTerm.bundle"
sign_runtime "$app_dir/Contents/Frameworks/Sparkle.framework"
sign_runtime "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"
printf 'Aplicación Developer ID firmada: %s\n' "$app_dir"
