import Foundation

struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == 0 }
}

final class PipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func set(stdout data: Data) { lock.withLock { stdout = data } }
    func set(stderr data: Data) { lock.withLock { stderr = data } }

    func result(status: Int32) -> ShellResult {
        lock.withLock {
            ShellResult(status: status, stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self))
        }
    }
}

enum Shell {
    static func run(_ executable: String, _ arguments: [String], currentDirectory: URL? = nil) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let currentDirectory { process.currentDirectoryURL = currentDirectory }
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            let output = PipeBuffer()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                output.set(stdout: outPipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                output.set(stderr: errPipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
            process.terminationHandler = { proc in
                group.wait()
                continuation.resume(returning: output.result(status: proc.terminationStatus))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    static func which(_ name: String, extra: [String] = []) -> String? {
        let fm = FileManager.default
        var candidates = extra
        candidates += [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/local/bin/\(name)",
            "\(fm.homeDirectoryForCurrentUser.path)/.local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)",
        ]
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: name)?.path {
            candidates.insert(bundled, at: 0)
        }
        if let resource = Bundle.main.resourceURL?.appendingPathComponent(name).path {
            candidates.insert(resource, at: 1)
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }
}
