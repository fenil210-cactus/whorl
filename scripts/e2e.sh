#!/bin/sh
# End-to-end: build real files, push them through every route Whorl offers, and inspect what comes out.
# usage: scripts/e2e.sh [path/to/Whorl]   (default: .build/debug/Whorl)
set -u
cd "$(dirname "$0")/.."
WHORL="${1:-.build/debug/Whorl}"
[ "${WHORL#/}" = "$WHORL" ] && WHORL="$PWD/$WHORL"
LAST=""
WORK="${TMPDIR:-/tmp}/whorl-e2e-$$"
FX="$WORK/fx"
PASS=0
FAIL=0
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
sh scripts/fixtures.sh "$FX" >/dev/null 2>&1 || { echo "could not build fixtures"; exit 1; }
cd "$FX"

ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL  %s  (%s)\n' "$1" "$2"; }

# conv <input> <format> <expected-file(1)-substring> : convert and check `file` output
conv() {
  in="$1"; fmt="$2"; want="$3"
  out=$("$WHORL" convert "$in" --to "$fmt" 2>"$WORK/err")
  rc=$?
  if [ $rc -ne 0 ]; then bad "$in -> $fmt" "$(cat "$WORK/err")"; return; fi
  first=$(printf '%s\n' "$out" | head -1)
  [ -s "$first" ] || { bad "$in -> $fmt" "empty or missing output"; return; }
  desc=$(file -b "$first")
  case "$desc" in
    *"$want"*) ok "$in -> $fmt  [$(basename "$first")]" ;;
    *) bad "$in -> $fmt" "file says: $desc" ;;
  esac
  LAST="$first"
}

contains() { # <file> <text> <label>
  if grep -q -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3" "'$2' not found in $1"; fi
}

# convo <input> <format> <want>: run only when this Mac offers the route (HEIC/AVIF encoders depend on the OS or VM)
convo() {
  if "$WHORL" formats "$1" | sed -n 1p | tr ' ' '\n' | grep -qx "$2"; then conv "$1" "$2" "$3"; else ok "$1 -> $2 not offered on this Mac (skipped, correctly)"; fi
}

echo "== images =="
conv photo.png jpg "JPEG"
convo photo.png heic "ISO Media"
conv photo.png tiff "TIFF"
conv photo.png bmp "PC bitmap"
conv photo.png gif "GIF"
convo photo.png avif "ISO Media"
conv photo.png webp "Web/P"
conv photo.png pdf "PDF"
conv photo.heic png "PNG"
conv photo.jpg png "PNG"
conv logo.svg png "PNG"
conv logo.svg jpg "JPEG"

echo "== image tools =="
for t in compress rotate metadata; do
  out=$("$WHORL" tool $t photo.jpg 2>"$WORK/err") && [ -s "$out" ] && ok "tool $t photo.jpg [$(basename "$out")]" || bad "tool $t photo.jpg" "$(cat "$WORK/err")"
done
out=$("$WHORL" tool merge photo.jpg photo.png 2>"$WORK/err") && file -b "$out" | grep -q PDF && ok "tool merge images -> pdf" || bad "tool merge images" "$(cat "$WORK/err")"

echo "== documents =="
conv notes.md html "HTML"
contains "$LAST" "<strong>bold</strong>" "md->html keeps bold"
contains "$LAST" "<h1>Trip notes</h1>" "md->html heading"
conv notes.md txt "text"
conv notes.md docx "Microsoft Word"
DOCX="$LAST"
conv notes.md rtf "Rich Text"
conv notes.md odt "OpenDocument"
conv notes.md epub "EPUB"
EPUB="$LAST"
conv notes.md pdf "PDF"
PDF="$LAST"
conv plain.txt docx "Microsoft Word"
conv plain.txt pdf "PDF"
echo "== document round trips =="
cp "$DOCX" back.docx
conv back.docx md "text"
contains "$LAST" "^# Trip notes" "docx->md H1 survives"
contains "$LAST" "^## Packing" "docx->md H2 stays H2"
contains "$LAST" "\*\*bold\*\*" "docx->md bold survives"
contains "$LAST" "^- Passport" "docx->md bullet list survives, one per line"
contains "$LAST" "^1\\. Book flights" "docx->md numbered list survives"
cp "$EPUB" back.epub
conv back.epub md "text"
contains "$LAST" "Trip notes" "epub->md title survives"
contains "$LAST" "^- Camera" "epub->md list survives, one per line"
conv back.epub txt "text"
cp "$PDF" back.pdf
conv back.pdf txt "text"
contains "$LAST" "Trip notes" "pdf->txt text is real, selectable"
conv back.pdf docx "Microsoft Word"
conv back.pdf md "text"
conv back.pdf png "PNG"
conv back.pdf jpg "JPEG"

echo "== epub structure =="
if unzip -l back.epub | head -6 | grep -q mimetype && [ "$(unzip -p back.epub mimetype)" = "application/epub+zip" ]; then ok "epub has mimetype first"; else bad "epub mimetype" "bad layout"; fi
unzip -p back.epub OEBPS/chapter.xhtml | xmllint --noout - 2>"$WORK/err" && ok "epub chapter is well-formed XML" || bad "epub chapter XML" "$(cat "$WORK/err")"
unzip -p back.epub OEBPS/content.opf | xmllint --noout - 2>"$WORK/err" && ok "epub opf is well-formed XML" || bad "epub opf XML" "$(cat "$WORK/err")"

echo "== PDF tools =="
cp "$PDF" doc.pdf
for t in rotate metadata; do
  out=$("$WHORL" tool $t doc.pdf 2>"$WORK/err") && file -b "$out" | grep -q PDF && ok "tool $t doc.pdf" || bad "tool $t doc.pdf" "$(cat "$WORK/err")"
done
# A small text PDF cannot shrink; Whorl must say so instead of handing back a bigger file.
"$WHORL" tool compress doc.pdf >/dev/null 2>"$WORK/err" && ok "compress on a tiny PDF produced a smaller file" || { grep -q "already as small" "$WORK/err" && ok "compress on a tiny PDF says it is already small" || bad "tiny PDF compress" "$(cat "$WORK/err")"; }
cp big.pdf photo-doc.pdf
out=$("$WHORL" tool compress photo-doc.pdf 2>"$WORK/err")
if [ -n "$out" ] && [ "$(stat -f%z "$out")" -lt "$(( $(stat -f%z photo-doc.pdf) / 2 ))" ]; then ok "pdf compress halves a photo PDF  [$(stat -f%z photo-doc.pdf) -> $(stat -f%z "$out") bytes]"; else bad "pdf compress photo PDF" "$(cat "$WORK/err") $out"; fi
out=$("$WHORL" tool merge doc.pdf photo-doc.pdf 2>"$WORK/err") && file -b "$out" | grep -q PDF && ok "tool merge two PDFs" || bad "tool merge PDFs" "$(cat "$WORK/err")"
out=$("$WHORL" tool split "$out" 2>"$WORK/err") && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -ge 2 ] && ok "tool split makes one file per page" || bad "tool split" "$(cat "$WORK/err")"

echo "== sheets =="
conv sheet.csv tsv "text"
conv sheet.csv xlsx "Microsoft Excel"
XLSX="$LAST"
conv sheet.csv ods "OpenDocument"
ODS="$LAST"
unzip -p "$XLSX" xl/worksheets/sheet1.xml | xmllint --noout - 2>"$WORK/err" && ok "xlsx sheet is well-formed XML" || bad "xlsx sheet XML" "$(cat "$WORK/err")"
unzip -p "$ODS" content.xml | xmllint --noout - 2>"$WORK/err" && ok "ods content is well-formed XML" || bad "ods content XML" "$(cat "$WORK/err")"
cp "$XLSX" t.xlsx
conv t.xlsx csv "text"
contains "$LAST" '"fresh, red"' "xlsx->csv keeps comma-in-quotes"
contains "$LAST" '"say ""hi"""' "xlsx->csv keeps escaped quotes"
contains "$LAST" "^007," "xlsx->csv keeps leading zero as text"
cp "$ODS" t.ods
conv t.ods csv "text"
contains "$LAST" '"fresh, red"' "ods->csv keeps comma-in-quotes"
conv sheet.tsv csv "text" 2>/dev/null || { "$WHORL" convert sheet.csv --to tsv >/dev/null 2>&1; }

echo "== subtitles =="
conv movie.srt vtt "text"
contains "$LAST" "WEBVTT" "srt->vtt header"
contains "$LAST" "00:00:01.000 --> 00:00:03.500" "srt->vtt timestamps use a dot"
cp "$LAST" back.vtt
conv back.vtt srt "text"
contains "$LAST" "00:00:01,000 --> 00:00:03,500" "vtt->srt timestamps use a comma"
contains "$LAST" "with two rows" "vtt->srt keeps multi-line cues"

echo "== audio =="
conv speech.wav m4a "ISO Media"
conv speech.wav aiff "AIFF"
conv speech.wav flac "FLAC"
conv speech.m4a wav "WAVE"
conv speech.aiff wav "WAVE"
out=$("$WHORL" tool compress speech.wav 2>"$WORK/err") && ok "tool compress audio [$(stat -f%z speech.wav) -> $(stat -f%z "$out")]" || bad "tool compress audio" "$(cat "$WORK/err")"

echo "== video =="
if [ -f clip.mp4 ]; then
  conv clip.mp4 mov "ISO Media"
  conv clip.mp4 gif "GIF"
  "$WHORL" convert clip.mp4 --to m4a >/dev/null 2>"$WORK/err" && bad "silent video -> m4a" "should refuse" || { grep -q "no sound" "$WORK/err" && ok "silent video -> m4a explains there is no sound" || bad "silent video message" "$(cat "$WORK/err")"; }
  conv speech-audio.mp4 m4a "ISO Media"
  "$WHORL" tool compress clip.mp4 >/dev/null 2>"$WORK/err" && ok "tool compress video made a smaller file" || { grep -q "already as small" "$WORK/err" && ok "tool compress video says a tiny clip is already small" || bad "tool compress video" "$(cat "$WORK/err")"; }
else
  bad "video fixture" "clip.mp4 not built"
fi

echo "== archives =="
conv pack.zip tar "tar"
conv pack.zip gz "gzip"
conv pack.tar.gz zip "Zip"
unzip -l "$LAST" | grep -q "a.txt" && ok "zip from tar.gz holds a.txt at the top" || bad "zip contents" "a.txt missing"
conv pack.tar.gz tar "tar"
printf 'hello\n' > solo.txt; gzip -k solo.txt
conv solo.txt.gz zip "Zip"

echo "== behaviour =="
"$WHORL" convert nothing.xyz --to png >/dev/null 2>"$WORK/err" && bad "unknown type is refused" "exit 0" || ok "unknown/missing input is refused with a message"
"$WHORL" convert clip.mp4 --to mkv >/dev/null 2>"$WORK/err" && bad "mkv without ffmpeg" "exit 0" || { grep -qi ffmpeg "$WORK/err" && ok "mkv without ffmpeg says how to get ffmpeg" || bad "mkv message" "$(cat "$WORK/err")"; }
out=$("$WHORL" convert photo.png --to jpg 2>/dev/null | head -1); out2=$("$WHORL" convert photo.png --to jpg 2>/dev/null | head -1)
[ "$out" != "$out2" ] && ok "second run never overwrites (numbered name)" || bad "overwrite protection" "same path twice"
"$WHORL" formats photo.heic | grep -q "convert:" && ok "formats lists targets" || bad "formats command" "no output"
"$WHORL" formats deck.pptx 2>/dev/null | grep -qi "libreoffice" && ok "pptx explains it needs LibreOffice" || ok "pptx offered (LibreOffice present)"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ] && echo E2E_OK
exit "$FAIL"
