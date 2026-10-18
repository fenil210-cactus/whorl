import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Audio and video. macOS handles MP4, MOV, M4A, WAV, AIFF, FLAC and GIF on its own;
/// ffmpeg, when present, adds MKV, WebM, AVI, WMV, MP3, OGG, Opus and WMA.
enum MediaConvert {
    typealias Progress = (Double) -> Void

    static func convert(input: URL, to format: Format, engines: Engines, progress: Progress?) throws -> URL {
        let ext = Catalog.normalizedExtension(input.pathExtension)
        let family = Catalog.family(of: ext)
        let output = OutputNames.url(beside: input, fileExtension: format.fileExtension)
        do {
            if family == .audio, Support.nativeAudioIn.contains(ext), format == .m4a {
                try aac(input, to: output, bitrates: [192_000, 128_000, 96_000, 64_000, 48_000, 32_000])
            } else if family == .audio, Support.nativeAudioIn.contains(ext), let args = afconvertArguments(format) {
                try Shell.run("/usr/bin/afconvert", args + [input.path, output.path])
            } else if family == .video, Support.nativeVideoIn.contains(ext), format == .mp4 || format == .mov {
                try exportVideo(input, to: output, type: format == .mp4 ? .mp4 : .mov, presets: [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality], progress: progress)
            } else if family == .video, Support.nativeVideoIn.contains(ext), format == .m4a {
                try exportVideo(input, to: output, type: .m4a, presets: [AVAssetExportPresetAppleM4A], progress: progress)
            } else if family == .video, Support.nativeVideoIn.contains(ext), format == .gif {
                try animatedGIF(input, to: output, progress: progress)
            } else {
                try ffmpeg(input: input, to: output, format: format, engines: engines)
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        progress?(1)
        return output
    }

    static func compress(input: URL, progress: Progress?) throws -> URL {
        let ext = Catalog.normalizedExtension(input.pathExtension)
        if Catalog.family(of: ext) == .audio {
            let output = OutputNames.url(beside: input, fileExtension: "m4a", tag: "compressed")
            do {
                try aac(input, to: output, bitrates: [96_000, 64_000, 48_000, 32_000])
                try ImageConvert.ensureSmaller(output, than: input)
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
            return output
        }
        let output = OutputNames.url(beside: input, fileExtension: "mp4", tag: "compressed")
        do {
            try exportVideo(input, to: output, type: .mp4, presets: [AVAssetExportPresetMediumQuality], progress: progress)
            try ImageConvert.ensureSmaller(output, than: input)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }

    /// AAC only accepts bitrates that suit the source's sample rate and channels, so step down until one is taken.
    private static func aac(_ input: URL, to output: URL, bitrates: [Int]) throws {
        var lastError: Error = ConvertError.failed("Could not encode AAC")
        for bitrate in bitrates {
            do {
                try Shell.run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", "-b", String(bitrate), input.path, output.path])
                return
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: output)
            }
        }
        throw lastError
    }

    private static func afconvertArguments(_ format: Format) -> [String]? {
        switch format {
        case .wav: return ["-f", "WAVE", "-d", "LEI16"]
        case .aiff: return ["-f", "AIFF", "-d", "BEI16"]
        case .flac: return ["-f", "flac", "-d", "flac"]
        default: return nil
        }
    }

    private static func exportVideo(_ input: URL, to output: URL, type: AVFileType, presets: [String], progress: Progress?) throws {
        let asset = AVURLAsset(url: input)
        if type == .m4a, asset.tracks(withMediaType: .audio).isEmpty {
            throw ConvertError.failed("\(input.lastPathComponent) has no sound to extract")
        }
        var lastError = "This Mac could not read \(input.lastPathComponent)"
        for preset in presets {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            try? FileManager.default.removeItem(at: output)
            session.outputURL = output
            session.outputFileType = type
            session.shouldOptimizeForNetworkUse = true
            let done = DispatchSemaphore(value: 0)
            session.exportAsynchronously { done.signal() }
            while done.wait(timeout: .now() + 0.25) == .timedOut { progress?(Double(session.progress)) }
            if session.status == .completed { return }
            lastError = session.error?.localizedDescription ?? lastError
        }
        throw ConvertError.failed(lastError)
    }

    private static func animatedGIF(_ input: URL, to output: URL, progress: Progress?) throws {
        let asset = AVURLAsset(url: input)
        let seconds = min(CMTimeGetSeconds(asset.duration), 15)
        guard seconds.isFinite, seconds > 0 else { throw ConvertError.unreadable(input.lastPathComponent) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let fps = 10.0
        let count = max(1, Int(seconds * fps))
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw ConvertError.failed("Could not start the GIF")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for index in 0..<count {
            let time = CMTime(seconds: Double(index) / fps, preferredTimescale: 600)
            guard let frame = try? generator.copyCGImage(at: time, actualTime: nil) else { continue }
            CGImageDestinationAddImage(dest, frame, frameProps)
            progress?(Double(index + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(dest) else { throw ConvertError.failed("Could not save the GIF") }
    }

    private static func ffmpeg(input: URL, to output: URL, format: Format, engines: Engines) throws {
        guard engines.ffmpeg, let binary = Binaries.find("ffmpeg") else {
            throw ConvertError.unsupported("Install ffmpeg to make \(format.label) files:  brew install ffmpeg")
        }
        var args = ["-y", "-loglevel", "error", "-i", input.path]
        switch format {
        case .mp3: args += ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case .ogg: args += ["-vn", "-c:a", "libvorbis", "-q:a", "5"]
        case .opus: args += ["-vn", "-c:a", "libopus", "-b:a", "128k"]
        case .wma: args += ["-vn", "-c:a", "wmav2", "-b:a", "192k"]
        case .flac: args += ["-vn", "-c:a", "flac"]
        case .m4a: args += ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case .wav, .aiff: args += ["-vn"]
        case .mp4, .mov: args += ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "+faststart"]
        case .mkv: args += ["-c:v", "libx264", "-c:a", "aac"]
        case .webm: args += ["-c:v", "libvpx-vp9", "-c:a", "libopus"]
        case .avi: args += ["-c:v", "mpeg4", "-q:v", "4", "-c:a", "libmp3lame"]
        case .wmv: args += ["-c:v", "wmv2", "-c:a", "wmav2"]
        case .gif: args += ["-vf", "fps=10,scale=480:-1:flags=lanczos", "-t", "15"]
        default: break
        }
        try Shell.run(binary, args + [output.path])
    }
}
