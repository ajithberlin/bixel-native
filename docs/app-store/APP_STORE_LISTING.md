# App Store Connect — data to enter for Bixel Studio

Copy/paste reference for every field App Store Connect asks for. Suggested copy
is provided; replace anything marked **(your choice)** with your own.

> Pairs with [`PUBLISHING.md`](PUBLISHING.md). Character limits are Apple's and
> enforced by the form.

---

## 1. App Information

| Field | Limit | Suggested value |
|---|---|---|
| App Name | 30 | `Bixel Studio` |
| Subtitle | 30 | `Pixel art & game asset studio` |
| Bundle ID | — | `com.bixel.studio` |
| SKU | — | `BIXEL-MAC-001` **(your choice, internal only)** |
| Primary Language | — | `English (U.S.)` |
| Primary Category | — | `Graphics & Design` |
| Secondary Category | — | `Developer Tools` *(optional)* |
| Content Rights | — | *Does your app contain, show, or access third-party content?* → **No** (the app ships no third-party media). |

---

## 2. Pricing and Availability

| Field | Suggested value |
|---|---|
| Price | **Free** (monetize via the in-app lifetime unlock) |
| Availability | Specific countries/regions; exclude **China mainland** unless the China-compliant build and metadata are ready |
| Distribution | Public |

---

## 3. App Privacy

Answer **Data Collection** based on what the app actually does:

| Data type | Collected? | Notes |
|---|---|---|
| Contact Info | No | No account, no sign-up. |
| Purchases | **Yes** (if RevenueCat is enabled) | Purchase history processed by RevenueCat to unlock the lifetime purchase. |
| Identifiers | **Yes** (if RevenueCat is enabled) | RevenueCat anonymous app-user ID. |
| Usage / Diagnostics | No | No analytics or crash SDK is bundled. |
| User Content | No | Projects, images and prompts stay on device; prompts are sent to the configured AI provider only when the user invokes an AI action. |

Privacy Policy URL: `https://ajithberlin.github.io/bixel-native/privacy.html`.
Tracking: **No** — the app does not track users across apps/websites.
The app does not bundle a Google Mobile Ads SDK or use behavioural advertising.
It fetches clearly labelled house-ad creatives from a published HTTPS feed; no
advertising identifier or cross-app tracking is used. Selecting a sponsor link
opens that sponsor's website only when the user chooses to open it.

---

## 4. Age Rating

Answer the questionnaire honestly. Expected outcome: **4+ / Everyone**.

| Question | Answer |
|---|---|
| Cartoon or Fantasy Violence | None |
| Realistic Violence | None |
| Sexual Content or Nudity | None |
| Profanity or Crude Humor | None |
| Alcohol, Tobacco, or Drug Use | None |
| Mature/Suggestive Themes | None |
| Horror/Fear Themes | None |
| Gambling | None |
| Medical/Treatment Information | None |
| Unrestricted Web Access | **No** |
| User-Generated Content (shared with others) | **No** (content stays local) |

---

## 5. Version Information (per release)

### Description (4,000 char limit)

```
Bixel Studio is a native pixel-art and 2D game-asset studio for Mac — draw, animate, and build tilemaps in one focused workspace.

DRAW & ANIMATE
• Layered raster editor with brush, eraser, fill, line, rectangle, ellipse and eyedropper tools
• Frame-by-frame animation timeline with tags, onion skinning and loop modes
• Palette management with built-in DB32, PICO-8 and Game Boy presets, plus custom palettes
• Undo/redo, clipboard, flip/rotate and nearest-neighbour zoom

TILEMAP DESIGNER
• Paint, flood-fill, pattern and autotile tools for top-down and side-scroller maps
• Structural validation and continuity checks before export
• Export to Tiled JSON, CSV and PNG

AI ASSISTANT
• Built-in assistant that turns prompts into pixel art and spritesheets
• Predict the next animation frame, compress palettes and remove backgrounds
• Connect OpenRouter or sign in with ChatGPT (Codex); keys stay in the macOS Keychain

BUILT FOR THE MAC
• Native SwiftUI + Metal, fast and fully offline for everything except AI actions
• Projects autosave locally; your art never leaves your Mac unless you ask the AI to use it
• Optimised for Apple silicon

Whether you're prototyping a game jam or shipping a full tileset, Bixel Studio keeps the whole pixel pipeline in one place.
```

### Keywords (100 char limit, comma-separated, no spaces)

```
pixel art,spritesheet,tilemap,animation,sprite,game assets,aseprite,retro,8bit,indie
```

### Promotional Text (170 char limit)

```
Draw, animate and build tilemaps in one native Mac studio. Includes an AI assistant that generates pixel art and spritesheets.
```

### URLs

| Field | Value |
|---|---|
| Support URL | `https://ajithberlin.github.io/bixel-native/support.html` |
| Marketing URL | `https://ajithberlin.github.io/bixel-native/` |
| Privacy Policy URL | `https://ajithberlin.github.io/bixel-native/privacy.html` |

### Build

Select the uploaded build (see `PUBLISHING.md`). Set **What's New in This Version**:

```
First public release of Bixel Studio for Mac.
```

### Copyright

```
2026 Ajith Berlin A
```

---

## 6. Screenshots (macOS)

At least **one** size is required; provide both for the best result:

| Size | Required | Notes |
|---|---|---|
| 1280 × 800 | Yes (one of these) | Minimum accepted macOS screenshot. |
| 1440 × 900 | Recommended | |
| 2560 × 1600 | Recommended | Retina. |
| 2880 × 1800 | Optional | |

Suggested shots (3–5):

1. Canvas with the timeline and a running animation.
2. Tilemap Designer with the tile palette and a painted map.
3. AI assistant panel generating a spritesheet.
4. Palette / colour tools.
5. Project library.

Screenshots must show the real UI — no device frames required on macOS. App
previews (video) are optional.

---

## 7. App Review Information

| Field | Value |
|---|---|
| Sign-in required? | **No** |
| Demo account | Not required. The AI features need an OpenRouter key or ChatGPT login, which reviewers supply themselves; all non-AI features work offline. |
| Contact | Your name, email, phone **(your choice)** |

### Notes for the reviewer

```
Bixel Studio is a fully local pixel-art editor. No account is required and all
drawing, animation and tilemap features work offline.

The optional AI assistant requires the reviewer to connect an OpenRouter API key
or sign in with ChatGPT; without one, the AI panel shows a connection prompt and
the rest of the app is unaffected.

All projects are stored locally under the app container. The app does not collect
analytics.

The Devices pane provides an optional Mac host for the paired Bixel iPad app.
To test it, open Settings → Devices, enable “Remote Access,” and choose “Show
pairing code.” When enabled, Bixel creates a Network.framework `NWListener` and
advertises the Bonjour service `_bixel-remote._tcp` so a paired iPad can initiate
encrypted local-network connections for project sync and the Mac-hosted AI
assistant. The listener is off by default and is only started after the user
enables Remote Access. The ChatGPT (Codex) sign-in flow also uses a localhost
callback on port 1455; OpenRouter, Codex, and the ad feed use outgoing HTTPS
connections.
```

---

## 8. Export Compliance

| Question | Answer |
|---|---|
| Does your app use encryption? | **Yes** (HTTPS to OpenRouter/Codex via the system TLS). |
| Is it exempt? | **Yes** — it uses only standard OS-provided encryption (URLSession/rustls with standard ciphers) and does not implement proprietary cryptography. |
| `ITSAppUsesNonExemptEncryption` | `NO` — add to `Info.plist` to skip the prompt on every upload. |

To automate this, add to the `info.properties` block in `project.yml`:

```yaml
ITSAppUsesNonExemptEncryption: false
```

---

## 9. In-App Purchases

The app uses RevenueCat for a lifetime ad-free unlock. Configure it in App Store
Connect before submitting:

| Field | Suggested value |
|---|---|
| Type | Non-Consumable |
| Reference Name | `Bixel Lifetime Unlock` |
| Product ID | `bixel_ad_free` **(must match the RevenueCat product)** |
| Price | Tier of your choice |
| Display Name | `Lifetime Unlock` |
| Description | `Unlock Bixel Studio forever and remove all ads.` |
| Review screenshot | A screenshot of the in-app purchase screen. |

Link the product to the RevenueCat entitlement/offering and add the IAP to the
app version under **In-App Purchases**.

---

## 10. Submission checklist

### China mainland storefront

The app includes an optional Codex provider integration and the associated
metadata must not be used for a China mainland submission without confirming
the required local compliance. For the current build, use the storefront
exclusion path:

1. In App Store Connect, open **Pricing and Availability** → **App
   Availability** → **Manage Availability**.
2. Choose **Specific Countries or Regions** and deselect **China mainland**.
3. Confirm the change before submitting the version for review.

If China mainland distribution is required later, prepare a separate
China-compliant release plan with professional legal advice, disable the
restricted provider in that build, and use localized metadata and screenshots
that contain no restricted provider references.

- [ ] App record created with bundle ID `com.bixel.studio`.
- [ ] App Sandbox + In-App Purchase capabilities enabled on the App ID.
- [ ] Distribution + installer certificates and Mac App Store profile installed.
- [ ] `.env.deploy` filled in; `.p8` placed in `private_keys/`.
- [ ] `.pkg` uploaded (`scripts/publish-appstore.sh`).
- [ ] Build processed and selected for the version.
- [ ] Listing fields above entered.
- [ ] Screenshots uploaded.
- [ ] App Privacy and Age Rating completed.
- [ ] Export compliance answered.
- [ ] IAP created and attached.
- [ ] Review notes entered.
- [ ] Submit for review.
