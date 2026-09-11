# Bixel Studio App Screenshots Guide

This directory holds the official screenshots featured on the [Bixel Studio Website](../../index.html) and in the [Handbook](../../handbook/index.html).

Currently, high-resolution styled vector placeholders are active. Whenever you want to attach real screenshots from the macOS app, simply save your captured screenshots here with the matching filenames below (PNG or JPG). The website and handbook will automatically load them!

---

## 📸 Screenshot Slots & Checklist

| Filename | Placement | Recommended App State / View | Recommended Resolution |
| :--- | :--- | :--- | :--- |
| **`interface-overview.png`** | Landing Hero & Handbook Ch. 3 | Main editor canvas open with a detailed pixel art character/scene, showing the Left Tool Rail and Right Panel. | 2560 × 1600 (or Retina 16:10) |
| **`animation-timeline.png`** | Features & Handbook Ch. 6 | Bottom timeline active with multiple frames, frame tags (e.g. *Run*, *Attack*), and Onion Skinning enabled. | 2560 × 1600 |
| **`tilemap-editor.png`** | Features & Handbook Ch. 7 | Tilemap Designer mode showing an isometric or top-down level, tileset picker, and layers. | 2560 × 1600 |
| **`ai-panel.png`** | Features & Handbook Ch. 8 | AI Assistant drawer open on the right showing a prompt conversation, generated pixel art asset, and `/skill` slash commands. | 2560 × 1600 |
| **`color-palette.png`** | Handbook Ch. 4 | Color Disc popover open showing the hue ring, saturation square, and DB32 / PICO-8 / Game Boy swatches. | 1600 × 1200 |

---

## 💡 How to Capture Great Screenshots on macOS

1. Launch Bixel Studio:
   ```bash
   ./scripts/start.sh --run
   ```
2. Press **Cmd + Shift + 4**, then press **Spacebar** to take a window screenshot with Apple's drop shadow.
3. Save or move the captured image into this folder (`site/assets/screenshots/`) with the corresponding name from the table above (e.g., `interface-overview.png`).
4. Commit and push to `main` — GitHub Actions will immediately deploy the updated site!
