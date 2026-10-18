# Whorl

**Free, offline file converter for your Mac.** Drop a file, pick a format, done. The new file lands next to the original. Nothing is uploaded, nothing is metered, no account.

Whorl lives in the menu bar. Use it two ways:

- **The window.** Click the menu bar icon → *Open Whorl*, then drop files on it. Works with no setup and no permissions.
- **The wheel.** Start dragging a file in Finder, tap a key, and a wheel of formats opens under your pointer. Drop on a wedge. Needs one permission (Accessibility), see below.

Also: right-click a file in Finder → *Services → Convert with Whorl*, *Open With → Whorl*, or drop onto the app icon.

## Install

No Apple Developer account is needed, so Whorl installs with one command, not from the App Store.

```sh
curl -fsSL https://raw.githubusercontent.com/fenil210-cactus/whorl/main/install.sh | sh
```

or with Homebrew:

```sh
brew install --cask fenil210-cactus/tap/whorl
```

macOS 13 or newer, Apple silicon or Intel. Remove it with `./install.sh --uninstall` or `brew uninstall --cask whorl`.

## What it converts

Everything below works on a clean Mac with nothing else installed:

| Kind | From → to |
| --- | --- |
| **Images** | JPG, PNG, WebP, HEIC, TIFF, AVIF, BMP, GIF, SVG (input) → each other, and → PDF. Photos come out upright, transparency becomes white for JPG. |
| **PDF** | → JPG / PNG (300 dpi, every page), TXT, MD, HTML, DOCX, EPUB, RTF (text only) |
| **Documents** | DOCX, DOC, ODT, RTF, EPUB, HTML, Markdown, TXT → PDF, DOCX, ODT, RTF, EPUB, HTML, MD, TXT. Headings, bold/italic, links and lists survive. |
| **Spreadsheets** | XLSX, ODS, CSV, TSV → each other (first sheet; quoted commas and line breaks handled) |
| **Subtitles** | SRT ↔ VTT |
| **Audio** | WAV, M4A, AIFF, FLAC, MP3 (in) → M4A, WAV, AIFF, FLAC |
| **Video** | MP4, MOV → MP4, MOV, GIF, or just the sound as M4A |
| **Archives** | ZIP, TAR, GZ, TGZ → ZIP, TAR, GZ (RAR, 7z, XZ can be opened too when macOS's `tar` reads them) |

**Tools:** compress (images, PDF, audio, video), rotate (images, PDF), strip metadata (images, PDF), split and merge PDFs, merge images into one PDF.
**Actions** (hold the third key): AirDrop, Float (a Quick Look preview that stays on top), Copy, Move, Copy Path, Open in Terminal.

### Optional extras

Whorl only offers conversions that will work. Install these and more formats appear:

| Install | Adds |
| --- | --- |
| `brew install ffmpeg` | MKV, WebM, AVI, WMV video; MP3, OGG, Opus, WMA audio; any odd input format |
| `brew install --cask libreoffice` | PPT/PPTX/XLS, and sharper Word → PDF |
| `brew install webp` | WebP output on older macOS |

`whorl doctor` shows what is found. Settings → *Extra tools* has copy-paste install commands.

## Using the wheel

1. Start dragging a file (or several) in Finder.
2. Tap **⇧ Shift** for formats, **⌘ Command** for tools, **⌃ Control** for actions. Tap another key to switch.
3. Move to a wedge and drop. Drop anywhere else to cancel, and the file slides back.

Change the keys in Settings. Whorl catches the drop itself, so Finder never moves or copies your original.

**Why Accessibility?** macOS only lets an app see a modifier-key tap while another app is in front if you allow it. Whorl uses it for exactly that and nothing else. Allow it from the card in the window, or System Settings → Privacy & Security → Accessibility. Because the app is signed ad hoc, macOS asks again after an update; switch Whorl off and on in that list.

## Command line

```sh
whorl convert photo.heic notes.md --to jpg      # each file to the format it can become
whorl convert report.docx --to pdf
whorl tool compress video.mp4
whorl formats mystery.file                      # what can this become?
whorl doctor
```

## Build from source

```sh
swift build                 # debug build
sh scripts/test.sh          # unit tests (Swift Testing; works with just the Command Line Tools)
sh scripts/e2e.sh           # builds real sample files and runs every route through the CLI
sh scripts/build-app.sh     # dist/Whorl.app + Whorl.zip, universal, ad-hoc signed
```

Layout: `Sources/WhorlCore` is the engine (what can convert to what, and the converters); `Sources/Whorl` is the menu bar app, window, wheel and CLI. `Whorl --snapshot <dir> [files]` draws the main screens to PNGs for quick visual checks.

## Limits, honestly

- PDF → DOCX/EPUB/MD is text only; layout, images and tables are not rebuilt.
- DOCX → PDF without LibreOffice flattens tables and drops images. With LibreOffice it is faithful.
- Pages, Keynote and Numbers files cannot be read; export to Word/PowerPoint/Excel first.
- Spreadsheets convert the first sheet and values, not formulas or styling.
- Whorl is independent. It is not affiliated with Leap Studio or Tangerine.

MIT licensed. Contributions welcome.
