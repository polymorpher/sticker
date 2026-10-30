# Stickerize

Turn any photo or image into stickers, then use them everywhere:

- **Messages, and the system Stickers drawer in every app.** The iMessage extension opts into the *media* presentation
  context, so iOS also lists it in the emoji keyboard's Stickers section (any app), FaceTime and Markup.
- **WhatsApp and Telegram packs.** Pick 3–30 stickers (WhatsApp) or up to 120 (Telegram) and add them through each app's
  official import API. They then live in that app's own sticker picker.
- **Any other app** (Signal, Slack, Mail…): the Stickerize keyboard is a sticker picker. Tap a sticker to copy it, then
  paste it into the chat.
- **Signal sticker packs** (Desktop upload): convert a folder of stickers — including WeChat favorites exported with
  [export-wechat-emoji](https://github.com/liusheng22/export-wechat-emoji) — into PNG / APNG packs with the CLI
  `stickerize signal-pack`, then upload in Signal Desktop (**File → Create/Upload Sticker Pack**).
- **Share, copy, drag, Save to Photos** from the app. From Photos you can add a sticker to the iPhone's own sticker library
  with *Add Sticker*; no API exists for apps to do that directly.

Stickers come from Photos (multi-select), Files (any format ImageIO reads, plus page 1 of a PDF), the pasteboard,
drag and drop, or the share sheet ("Stickerize"). The editor lifts every foreground subject with Vision. You choose
which subjects to keep, and you can crop to the subject, add a white outline, and set a name and emoji. Every saved
sticker is normalized to what `MSSticker.h` requires: each side 300–618 px, ≤ 500 KB.

**Animated stickers:** animated GIF, APNG, WebP and HEICS imports become animated GIF stickers, kept whole (no
cut-out). They play in Messages and the Stickers drawer, and the keyboard and Copy hand other apps the GIF itself.
Signal sends a pasted GIF as an animated image; Telegram sends it as a GIF animation. WhatsApp and Telegram pack exports
use the first frame. To make a still instead, turn off Keep Animation in the editor; the first frame can then be cut
out like any photo.

`stickerize`, the original macOS command-line tool, is rebuilt on the same library (see below).

## Layout

Everything lives in `stickerize/`:

| Path | What |
| --- | --- |
| `Stickerize.xcodeproj` | App + 3 extensions + UI tests. Folders are file-system synchronized: new files are picked up automatically. |
| `Config/Base.xcconfig` | Bundle ID prefix, App Group, team. Per-target Info.plists and the shared entitlements file. |
| `App/` | SwiftUI container app: library, import, sticker page, WhatsApp/Telegram export, setup guide. |
| `Shared/` | The sticker editor and import helpers, compiled into the app and the Share extension. |
| `MessagesExtension/` | iMessage app: `MSStickerBrowserViewController` over the shared library. |
| `KeyboardExtension/` | Sticker keyboard: a grid of your stickers; tap one to copy it. |
| `ShareExtension/` | "Stickerize" in the share sheet, same editor as the app. |
| `StickerizeKit/` | Swift package. `StickerizeKit`: storage, decoding, normalization (no Vision, safe for every extension). `StickerLift`: Vision subject lifting and outlines. `StickerExport`: WhatsApp/Telegram payloads (libwebp) and Signal Desktop pack prep (PNG/APNG). `stickerize`: the CLI. Plus tests. |
| `samples/` | Test photos used by the package tests and the CLI examples. |
| `scripts/` | `make-icons.swift` (draws every icon), `generate-xcodeproj.py` (how the project file was made). |

The package isn't called `StickerKit` because Apple ships an empty system module with that name in the device and
macOS SDKs (but not the simulator SDK). A shadowing module would fail differently on device and in the simulator.

## Build and run

Requires Xcode 27 (iOS 27 SDK); the app runs on iOS 17 and later. If Xcode isn't your selected developer directory,
prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

```bash
open stickerize/Stickerize.xcodeproj
```

**Simulator:** select the *Stickerize* scheme and run. No team is needed. Don't build simulator copies with
`CODE_SIGNING_ALLOWED=NO`: that drops the entitlements, the App Group stops working, and the extensions can't see the
library (the app then shows a warning).

**Device:** put your team in `stickerize/Config/Local.xcconfig` (git-ignored), and change the bundle ID prefix if
`ai.qokka.stickerize` isn't yours:

```
DEVELOPMENT_TEAM = ABCDE12345
BUNDLE_ID_PREFIX = com.example.stickerize
```

The App Group is derived from the prefix (`group.<prefix>`), written into every target's entitlements and Info.plist,
and registered by automatic signing (`REGISTER_APP_GROUPS`). Nothing else needs editing.

**Tests:**

```bash
cd stickerize/StickerizeKit && swift test
```

90 tests cover decoding, orientation, normalization limits, animated GIFs, naming, the store, Vision lifting on the
samples, outlines, the WebP/pack payloads and Signal packs (checked against what Signal's sticker creator accepts). Vision tests run on the Mac only: Vision's instance masks don't run in the iOS Simulator.
The scheme's Test action runs the same package tests plus the UI tests in the simulator.

## Turning it on

- **Messages / Stickers drawer:** nothing to set up. Open the emoji keyboard and tap Stickers, or in Messages tap
  **+ › Stickers**.
- **Keyboard:** Settings › General › Keyboard › Keyboards › Add New Keyboard › **Stickerize**. Then tap Stickerize and
  turn on **Allow Full Access**, which copying stickers needs. Without it, the keyboard still shows your stickers and
  explains how to turn it on. The keyboard has no network code and doesn't type text.
- **WhatsApp / Telegram:** in the app, tap Select, pick stickers, then Add to… › WhatsApp or Telegram.

## The command-line tool

```bash
cd stickerize/StickerizeKit
swift run stickerize ../samples/test3.jpg --list
swift run stickerize ../samples/test3.jpg --include 1 --outline 12 --output person.png
```

Run `stickerize --help` for the options. The output meets the iMessage limits unless you pass `--full-size`. Logs go
to stderr and the output path to stdout. Exit codes: 1 error, 2 usage, 3 no subject found.

### Signal packs from a folder (WeChat → Signal)

Signal has no iOS pasteboard import like WhatsApp / Telegram. Prepare files on disk, then upload from
[Signal Desktop](https://signal.org/download/):

1. Export WeChat favorites with [export-wechat-emoji](https://github.com/liusheng22/export-wechat-emoji) (GIF / JPG / PNG folder). Quit WeChat first so the tool can read the DB key.
2. Convert them into Signal-ready packs. The input folder is never written to. Packs go into `--output` as `pack-01`, `pack-02`, … with up to 200 stickers each (Signal's per-pack limit):

```bash
cd stickerize/StickerizeKit
swift run -c release stickerize signal-pack ~/Downloads/微信表情包_导出_YYYYMMDD_HHMMSS \
  --output ~/Downloads/Signal贴纸包
```

   Stills become 512 px PNGs. Signal re-encodes stills itself, and the tool checks that Signal's re-encode will fit its 300 KB limit. Animations become square APNGs of up to 512 px and 300 KB that loop forever, as Signal's uploader requires. An animation that doesn't fit is first reduced to 256 colors (all a GIF has anyway), then shrunk and thinned. One that still can't fit is kept as a still, using its most visible frame. Very long animations can also lose frames up front, so that one sticker never needs more than a few hundred MB of memory. The run lists every sticker it reduced. Drawn stickers usually stay at 512 px; photo-like clips shrink (a 240 px, 10-frame clip comes out at about 216 px with 8 frames). Running again into the same folder stops instead of mixing old and new files. Add `--replace` to swap in the new packs: the old ones go to the Trash, and folders the tool didn't make are never touched.

3. In Signal Desktop: **File → Create/upload sticker pack** → drag in one `pack-XX` folder's files (not the original WeChat GIFs) → pick an emoji per sticker → set title and author → **Upload** → **Install**.
4. Limits: Signal's [Stickers](https://support.signal.org/hc/en-us/articles/360031836512-Stickers) article (≤ 200 stickers, ≤ 300 KB each, APNG for motion, not GIF). Signal Desktop's sticker creator also rejects animated stickers that aren't square or don't loop forever.

## Known limits

- In the simulator, background removal is unavailable (the editor says so and uses the whole image). Test it on a device.
- Declaring the media context means the iMessage app lives in the Stickers drawer rather than the Messages app list.
- The keyboard is a sticker picker with no typing keys. App Review guideline 4.4.1 asks keyboards to provide typed
  input, so expect to explain this in review notes. The typing layout is in the git history if review insists.
- WhatsApp and Telegram import, the keyboard's Full Access behaviour and how other apps treat pasted stickers have been
  checked against each project's source and docs, not on a device. See [`stickerize/REVIEW.md`](stickerize/REVIEW.md) for what was verified and how.
