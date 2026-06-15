# Signing & releasing Relay

Relay uses **local** notifications (`UNUserNotificationCenter`), so it needs **no**
push entitlement and **no** provisioning profile. Signing exists only to give the
app a stable, trusted identity.

## Use it now (no Developer ID needed)
Builds the universal Go helper + the app, signs with your *Apple Development* cert,
installs to `/Applications`, runs:
```bash
scripts/run-native.sh
```
Grant **Notifications**/**Microphone** on first launch. Because it's signed with a
stable identity, those permissions persist across rebuilds. This is all you need to
start using Relay yourself.

> Set `DEVELOPMENT_TEAM` in `project.yml` to your own Apple Developer team id first.

## Make a notarized, shareable build
One-time setup (needs your own Apple Developer account + paid membership):

1. **Create a Developer ID Application certificate**
   Xcode → Settings → Accounts → select your team → *Manage Certificates…*
   → **＋** → **Developer ID Application**.

2. **Store notary credentials** as a keychain profile. Generate an app-specific
   password at <https://appleid.apple.com> → Sign-In & Security → App-Specific
   Passwords, then:
   ```bash
   xcrun notarytool store-credentials relay-notary \
     --apple-id "<your-apple-id-email>" --team-id "<YOUR_TEAM_ID>" --password "<app-specific-password>"
   ```
   (The release script reads the team id from its `TEAM` variable — set it to your own.)

Then, any time you want a distributable build:
```bash
scripts/release.sh
```
It builds the universal Go helper + app → bundles + signs with Developer ID + hardened
runtime + secure timestamp → notarizes (waits for Apple) → staples → outputs a notarized
`dist/Relay.app`, a drag-to-Applications `dist/Relay.dmg`, and `dist/Relay.zip` that run
warning-free on any Mac. Publish with `gh release create` (the script prints the command).

## Auto-update (Sparkle)

Relay ships with [Sparkle](https://sparkle-project.org): it checks a signed `appcast.xml`
on GitHub Releases in the background and offers a one-click in-app update — users never
visit GitHub. Wiring is already done (SPM dependency + `SUFeedURL`/`SUPublicEDKey` in the
generated `Info.plist`, pointing at `releases/latest/download/appcast.xml`).

**One-time:** the EdDSA signing keypair is generated with Sparkle's `generate_keys`
(private key stays in your login Keychain; the public key is `SUPublicEDKey` in
`project.yml`). The Sparkle CLI tools (`generate_keys`, `generate_appcast`, `sign_update`)
come from the Sparkle release tarball — `release.sh` looks for them in `.sparkle-tools/`
(git-ignored) or the resolved SPM artifacts. To (re)fetch:
```bash
TAG=$(gh release view --repo sparkle-project/Sparkle --json tagName -q .tagName)
mkdir -p .sparkle-tools && cd .sparkle-tools
curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$TAG/Sparkle-$TAG.tar.xz" | tar -xJ
```

**Each release:**
1. Bump `MARKETING_VERSION` **and** `CURRENT_PROJECT_VERSION` in `project.yml`
   (Sparkle compares `CURRENT_PROJECT_VERSION` to decide what's newer).
2. `scripts/release.sh` → produces `dist/Relay.dmg`, `dist/Relay.zip`, and a signed
   `dist/appcast.xml`, and prints the exact `gh release create vX …` command.
3. Run that command. The tag **must** be `v<MARKETING_VERSION>` so the appcast's
   download URLs resolve. Uploading `appcast.xml` to the latest release is what triggers
   everyone's auto-update.

## Notes
- `project.yml` uses **Automatic** signing for the Xcode IDE (Run just works when you're
  signed into your Developer account). The release script re-signs with explicit
  `codesign`, so it never depends on provisioning profiles.
- Entitlements (`RelayNative/RelayNative.entitlements`) cover hardened-runtime JIT +
  microphone access; the app is not sandboxed (direct distribution only).
