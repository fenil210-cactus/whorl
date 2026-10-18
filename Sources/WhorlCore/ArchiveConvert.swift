import Foundation

enum ArchiveConvert {
    static func convert(input: URL, to format: Format) throws -> URL {
        // "pack.tar.gz" becomes "pack.zip", not "pack.tar.zip".
        var stem = input.deletingPathExtension()
        if stem.pathExtension.lowercased() == "tar" { stem = stem.deletingPathExtension() }
        let output = OutputNames.url(beside: stem.appendingPathExtension("src"), fileExtension: format.fileExtension)
        let temp = try Shell.tempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try unpack(input, to: temp)
        do {
            switch format {
            case .zip: try Shell.run("/usr/bin/ditto", ["-c", "-k", temp.path, output.path])
            case .tar: try Shell.run("/usr/bin/tar", ["-cf", output.path, "-C", temp.path, "."])
            case .gz: try Shell.run("/usr/bin/tar", ["-czf", output.path, "-C", temp.path, "."])
            default: throw ConvertError.unsupported("Cannot pack \(format.label)")
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }

    private static func unpack(_ input: URL, to directory: URL) throws {
        if Catalog.normalizedExtension(input.pathExtension) == "zip" {
            try Shell.run("/usr/bin/ditto", ["-x", "-k", input.path, directory.path])
            return
        }
        // A bare "notes.txt.gz" is one compressed file, not a tarball.
        let rawExtension = input.pathExtension.lowercased()
        let inner = input.deletingPathExtension()
        if rawExtension == "gz", inner.pathExtension.lowercased() != "tar" {
            let target = directory.appendingPathComponent(inner.lastPathComponent)
            try Shell.run("/bin/sh", ["-c", "/usr/bin/gunzip -c \"$1\" > \"$2\"", "sh", input.path, target.path])
            return
        }
        // bsdtar reads tar, tgz, bzip2, xz, 7z, and RAR by sniffing the contents.
        try Shell.run("/usr/bin/tar", ["-xf", input.path, "-C", directory.path])
    }
}
