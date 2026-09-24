# Releasing FS Code

The application targets macOS 15+. `build-app.sh` builds for the host architecture; the first alpha artifact is for Apple Silicon (arm64), not a universal binary.

## Local build

```sh
bash scripts/build-app.sh
```

This defaults to ad-hoc signing for development. No RTK installation is required.

## Developer ID distribution

Install your Developer ID Application certificate/private key in your macOS Keychain. Store notarization credentials using Apple's `xcrun notarytool store-credentials` interactive workflow. Never put private keys or passwords in the repository.

```sh
export FS_CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
# Optional: restrict codesign identity lookup to one keychain.
export FS_CODE_SIGN_KEYCHAIN="/path/to/selected.keychain-db"
export FS_CODE_NOTARY_PROFILE="your-notary-profile"
bash scripts/release-sign.sh
```

`FS_CODE_SIGN_IDENTITY` may also be an unambiguous certificate hash. Set `FS_CODE_SIGN_KEYCHAIN` only when identity lookup must be restricted to a specific keychain; the script does not choose one by default. The script signs nested Sparkle components, the framework, and the application with hardened runtime and a secure timestamp. The application signature seals the SwiftTerm resource bundle. It then creates an architecture-specific ZIP, submits it to Apple, staples the ticket, and recreates the ZIP. If `FS_CODE_NOTARY_PROFILE` is omitted, the artifact is signed but **not notarized**.

Verify before publishing:

```sh
codesign --verify --deep --strict "dist/FS Code.app"
xcrun stapler validate "dist/FS Code.app"
spctl --assess --type execute --verbose=2 "dist/FS Code.app"
shasum -a 256 dist/release/*.zip
```

Run relevant tests and launch the signed app. Publish source matching the binary, release notes, architecture/minimum system version, and a checksum. Mark alpha releases as prereleases. Increment the bundle build number for subsequent releases.

## Updates

Sparkle is bundled but the first release does not activate an update channel. Automatic update checks and installation are disabled by default.

To configure a future release, supply both `FS_CODE_SU_FEED_URL` (HTTPS) and `FS_CODE_SU_PUBLIC_ED_KEY` (Base64 Ed25519 public key). Keep the private update key outside source control. Generate a signed appcast using Sparkle's official tooling and test an upgrade between two actual releases before advertising automatic updates.

Developer ID signing and Sparkle update signing are distinct. A notarized application alone does not establish an update channel.
