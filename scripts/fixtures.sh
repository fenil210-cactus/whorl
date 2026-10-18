#!/bin/sh
# Builds a small set of real sample files with tools that ship with macOS.
# usage: scripts/fixtures.sh <output-dir>
set -eu
OUT="$1"
rm -rf "$OUT"
mkdir -p "$OUT"
cd "$OUT"

# A portrait photo, so orientation handling is exercised, plus a transparent PNG.
sips -s format png "$(ls /System/Library/Desktop\ Pictures/*.heic | head -1)" --resampleWidth 800 --out photo.png >/dev/null
sips -s format jpeg photo.png --out photo.jpg >/dev/null
sips -s format heic photo.png --out photo.heic >/dev/null
sips -s format tiff photo.png --out photo.tiff >/dev/null
sips -s format pdf "$(ls /System/Library/Desktop\ Pictures/*.heic | head -1)" --out big.pdf >/dev/null 2>&1 || true
cat > logo.svg <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80" viewBox="0 0 120 80"><rect width="120" height="80" rx="12" fill="#5B6CFF"/><circle cx="60" cy="40" r="22" fill="#fff"/></svg>
SVG

cat > notes.md <<'MD'
# Trip notes

A short paragraph with **bold**, *italic*, `code`, and a [link](https://example.com).

## Packing

- Passport
- Charger
- Camera

1. Book flights
2. Pack bags

> Travel light.

```
echo done
```
MD
printf 'First paragraph.\n\nSecond paragraph.\n' > plain.txt
printf 'name,qty,note\nApples,3,"fresh, red"\nPears,12,"say ""hi"""\n007,1,\n' > sheet.csv
printf '1\n00:00:01,000 --> 00:00:03,500\nHello there\n\n2\n00:00:04,000 --> 00:00:06,000\nSecond line\nwith two rows\n' > movie.srt

# Audio and video from the system voice.
say -o speech.aiff "Whorl converts files on your Mac."
afconvert -f WAVE -d LEI16 speech.aiff speech.wav
afconvert -f m4af -d aac speech.aiff speech.m4a
afconvert -f mp4f -d aac speech.aiff speech-audio.mp4 2>/dev/null || true
cat > make-video.swift <<'SWIFT'
import AVFoundation
import CoreVideo
let url = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: url)
let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180]
let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)
for frame in 0..<30 {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32ARGB, nil, &buffer)
    guard let pixels = buffer else { continue }
    CVPixelBufferLockBaseAddress(pixels, [])
    let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
    for i in 0..<(320 * 180) { base[i * 4] = 255; base[i * 4 + 1] = UInt8(frame * 8); base[i * 4 + 2] = 80; base[i * 4 + 3] = 120 }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 10))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
SWIFT
swiftc -O make-video.swift -o make-video 2>/dev/null && ./make-video clip.mp4 || echo "video fixture skipped"
rm -f make-video make-video.swift

# Archives.
mkdir -p pack && printf 'one\n' > pack/a.txt && printf 'two\n' > pack/b.txt
ditto -c -k pack pack.zip
tar -czf pack.tar.gz -C pack .
ls -1
