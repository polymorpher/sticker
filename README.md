# Stickerize

Turn any photo or image into stickers, then use them everywhere:

- **Messages, and the system Stickers drawer in every app.** The iMessage extension opts into the *media* presentation
  context, so iOS also lists it in the emoji keyboard's Stickers section (any app), FaceTime and Markup.
- **WhatsApp and Telegram packs.** Pick 3–30 stickers (WhatsApp) or up to 120 (Telegram) and add them through each app's
  official import API. They then live in that app's own sticker picker.
- **Any other app** (Signal, Slack, Mail…): the Stickerize keyboard is a sticker picker. Tap a sticker to copy it, then
  paste it into the chat.
- **Signal sticker packs** (Desktop upload): convert a folder or ZIP of stickers — including WeChat favorites exported
  with [export-wechat-emoji](https://github.com/liusheng22/export-wechat-emoji) — into PNG / APNG packs with the CLI
  `stickerize signal-pack`, then upload in Signal Desktop (**File → Create/Upload Sticker Pack**).
- **Share, copy, drag, Save to Photos** from the app. From Photos you can add a sticker to the iPhone's own sticker library
  with *Add Sticker*; no API exists for apps to do that directly.
- **Folders.** Stickers can be sorted into folders and subfolders, and a ZIP archive's folders come in as folders (see
  [Folders and search](#folders-and-search)). The iMessage app and the keyboard show one folder at a time, and
  everything can be searched by name, emoji or folder.

Stickers come from Photos (multi-select), Files (any format ImageIO reads, plus page 1 of a PDF), the pasteboard,
drag and drop, or the share sheet ("Stickerize"). A ZIP archive from Files, the pasteboard or drag and drop brings in
every image inside it, including subfolders and ZIPs inside the ZIP (see [ZIP archives](#zip-archives)). The editor
lifts every foreground subject with Vision. You choose which subjects to keep, and you can crop to the subject, add a
white outline, and set a name and emoji. Every saved sticker is normalized to what `MSSticker.h` requires: each side
300–618 px, ≤ 500 KB.

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
| `MessagesExtension/` | iMessage app: a folder picker and search over an `MSStickerBrowserViewController` of the shared library. |
| `KeyboardExtension/` | Sticker keyboard: a grid of your stickers, by folder or matching the word just typed; tap one to copy it. |
| `ExtensionUI/` | The folder list both extensions share. |
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

228 tests cover decoding, orientation, normalization limits, animated GIFs, naming, the store and its folders (damaged
and newer manifests included), search, Vision lifting on the samples, outlines, the WebP/pack payloads, Signal packs
(checked against what Signal's sticker creator accepts) and ZIP archives (damaged, encrypted and hostile ones included,
name decoding measured on generated names, and how their folders become sticker folders). Vision tests run on the Mac only: Vision's instance masks don't run in the iOS Simulator.
The scheme's Test action runs the same package tests plus the UI tests in the simulator.

## ZIP archives

The app (Files, paste, drag and drop) and `stickerize signal-pack` both take ZIP archives:

- **Everything inside counts.** Subfolders are searched and ZIPs inside the ZIP are opened, up to 4 levels deep. Files
  without an extension (WeChat's own sticker files have none) are recognized by their contents. Text files, macOS's
  `__MACOSX` copies, hidden files and formats ImageIO can't decode (SVG, Illustrator) are left out, and so are
  documents that happen to be ZIPs (Procreate, Krita, Sketch, Office), whose previews aren't stickers.
- **Names come out right.** Each sticker is named after its file ("开心.gif" → 开心). Hashes and numbers, which is how
  WeChat and export-wechat-emoji name files, give the default name instead. Archives made on a Mac or Linux store
  UTF-8, marked as such or not, and those names stay as they are: one-letter and one-character names ("ñ", "桜"),
  folders, decomposed accents and kaomoji ("(×_×)", "(´∀`)") included. Unmarked names from Windows are in the system's
  code page instead: GBK on Chinese Windows (how most WeChat collections arrive), Big5, Shift_JIS, Korean CP949, CP850
  (Western Europe, Latin America) or CP866 (Russian). The encoding is detected for the whole archive, and a name added
  on a Mac to a Windows archive stays UTF-8 without changing how the others read. A single short name is the hard case,
  because the same bytes can be valid text in two encodings ("è" is the same bytes as GBK "猫", Korean "좋아요" as GBK
  "亮酒夸"); then the user's language decides. Measured on real names and generated ones, decoded for users of seven
  languages:
  - Five or more different names: 99.2–100% in every encoding, whatever the user's language, as long as most of them
    have characters beyond ASCII (a Western archive with one or two accented names is as hard as those names alone).
  - One name alone, for users of the archive's language: GBK 99.5% (97% for rare hanzi), Big5 99.1%, Shift_JIS 100%,
    Korean 89–99% (the lower end with full-width punctuation, "（1）", "！"), CP850 100%, CP866 97%. For other users: GBK 99.5% (Western, Russian, Japanese) or 92–94% (Korean,
    Traditional Chinese); Big5 87–95%; Shift_JIS 86–96%; Korean 65–88%; CP850 98.5–99% (86–90% for Japanese and Traditional
    Chinese users); CP866 90–91%.
  - A numbered pack (one name numbered 1 to 5) is as hard as that name alone: 87–100% for users of its language, and
    for others 67–100% depending on the encoding (lowest: Big5 and Korean packs for users who read neither).
  - One character alone, each of the common ones: GBK 100% for Simplified Chinese users, Big5 85% for Traditional
    Chinese users, a Korean syllable 65% for Korean users; much less for others, who get the reading likeliest for them.
- **Bad files don't stop the rest.** Damaged or password-protected images, and folders that can't be opened, are listed
  as skipped, and the CLI says so plainly when a whole archive is password-protected. Limits keep a hostile archive (a
  "ZIP bomb") from filling the disk or running for hours: 256 MB per file, and 2 GB and 200,000 archive records per
  import (per run for the CLI), however many archives that takes, files picked together included; overlapping or
  impossible entries, and names longer than any real file's (a path of more than 1 KB, or a file name of more than 255
  characters), are refused. Once the 2 GB is reached, the first file that doesn't fit and everything after it is left
  out, files beside the archive and (in the app) items picked after it included, and both say from which file on. The
  app opens at most 500 images per import, the CLI 10,000 per run, both the first ones in name order (folder by folder,
  archive by archive), and both say when they stop there.
- **Ctrl-C stops `signal-pack` cleanly.** It stops at the next file (or chunk, while unpacking or reading a large
  archive), removes what it unpacked and leaves the output as it was, also when the terminal window is closed or
  already gone. Pressing Ctrl-C again quits at once; the next run with its output on the same disk removes what that
  left, as it does after a crash or `kill -9`. A signal that arrives while the packs are being moved into place lets
  that finish and the report print first. Signals ignored when it starts (`nohup`) stay ignored.

## Folders and search

- **Folders** hold stickers and other folders, to any depth. In the app: **+ › New Folder**; touch and hold a folder to
  rename, move or delete it (keeping its stickers moves them up a level); **Select › Move to…** or a sticker's Folder
  row moves stickers. Folders are sorted by name, as in Finder; a folder's stickers keep the library's order. Names
  differing only in case or width ("Cats", "ＣＡＴＳ") count as the same name; accents don't ("Bär", "Bar").
- **ZIP archives keep their layout.** Each archive becomes a folder named after it, and its subfolders become
  subfolders. When every image is inside the same folder, the innermost folder they all share names it instead and the
  folders above are dropped ("Cats.zip" holding "Cats/…" gives "Cats", not "Cats › Cats"; a ZIP made with full paths,
  "Users/me/Desktop/Cats/…", gives "Cats"). ZIPs inside it follow the same rule. An archive name nobody chose makes no
  folder: "Archive", "download (3)", "New folder", hashes, camera names, export pages, or the name of one of its own
  top-level items when there are others (Windows names a ZIP of several items after the one that was right-clicked,
  so "开心.zip" holding "开心/" and "难过/" gives two sibling folders). A shared folder with a default name ("New folder",
  "Downloads") gives way to the archive's name. Inside an archive, only UUID and hash folders, camera folders ("DCIM",
  "100APPLE") and the pages export-wechat-emoji makes ("1_50_组") make no folder; their stickers go to the folder
  above. At most 3 levels are created; deeper images go into the third. Importing inside a folder puts it all there.
  Importing the same archive on its own again fills the same folders (its stickers are added again). An import that
  stops at a limit can't tell which folder all the archive's images share, so it keeps the archive's whole folder
  path from its name down (cut at 3 levels): it can land in different, deeper folders than the archive imported on
  its own. Folders are created as stickers are saved, so skipped images leave no empty ones, and a batch keeps the
  archive's order.
- **Search** in the app looks at sticker names, emoji and folder names (every word has to match; case, accents and
  width are ignored, and Chinese or Japanese needs no spaces). In the **iMessage app**, tap the name at the top to show
  one folder, or the magnifying glass to search. Apple gives the compact drawer no keyboard, so searching asks for the
  expanded drawer first; if the host doesn't expand it, the field says to pull the drawer up and tap it. Whether the
  drawer expands, or can be pulled up, in the emoji keyboard of other apps hasn't been checked on a device. In the
  **keyboard**, which can't type into its own search field, type a word such as "cat" in the message field before
  switching: the stickers in the folder shown whose name, emoji or folder has a word starting with it are shown, with
  a button to show the folder again. Words need three letters (two in Korean); Chinese, Japanese, Thai and other text
  written without spaces is matched by its longest ending that finds anything ("我好开心" finds "开心"), and by one
  character only when that's all that was typed. iOS's own emoji-keyboard search has no way in for apps.
- **Sending stickers friends can save.** iOS lets people who receive a sticker save it only if it was made on the
  sender's iPhone (Live Stickers) or is a Genmoji. Messages checks this itself: in the iOS 27.2 ChatKit (read from the
  Mac Catalyst and simulator builds), `isIMStickerSaveable:` accepts only Apple's own two sticker sources. So no app's
  stickers can be saved by the people who receive them; Sticker Details shows which app it came from. To send one that
  can be saved: save it to Photos (one sticker, or **Select › Add to… › Save to Photos**), make it an iPhone sticker
  there with **Add Sticker**, and send it from your own stickers in the Stickers drawer. Recipients on iOS 17.2 or later
  touch and hold it and tap Save to Stickers (Sticker Details › Save when it was placed on a bubble).

The library is still one `manifest.json` (version 2 adds folders). Readers never change it, a manifest that can't be
read right now is never overwritten, one damaged folder entry costs only that folder, and a manifest written by a newer
version is never changed (this version shows what it can read of it and refuses changes). A build from before
folders drops them on its next change.

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

1. Export WeChat favorites with [export-wechat-emoji](https://github.com/liusheng22/export-wechat-emoji) (GIF / JPG / PNG, in folders of 50 by default). Quit WeChat first so the tool can read the DB key.
2. Convert them into Signal-ready packs. The input is the export folder (searched with all its subfolders) or a ZIP of it, such as one sent from a Windows PC; see [ZIP archives](#zip-archives). The input is never written to. Packs go into `--output` as `pack-01`, `pack-02`, … with up to 200 stickers each (Signal's per-pack limit):

```bash
cd stickerize/StickerizeKit
swift run -c release stickerize signal-pack ~/Downloads/微信表情包_导出_YYYYMMDD_HHMMSS \
  --output ~/Downloads/Signal贴纸包
swift run -c release stickerize signal-pack ~/Downloads/表情包.zip --output ~/Downloads/Signal贴纸包
```

   Stills become 512 px PNGs. Signal re-encodes stills itself, and the tool checks that Signal's re-encode will fit its 300 KB limit. Animations become square APNGs of up to 512 px and 300 KB that loop forever, as Signal's uploader requires. An animation that doesn't fit is first reduced to 256 colors (all a GIF has anyway), then shrunk and thinned. One that still can't fit is kept as a still, using its most visible frame. Very long animations can also lose frames up front, so that one sticker never needs more than a few hundred MB of memory. The run lists every sticker it reduced. Drawn stickers usually stay at 512 px; photo-like clips shrink (a 240 px, 10-frame clip comes out at about 216 px with 8 frames). Running again into the same folder stops instead of mixing old and new files. Add `--replace` to swap in the new packs: the old ones go to the Trash, and folders the tool didn't make are never touched.

3. In Signal Desktop: **File → Create/upload sticker pack** → drag in one `pack-XX` folder's files (not the original WeChat GIFs) → pick an emoji per sticker → set title and author → **Upload** → **Install**.
4. Limits: Signal's [Stickers](https://support.signal.org/hc/en-us/articles/360031836512-Stickers) article (≤ 200 stickers, ≤ 300 KB each, APNG for motion, not GIF). Signal Desktop's sticker creator also rejects animated stickers that aren't square or don't loop forever.

## Known limits

- In the simulator, background removal is unavailable (the editor says so and uses the whole image). Test it on a device.
- Declaring the media context means the iMessage app lives in the Stickers drawer rather than the Messages app list.
- The keyboard is a sticker picker with no typing keys. App Review guideline 4.4.1 asks keyboards to provide typed
  input, so expect to explain this in review notes. The typing layout is in the git history if review insists.
- Searching in the iMessage app (especially from the emoji keyboard of other apps), the folder list in both
  extensions and the keyboard's typed-word matches have been checked by building and by tests of the matching, not
  on a device or in Messages. The app's folder screens and ZIP folders were checked in the simulator.
- WhatsApp and Telegram import, the keyboard's Full Access behaviour and how other apps treat pasted stickers have been
  checked against each project's source and docs, not on a device. See [`stickerize/REVIEW.md`](stickerize/REVIEW.md) for what was verified and how.
