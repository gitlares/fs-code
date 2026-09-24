#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$repo_dir/dist/FS Code.app"
release_dir="${FS_CODE_RELEASE_DIR:-$repo_dir/dist/release}"
signing_identity="${FS_CODE_SIGN_IDENTITY:-}"
notary_profile="${FS_CODE_NOTARY_PROFILE:-}"

if [[ -z "$signing_identity" ]]; then
    printf 'Set FS_CODE_SIGN_IDENTITY to a Developer ID Application signing identity.\n' >&2
    exit 1
fi

FS_CODE_SIGN_IDENTITY="$signing_identity" bash "$repo_dir/scripts/build-app.sh"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
mkdir -p "$release_dir"
archive="$release_dir/FS-Code-$version.zip"

package_archive() {
    rm -f "$archive"
    ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$archive"
}

package_archive

if [[ -n "$notary_profile" ]]; then
    xcrun notarytool submit "$archive" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$app_dir"
    xcrun stapler validate "$app_dir"
    package_archive
fi

printf 'Release archive: %s\n' "$archive"
