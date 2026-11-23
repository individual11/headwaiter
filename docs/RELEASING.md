# Releasing

For maintainers. `scripts/release.sh` builds a universal app, signs it with Developer ID and the hardened runtime, packs a DMG, notarizes it and writes the signed update feed. It publishes nothing. `scripts/release.sh --dry-run` does everything except Developer ID signing and notarization.

One-time setup, with your own Apple Developer account:

1. Create a **Developer ID Application** certificate (Xcode or developer.apple.com) and import it into your login keychain. If `security find-identity -v -p codesigning` doesn't list it, install Apple's Developer ID G2 intermediate certificate.
2. Store notarization credentials under the keychain profile `headwaiter-notary`:

```bash
xcrun notarytool store-credentials headwaiter-notary --apple-id <you> --team-id <TEAMID>
```

3. Create the update signing key. Sparkle keeps the private half in your login keychain and prints the public half:

```bash
swift package resolve && .build/artifacts/sparkle/Sparkle/bin/generate_keys --account headwaiter
```

Put the public key alone in `Resources/sparkle-public-key.txt` and commit it. Back up the private key somewhere safe, such as a password manager: installed copies only accept updates signed with it. Anyone who has it could sign an update.

Never commit certificates, private keys or passwords.

## Each release

1. In `scripts/build-app.sh`, raise `version` and `build` (Sparkle compares `build`).
2. Write `docs/releases/<version>.md`. It becomes the GitHub release notes and what Sparkle shows.
3. Merge to `main`, then run `scripts/release.sh`. Test the DMG it prints.
4. Create the release with all three files, using the tag `v<version>`:

```bash
gh release create v0.5 build/updates/Headwaiter-0.5.dmg build/updates/Headwaiter.dmg build/updates/appcast.xml --title "Headwaiter 0.5" --notes-file docs/releases/0.5.md
```

- **All three files, every time.** Installed copies read `releases/latest/download/appcast.xml`, and the website links to `releases/latest/download/Headwaiter.dmg`. A latest release missing one breaks update checks or the download.
- **Don't mark it as a pre-release,** even for a beta. GitHub's `latest` skips those.
- **Don't edit `appcast.xml`.** Its signature would no longer match.

## Testing an update

Build a copy that thinks it's older, install it, then choose Check for Updates from the right-click menu:

```bash
VERSION=0.3 BUILD=3 UPDATES=1 scripts/build-app.sh release
```

That copy is signed with the local development certificate, so macOS may ask for folder access again after it updates.
