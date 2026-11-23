# Contributing

Bug reports, captures and pull requests are welcome. For a larger feature, open an issue first so we can agree on the shape.

## Building and testing

You need macOS 15 or later and Swift 6 (Xcode 16 or later). There are no dependencies.

```bash
swift test
scripts/build-app.sh debug
open build/Headwaiter.app
```

`scripts/make-dev-cert.sh` is optional. It adds a local self-signed certificate to your keychain so macOS privacy permissions survive rebuilds; the script says how to undo it.

## Pull requests

- Branch from `main`, one change per pull request.
- Add a test for detection or stop changes. Stop must never signal anything above a server's own root (shells, orchestrators, agents).
- Keep runtime knowledge in a `RuntimeProfile`; see "Adding a runtime" in the [README](README.md#adding-a-runtime).
- For UI changes, include a screenshot. `HW_SNAPSHOT=<existing folder> .build/debug/Headwaiter` renders every state with sample data.

## Captures

If a server is missing, misnamed, or grouped wrongly, right-click the menu bar icon and choose **Capture Diagnostics**. The capture is saved to `~/Library/Application Support/Headwaiter/Captures`.

**Read a capture before sharing it.** Only your home folder is anonymized. It still contains folder and project names, full command lines (including any tokens or environment variables passed on them), and the contents of manifests such as `package.json`. Rename anything private and cut manifests down to what matters.
