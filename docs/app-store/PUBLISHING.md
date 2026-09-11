# Publishing Bixel Studio to the Mac App Store

This guide covers building a signed Mac App Store package and uploading it to
App Store Connect with `scripts/publish-appstore.sh`.

The listing copy you must paste into App Store Connect lives in
[`APP_STORE_LISTING.md`](APP_STORE_LISTING.md).

---

## 1. Prerequisites

| Requirement | Notes |
|---|---|
| Apple Developer Program | Paid membership, Team ID from [developer.apple.com/account](https://developer.apple.com/account) → Membership. |
| Xcode | Current stable (project targets macOS 13+, `xcodeVersion: 15.0`). |
| Xcode command line tools | `xcode-select --install`. |
| `xcodegen` | `brew install xcodegen`. |
| `cbindgen` | `cargo install cbindgen` (or `brew install cbindgen`). |
| Rust toolchain | `rustup`. |
| An app record in App Store Connect | Bundle ID `com.bixel.studio` (or your own), created under **My Apps → + → New App**. |
| App Store Connect API key | *Users and Access → Integrations → App Store Connect API → +*. Download the `.p8` **once**. |

> The build embeds the full goose agent, so `scripts/build-rust.sh` needs
> `cmake` (for `aws-lc-rs`) and can take several minutes.

---

## 2. One-time setup in the Apple Developer portal

1. **Register the App ID** — *Certificates, Identifiers & Profiles → Identifiers → +*
   → *App IDs → App*. Choose the explicit bundle ID (`com.bixel.studio`) and
   enable **App Sandbox** and **In-App Purchase** capabilities.
2. **Create certificates** (Keychain Access → Certificate Assistant → Request a
   Certificate From a Certificate Authority first):
   - **Apple Distribution** — signs the app.
   - **Mac Installer Distribution** (`3rd Party Mac Developer Installer`) — signs the `.pkg`.
3. **Create a provisioning profile** — *Profiles → + → Mac App Store* → select
   the App ID and the Apple Distribution certificate. Download and double-click to
   install. Note the exact **profile name** for `APPSTORE_PROVISIONING_PROFILE`.
4. **Create the app record** in App Store Connect (bundle ID above). Fill in the
   listing fields from [`APP_STORE_LISTING.md`](APP_STORE_LISTING.md).

---

## 3. Configure production and deployment environments

The RevenueCat public SDK key is selected separately from the App Store Connect
credentials. Put the production key in `.env`:

```dotenv
REVENUECAT_API_KEY=appl_your_production_public_sdk_key
```

Local/DMG builds use `.env.dev` instead. The repository provides
`.env.dev.example` with the RevenueCat test key. Both files are gitignored.

The publish script loads `.env` automatically, while App Store Connect
credentials continue to come from `.env.deploy`:

```bash
cp .env.example .env
cp .env.deploy.example .env.deploy
$EDITOR .env
$EDITOR .env.deploy
```

You can override the production file for CI or a rehearsal with
`BIXEL_PRODUCTION_ENV=/path/to/.env`.

Minimum fields:

```dotenv
DEVELOPMENT_TEAM=ABCDE12345
APPSTORE_BUNDLE_ID=com.bixel.studio
APPSTORE_VERSION=1.0.0
APPSTORE_SIGNING_STYLE=manual
APPSTORE_CODE_SIGN_IDENTITY="Apple Distribution"
APPSTORE_PROVISIONING_PROFILE="Bixel Studio App Store"
APPSTORE_API_KEY_ID=ABC123DEFG
APPSTORE_API_ISSUER_ID=00000000-0000-0000-0000-000000000000
```

Put the API private key where `altool` can find it:

```bash
mkdir -p private_keys
cp ~/Downloads/AuthKey_ABC123DEFG.p8 private_keys/
```

`private_keys/`, `.env`, `.env.dev`, and `.env.deploy` are gitignored — never
commit them.

> Prefer Apple ID auth? Leave the API fields empty and set
> `APPSTORE_APPLE_ID` + `APPSTORE_APP_SPECIFIC_PASSWORD` (generate the
> app-specific password at [appleid.apple.com](https://appleid.apple.com) →
> Sign-In and Security). The API key is recommended because it is not tied to a
> person and does not expire every few months.

---

## 4. Build + publish

```bash
# Full pipeline: version bump → xcodegen → Rust → archive → export .pkg → validate → upload
scripts/publish-appstore.sh

# Bump explicitly
scripts/publish-appstore.sh --version 1.0.1 --build-number 42

# Build + validate the .pkg but do not upload (safe rehearsal)
scripts/publish-appstore.sh --skip-upload

# Re-upload the last exported .pkg without rebuilding
scripts/publish-appstore.sh --skip-build

# Stop after the .xcarchive (debug signing/entitlements issues)
scripts/publish-appstore.sh --archive-only

# Upload, then create + push the git tag v1.0.1
scripts/publish-appstore.sh --git-push

# Show the resolved configuration without touching anything
scripts/publish-appstore.sh --dry-run
```

The script performs, in order:

1. Loads `.env` (or `$BIXEL_PRODUCTION_ENV`) for the production RevenueCat key.
2. Loads `.env.deploy` (or `$BIXEL_DEPLOY_ENV`) for App Store Connect settings.
3. Writes `CFBundleShortVersionString` / `CFBundleVersion` into `project.yml`.
4. `xcodegen generate`.
5. `scripts/build-rust.sh` (release static lib + cbindgen header).
6. Writes `build/appstore/ExportOptions.plist` (`method: app-store-connect`).
7. `xcodebuild archive` with the App Sandbox entitlements and production key.
8. `xcodebuild -exportArchive` → `build/appstore/export/Bixel.pkg`.
9. `xcrun altool --validate-app` then `--upload-app`.
10. Optionally tags and pushes `vX.Y.Z`.

Artifacts land in `build/appstore/` (gitignored):

```
build/appstore/Bixel.xcarchive
build/appstore/ExportOptions.plist
build/appstore/export/Bixel.pkg
```

After upload, open **App Store Connect → My Apps → Bixel Studio → TestFlight**.
Once processing finishes, attach the build to a version and submit for review.

---

## 5. Versioning

- `CFBundleShortVersionString` = marketing version (`APPSTORE_VERSION`).
- `CFBundleVersion` = build number (`APPSTORE_BUILD_NUMBER`); defaults to the git
  commit count when unset.
- The build number must increase for every upload of the same marketing version.
- The script commits nothing. Commit the `project.yml` version bump yourself if
  you want it tracked, then use `--git-push` to publish the tag.

---

## 6. Publish from Xcode (GUI)

You can do the whole build-and-upload flow in Xcode instead of the script. This is
the recommended path the first time, because Xcode reports signing problems
clearly.

### 6.1 Prepare the project

```bash
# Bump the version in project.yml if you want it tracked
xcodegen generate
open Bixel.xcodeproj
```

The Rust engine is rebuilt automatically by the **Build Rust engine** pre-build
phase (`scripts/build-rust.sh`), so the first build may take several minutes.

### 6.2 Add your Apple ID to Xcode

*Xcode → Settings → Accounts → + → Apple ID* and sign in with the Apple ID tied
to your Apple Developer team. This is what lets Xcode create/download
certificates and provisioning profiles for you.

### 6.3 Configure signing & capabilities

1. Select the **Bixel** project in the navigator → the **Bixel** target →
   **Signing & Capabilities** tab.
2. Set **Team** to your Developer team.
3. Tick **Automatically manage signing**. Xcode creates the *Mac App Store*
   provisioning profile and the *Apple Distribution* certificate if missing.
4. Confirm the **App Sandbox** capability is listed, with both **Outgoing
   Connections (Client)** and **Incoming Connections (Server)** enabled. The
   repo ships the entitlements at `app/Bixel/Bixel-AppStore.entitlements`, and
   `project.yml` wires them into the **Release** configuration via
   `CODE_SIGN_ENTITLEMENTS` (Debug/dev builds stay unsandboxed). Add **In-App
   Purchase** as a capability as well.
5. Make sure **Hardened Runtime** is enabled (it is set in `project.yml`).

> `project.yml` is the source of truth and `Bixel.xcodeproj` is generated. Any
> capability you add through the Xcode UI is lost the next time you run
> `xcodegen generate`. If you need a capability permanently, add the matching
> entitlement to `app/Bixel/Bixel-AppStore.entitlements` (and, if it needs an
> App ID toggle, enable it in the Developer portal).

### 6.4 Archive

1. At the top of the window set the scheme to **Bixel** and the destination to
   **My Mac** (or *Any Mac*).
2. *Product → Build* once to shake out compile errors.
3. *Product → Archive* (this always builds in **Release**). The Organizer opens
   when it finishes; if not, *Window → Organizer → Archives*.

### 6.5 Validate and upload

1. In the Organizer select the new archive → **Distribute App**.
2. Choose **App Store Connect** → **Upload**.
3. Review the summary (bundle ID, version, build, team) and the **App Sandbox**
   entitlements shown. Fix anything red here rather than after upload.
4. Options:
   - **Upload your app's symbols** — leave checked (needed for crash reports).
   - **Manage the version number and build number** — leave unchecked so the
     version from `project.yml` is used.
   - **Strip Swift symbols** — optional; leaving it unchecked is fine.
5. **Upload**. Xcode validates the `.pkg` and uploads it. Sign in with your App
   Store Connect API key or Apple ID if prompted.

### 6.6 Alternative: export a `.pkg` and use Transporter

Use this when you want to inspect the package or when Xcode's direct upload is
unavailable.

1. *Product → Archive* → **Distribute App** → **App Store Connect** →
   **Export**.
2. Choose an output folder; Xcode produces `Bixel.pkg`.
3. Open the **Transporter** app (free on the Mac App Store), drag `Bixel.pkg`
   in, and click **Deliver**. Or use `altool`:

   ```bash
   xcrun altool --validate-app Bixel.pkg \
     --api-key ABC123DEFG --api-issuer 00000000-0000-0000-0000-000000000000
   xcrun altool --upload-app -f Bixel.pkg \
     --api-key ABC123DEFG --api-issuer 00000000-0000-0000-0000-000000000000
   ```

   (Put `AuthKey_ABC123DEFG.p8` in `./private_keys/` first. On older Xcode use
   `--apiKey`/`--apiIssuer` and add `-t macos`.)

### 6.7 After upload

Open **App Store Connect → My Apps → Bixel Studio → TestFlight** (or **Builds**).
Processing takes 5–30 minutes. When it is ready:

1. Go to the **App Store** tab → your version → **Build** → select the build.
2. Complete the listing from [`APP_STORE_LISTING.md`](APP_STORE_LISTING.md).
3. Click **Submit for Review**.

### 6.8 Command-line equivalent

The same steps headlessly (what `scripts/publish-appstore.sh` wraps):

```bash
xcodebuild archive -project Bixel.xcodeproj -scheme Bixel \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath build/appstore/Bixel.xcarchive \
  DEVELOPMENT_TEAM=ABCDE12345 \
  CODE_SIGN_ENTITLEMENTS=app/Bixel/Bixel-AppStore.entitlements

xcodebuild -exportArchive -archivePath build/appstore/Bixel.xcarchive \
  -exportPath build/appstore/export \
  -exportOptionsPlist build/appstore/ExportOptions.plist
```

---

## 7. Troubleshooting

| Symptom | Fix |
|---|---|
| `No signing certificate "Apple Distribution" found` | Install the cert (double-click the `.cer`), or set `APPSTORE_SIGNING_STYLE=automatic`. |
| `Provisioning profile ... doesn't include ...` | Recreate the Mac App Store profile for the exact bundle ID and install it; verify `APPSTORE_PROVISIONING_PROFILE` matches its name. |
| `altool: Invalid API key` / `Unable to find API key` | The `.p8` must be named `AuthKey_<KEYID>.p8` inside `./private_keys/`. |
| `Invalid Signature. Code object is not signed at all` | The app must be sandboxed; check `CODE_SIGN_ENTITLEMENTS` points at `app/Bixel/Bixel-AppStore.entitlements`. |
| `Missing required icon` / `Invalid Image Path` | `AppIcon` must be a complete macOS set (16–512 @1x/@2x). |
| `The provided entity includes an attribute with a value that has already been used` | Bump `APPSTORE_BUILD_NUMBER`. |
| `Unsupported Toolchain` / Metal errors | `xcodebuild -downloadComponent MetalToolchain`. |
| Rust build fails with `cmake not found` | `brew install cmake`. |
| `method 'app-store-connect' is not supported` | Older Xcode: change `method` to `app-store` in `build/appstore/ExportOptions.plist`. |

---

## 8. Known App Store limitations (review these before submitting)

The Mac App Store **requires the App Sandbox**, which the dev/DMG builds do not
use. Some Bixel features may be rejected or need to be disabled for the Store
build:

- **Subprocess execution** — `crates/bixel-core/src/jobs.rs` and goose's
  developer extension shell out to processes, which the sandbox blocks. Gate or
  remove these for the Store configuration, or the app will fail at runtime /
  review.
- **Arbitrary filesystem access** — everything outside the container must go
  through `NSOpenPanel`/`NSSavePanel` (already the case for projects, sources and
  exports; `paths::safe_resolve` keeps writes inside the chosen base).
- **Network** — both `com.apple.security.network.client` and
  `com.apple.security.network.server` are included. The server entitlement is
  required because Codex OAuth receives its browser callback on
  `localhost:1455`. Regenerate the Mac App Store provisioning profile after
  enabling Incoming Connections (Server), and document the OpenRouter/Codex
  usage in **App Privacy**.
- **In-App Purchases** — the RevenueCat lifetime unlock must be configured in App
  Store Connect and offered for the Store build (external payment links are not
  allowed).

Test the sandboxed archive locally before uploading:

```bash
scripts/publish-appstore.sh --archive-only
open build/appstore/Bixel.xcarchive/Products/Applications/Bixel.app
```

In the sandboxed build, exercise the paths the sandbox restricts: open a
project outside `~/Library/Containers`, run an AI agent turn end-to-end
(provider connect, model-backed skill, artifact write), and confirm no
subprocess-based feature is invoked. If a feature fails, either add the
matching entitlement or gate it out of the Store configuration.

---

## 9. CI (optional)

`.github/workflows/release.yml` currently produces the ad-hoc DMG for GitHub
Releases. To automate App Store uploads, add the `.env.deploy` values as
repository secrets, import the distribution certificate + provisioning profile
into a temporary keychain, then run:

```bash
scripts/publish-appstore.sh --skip-upload=false
```

Keep API keys in GitHub Secrets and write them to `.env.deploy` inside the job —
never commit them.
