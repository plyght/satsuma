import Foundation

struct ArchiveEngine: ConversionEngine {
    func supports(from: FileFormat, to: FileFormat) -> Bool {
        from.category == .archive && to.category == .archive && to != .rar
    }

    func convert(_ request: ConversionRequest) async throws {
        if request.target == .rar {
            throw SatsumaError.invalidInput("RAR archives can be read but macOS has no free RAR encoder. Choose ZIP, TAR, or GZIP instead.")
        }
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("satsuma-archive-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        try await extract(request.source, format: request.sourceFormat, into: staging)
        request.progress(0.5)
        try await pack(staging, as: request.target, to: request.destination)
        request.progress(1)
    }

    func extract(_ archive: URL, format: FileFormat, into directory: URL) async throws {
        switch format {
        case .zip:
            try await ZipTool.unzip(archive, into: directory)
        case .tar:
            let result = try await Shell.run("/usr/bin/tar", ["-xf", archive.path, "-C", directory.path])
            guard result.succeeded else { throw SatsumaError.toolFailed("tar", result.stderr) }
        case .gz:
            let name = archive.lastPathComponent.lowercased()
            if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
                let result = try await Shell.run("/usr/bin/tar", ["-xzf", archive.path, "-C", directory.path])
                guard result.succeeded else { throw SatsumaError.toolFailed("tar", result.stderr) }
            } else {
                let output = directory.appendingPathComponent(archive.deletingPathExtension().lastPathComponent)
                let result = try await Shell.run("/bin/sh", ["-c", "/usr/bin/gunzip -c \"$0\" > \"$1\"", archive.path, output.path])
                guard result.succeeded else { throw SatsumaError.toolFailed("gunzip", result.stderr) }
            }
        case .rar:
            let candidates = ["unar", "unrar", "bsdtar"]
            for tool in candidates {
                guard let path = Shell.which(tool) else { continue }
                let args: [String]
                switch tool {
                case "unar": args = ["-q", "-o", directory.path, archive.path]
                case "unrar": args = ["x", "-y", "-idq", archive.path, directory.path + "/"]
                default: args = ["-xf", archive.path, "-C", directory.path]
                }
                let result = try await Shell.run(path, args)
                if result.succeeded { return }
            }
            let bsdtar = try await Shell.run("/usr/bin/tar", ["-xf", archive.path, "-C", directory.path])
            guard bsdtar.succeeded else {
                throw SatsumaError.toolFailed("rar", "Install `unar` (`wax install unar`) to extract RAR archives.")
            }
        default:
            throw SatsumaError.unsupportedConversion(format, .zip)
        }
    }

    func pack(_ directory: URL, as format: FileFormat, to destination: URL) async throws {
        switch format {
        case .zip:
            try await ZipTool.zip(directory: directory, to: destination)
        case .tar:
            let result = try await Shell.run("/usr/bin/tar", ["-cf", destination.path, "-C", directory.path, "."])
            guard result.succeeded else { throw SatsumaError.toolFailed("tar", result.stderr) }
        case .gz:
            let result = try await Shell.run("/usr/bin/tar", ["-czf", destination.path, "-C", directory.path, "."])
            guard result.succeeded else { throw SatsumaError.toolFailed("tar", result.stderr) }
        default:
            throw SatsumaError.unsupportedConversion(.zip, format)
        }
    }
}
