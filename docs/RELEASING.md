# Releasing

Pushing a tag like `v0.2.0` builds StarDash, signs it with the Developer ID certificate,
notarizes the disk image with Apple and attaches it to a GitHub release. The release notes are
that version's section of [CHANGELOG.md](../CHANGELOG.md), so first rename `[Unreleased]` to the
new version with today's date, start a fresh `[Unreleased]` above it, update the compare links at
the bottom and commit.

```sh
git tag v0.2.0
git push origin v0.2.0
```

## One-time setup

The signing material lives in a GitHub environment called `release`. Pull requests, forks and
any workflow outside that environment can't read it.

1. Settings > Environments > New environment, name it `release`.
   - Deployment branches and tags: "Selected", add the tag rule `v*`.
   - Required reviewers: yourself, if you want to approve each release before it signs anything.
2. Export the certificate. In Keychain Access, find "Developer ID Application: …", right-click,
   Export, save as `.p12` with a strong password. Then:
   ```sh
   base64 -i DeveloperID.p12 | pbcopy
   ```
   Add environment secrets `MACOS_CERT_P12` (the pasted text) and `MACOS_CERT_PASSWORD`.
   Delete the `.p12` file afterwards.
3. Create a notarization key. App Store Connect > Users and Access > Integrations >
   App Store Connect API > Team Keys, add a key with the Developer role and download the `.p8`
   (Apple lets you download it once). Then:
   ```sh
   base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
   ```
   Add environment secrets `NOTARY_KEY` (the pasted text), `NOTARY_KEY_ID` (the key ID) and
   `NOTARY_ISSUER` (the issuer ID shown above the key list).
4. Settings > Actions > General > Fork pull request workflows: choose
   "Require approval for all external contributors".
5. Optional: Settings > Rules > Rulesets, add a tag ruleset for `v*` that only admins can bypass,
   so only you can cut a release.

If a key leaks, revoke the API key in App Store Connect and the certificate in the Apple
Developer portal, then replace the secrets.
