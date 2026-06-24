# Releasing

`agent-wrap` is distributed as a prebuilt binary via the Homebrew tap
[andreichenchik/homebrew-tap](https://github.com/andreichenchik/homebrew-tap):

```bash
brew install andreichenchik/tap/agent-wrap
```

## Cut a release

```bash
make release VERSION=0.1.0
```

`make release` builds and signs the release binary, packages it into
`dist/agent-wrap-<version>-arm64-macos.tar.gz`, creates the `v<version>` GitHub release in
this repo and uploads the tarball, then clones the tap repo, bumps the formula's `version` and
`sha256`, and commits + pushes it. After it finishes, `brew install andreichenchik/tap/agent-wrap`
serves the new version.

Requirements: `gh` authenticated with push access to both repos, and an Apple silicon Mac (the
binary is arm64 only).

## First release after the `container-primer` rename (one-time)

`make release` only bumps an existing `Formula/agent-wrap.rb`. Before the first `agent-wrap` release,
prepare the tap repo once so existing users migrate automatically:

1. Rename the GitHub repo `andreichenchik/container-primer` → `andreichenchik/agent-wrap` (GitHub
   redirects old URLs, so prior release tarballs keep resolving).
2. In the tap repo, add `Formula/agent-wrap.rb` (class `AgentWrap`, `bin.install "agent-wrap"`),
   remove `Formula/container-primer.rb`, and add `tap_migrations.json` at the repo root:

   ```json
   { "container-primer": "andreichenchik/tap/agent-wrap" }
   ```

   After `brew update`, `brew upgrade` then replaces an installed `container-primer` with `agent-wrap`.

From then on, `make release VERSION=…` keeps the formula current.

## Signing

The binary is **ad-hoc** signed with the `com.apple.security.virtualization` entitlement (same as
`make build-release`). This is sufficient for Homebrew **formula** installs: such downloads are not
quarantined, so Gatekeeper does not block them, and the entitlement is honored under ad-hoc signing
on any Apple silicon Mac.

If a future non-Homebrew download path is added, or Gatekeeper rejects the binary, harden with
Developer ID signing + notarization:

```bash
codesign --force --options runtime --sign "Developer ID Application: …" \
  --entitlements AgentWrap.entitlements .build/release/agent-wrap
xcrun notarytool submit dist/<tarball> --keychain-profile … --wait
```
