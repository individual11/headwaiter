# Releasing

For maintainers. `scripts/release.sh` builds a universal app, signs it with Developer ID and the hardened runtime, notarizes it and packs a DMG. `scripts/release.sh --dry-run` does everything except Developer ID signing and notarization.

One-time setup, with your own Apple Developer account:

1. Create a **Developer ID Application** certificate (Xcode or developer.apple.com) and import it into your login keychain. If `security find-identity -v -p codesigning` doesn't list it, install Apple's Developer ID G2 intermediate certificate.
2. Store notarization credentials under the keychain profile `headwaiter-notary`:

```bash
xcrun notarytool store-credentials headwaiter-notary --apple-id <you> --team-id <TEAMID>
```

Never commit certificates, keys or passwords.
