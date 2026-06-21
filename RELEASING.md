# Releasing

`container-primer` is distributed as a prebuilt binary via the Homebrew tap
[andreichenchik/homebrew-tap](https://github.com/andreichenchik/homebrew-tap):

```bash
brew install andreichenchik/tap/container-primer
```

## Cut a release

```bash
make release VERSION=0.1.0
```

`make release` builds and signs the release binary, packages it into
`dist/container-primer-<version>-arm64-macos.tar.gz`, creates the `v<version>` GitHub release in
this repo and uploads the tarball, then clones the tap repo, bumps the formula's `version` and
`sha256`, and commits + pushes it. After it finishes, `brew install andreichenchik/tap/container-primer`
serves the new version.

Requirements: `gh` authenticated with push access to both repos, and an Apple silicon Mac (the
binary is arm64 only).

## Signing

The binary is **ad-hoc** signed with the `com.apple.security.virtualization` entitlement (same as
`make build-release`). This is sufficient for Homebrew **formula** installs: such downloads are not
quarantined, so Gatekeeper does not block them, and the entitlement is honored under ad-hoc signing
on any Apple silicon Mac.

If a future non-Homebrew download path is added, or Gatekeeper rejects the binary, harden with
Developer ID signing + notarization:

```bash
codesign --force --options runtime --sign "Developer ID Application: …" \
  --entitlements ContainerPrimer.entitlements .build/release/ContainerPrimer
xcrun notarytool submit dist/<tarball> --keychain-profile … --wait
```
