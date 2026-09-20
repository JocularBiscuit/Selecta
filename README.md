# Selecta

A fast, Adobe Bridge / Photo Mechanic–style photo culling app for iPhone. Plug an SD card into your iPhone via a USB adapter, browse the RAW+JPEG pairs, rate and flag at speed, and export the untouched originals (plus XMP sidecar ratings) into a folder you can hand straight to Lightroom.

**Selecta never modifies, re-encodes, or deletes anything on your card.** Exports are byte-for-byte copies via `FileManager.copyItem`, with original filenames preserved and no silent overwrites.

## What's in the box

- **RAW+JPEG pairing** — `DSC01234.ARW` + `DSC01234.JPG` show as one shot (case-insensitive, handles Sony `DSC#####` and Nikon `DSC_####`/`_DSC####`). Extensions: ARW, NEF, CR3, CR2, RAF, RW2, DNG, ORF / JPG, JPEG. Videos are listed with a badge.
- **Fast previews** — JPEG siblings are used for thumbnails and the loupe (the RAW is never decoded unless it has to be). RAW-only shots use the embedded JPEG preview via ImageIO, falling back to a reduced-size `CIRAWFilter` render, falling back to a placeholder. Thumbnails are disk-cached and decoded off the main thread with bounded concurrency.
- **Culling** — stars 0–5, pick/reject flags, Lightroom color labels (Red/Yellow/Green/Blue/Purple). Grid multi-select for batch rating. Loupe with pinch/double-tap 100% zoom, filmstrip, undo, and gestures: swipe up = +1 star, swipe down = reject, swipe left/right = next/previous.
- **Persistence** — ratings live in SwiftData keyed by card + base filename, so they survive app restarts and card unplugging. XMP sidecars written to the card (if writable) restore ratings on any machine.
- **Export** — selection / current filter / "keepers" rule (≥N stars or picked, never rejects). RAW, JPEG, or both. Destination: the Files-visible `Selecta → Exports` folder or any folder you pick. Optional XMP sidecars and Photos-album add. Name collisions get ` (1)` suffixes — nothing is ever overwritten.

## Prerequisites

- **macOS** with **Xcode 15 or newer** (Xcode 16 recommended). Note: the Command Line Tools alone are *not* enough to build an iOS app — install the full Xcode from the App Store or <https://developer.apple.com/download/>. This machine currently has only the Command Line Tools, so installing Xcode is the one missing step.
- **XcodeGen** (already installed here): `brew install xcodegen`
- An iPhone on **iOS 17 or newer** (see below if yours is older), a USB-C/Lightning SD card reader, and a card with photos.

## Build & install

```bash
cd PhotoSorter          # this folder
xcodegen generate       # regenerates Selecta.xcodeproj from project.yml (already done once)
open Selecta.xcodeproj
```

Then in Xcode:

1. Select the **Selecta** target → **Signing & Capabilities** → choose your **Team**.
2. Change the bundle identifier if you like (`project.yml` → `PRODUCT_BUNDLE_IDENTIFIER`, then re-run `xcodegen generate` — the project file is disposable; `project.yml` and `Selecta/` are the source of truth).
3. Plug in your iPhone, pick it as the run destination, hit **⌘R**.

### Signing: free Apple ID vs. paid Developer Program

- **Free Apple ID**: works fine. Xcode → Settings → Accounts → add your Apple ID, then select the "Personal Team". Limitations: the app expires after **7 days** (just hit ⌘R again to reinstall — your ratings/data survive), max 3 sideloaded apps, and the first launch requires trusting yourself as a developer: on the iPhone, **Settings → General → VPN & Device Management → your Apple ID → Trust**.
- **Paid Developer Program** ($99/yr): installs last a year, no app-count limit, TestFlight if you ever want it.

### If your iPhone is older than iOS 17

The app uses SwiftData and the `@Observable` macro, both iOS 17+. To target iOS 16 you'd need to swap SwiftData for Core Data (`NSPersistentContainer`, two entities mirroring `AssetRecord`/`CardSession`) and `@Observable` for `ObservableObject`/`@Published` (plus `MagnifyGesture` → `MagnificationGesture`). Everything else (ImageIO, PhotoKit, fileImporter, security-scoped bookmarks) is iOS 14–16 era API. Check your device: Settings → General → About → iOS Version. To change the target: edit `deploymentTarget`/`IPHONEOS_DEPLOYMENT_TARGET` in `project.yml` and re-run `xcodegen generate`.

## Using it

1. **Open Card** → the system folder picker appears. Navigate to the SD card and pick its **DCIM** folder (or the card root). iOS requires this one-time grant; Selecta saves a bookmark so "Reopen" works next session.
2. **Cull** — tap a thumbnail for the loupe. Swipe up to add stars, down to reject, sideways to move on. Double-tap for 100% to check focus. Long-press in the grid for multi-select.
3. **Filter** — the chip bar isolates keepers (rating ≥ N, picks, labels, RAW/JPEG type) and sorts by capture time / filename / rating.
4. **Export** — share icon → choose scope, RAW/JPEG/both, destination, XMP on. Progress is shown; a summary reports every copy, sidecar, and collision rename.

### Handing off to Lightroom

- **Lightroom Classic (Mac/PC)**: Files app → On My iPhone → **Selecta → Exports** → select the export folder → AirDrop (or cable-copy) to the Mac → import into Lightroom Classic. Star ratings and color labels come in automatically from the `.xmp` sidecars.
- **Lightroom mobile**: "Add from Files" pointing at the export folder. **Caveat**: Lightroom mobile's XMP-sidecar support is inconsistent — ratings may not appear there, even though the same files + sidecars import perfectly into Lightroom Classic and Bridge on desktop.
- **Pick/reject flags** are *not* part of standard XMP, so they intentionally stay inside Selecta — use them to drive the export selection (the default "keepers" rule is ≥3★ or picked).

## Project layout

```
project.yml                  XcodeGen manifest — regenerate the .xcodeproj anytime
Selecta/
  App/SelectaApp.swift        Entry point, SwiftData container
  Models/Models.swift        AssetRecord, CardSession, CardItem, enums
  Services/Library.swift     Card open/scan/pair, ratings, undo, filters
  Services/ThumbnailStore.swift  Preview pipeline + disk cache
  Services/XMP.swift         Sidecar read/write
  Services/ExportManager.swift   Byte-for-byte export + Photos album
  Views/…                    Grid, loupe, filmstrip, export sheet, settings
```

## Design notes & honest caveats

- **Ratings are keyed to card + base filename**, not full paths, so they survive replugging. If you re-pick the same card the existing key is matched via its bookmark. If iOS ever mounts the card at a different path *and* the bookmark can't be matched, ratings still come back from the XMP sidecars on the card.
- **Locked/read-only cards**: sidecar writes fail silently by design; ratings stay in the on-device database and are written as sidecars at export time instead.
- **Photos export** is secondary: JPEGs are added reliably; RAW handling in Photos varies by format, and files Photos rejects are skipped (the summary shows the count). The folder export is the dependable Lightroom path.
- **Capture time** uses file-system dates for sorting (reading EXIF from hundreds of RAWs during the initial scan would wreck the "grid appears instantly" goal). The loupe's info sheet shows the true EXIF capture time.
- Not yet implemented (listed as nice-to-haves): RGB histogram, two-up compare view.
