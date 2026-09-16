import Darwin
import Foundation

enum DiagnosticLog {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Logs/Satsuma", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let logFile = directory.appendingPathComponent("satsuma.log")
    static let crashFile = directory.appendingPathComponent("crash.log")

    private static let queue = DispatchQueue(label: "lol.peril.satsuma.log")
    private static let handle: FileHandle? = {
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        let handle = FileHandle(forWritingAtPath: logFile.path)
        handle?.seekToEndOfFile()
        return handle
    }()

    private static var crashPath = [CChar](repeating: 0, count: Int(PATH_MAX))
    private static let signals: [Int32] = [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE]

    static func start() {
        crashFile.path.withCString { source in
            strlcpy(&crashPath, source, crashPath.count)
        }
        for signal in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = crashHandler
            action.sa_flags = SA_SIGINFO | SA_RESETHAND | SA_ONSTACK
            sigemptyset(&action.sa_mask)
            sigaction(signal, &action, nil)
        }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        log("Satsuma \(version) (\(build)) started, macOS \(ProcessInfo.processInfo.operatingSystemVersionString), pid \(getpid())")
    }

    static func log(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        let text = message()
        let thread = Thread.isMainThread ? "main" : "bg"
        let stamp = ISO8601DateFormatter.shared.string(from: Date())
        let entry = "\(stamp) [\(thread)] \(file):\(line) \(text)\n"
        queue.sync {
            handle?.write(Data(entry.utf8))
        }
        DragDebug.log(text)
    }

    static func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    private static let crashHandler: @convention(c) (Int32, UnsafeMutablePointer<siginfo_t>?, UnsafeMutableRawPointer?) -> Void = { signal, info, _ in
        let fd = open(crashPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd >= 0 {
            writeLine(fd, "==== Satsuma crash ====")
            writeLine(fd, "signal ", Int(signal), " (", String(cString: strsignal(signal)), ")")
            if let info {
                writeLine(fd, "code ", Int(info.pointee.si_code), " address ", UInt(bitPattern: info.pointee.si_addr))
            }
            writeLine(fd, "thread ", Thread.isMainThread ? "main" : "background")
            var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
            let count = backtrace(&frames, Int32(frames.count))
            backtrace_symbols_fd(&frames, count, fd)
            writeLine(fd, "")
            close(fd)
        }
        raise(signal)
    }

    private static func writeLine(_ fd: Int32, _ parts: Any...) {
        var line = ""
        for part in parts { line += String(describing: part) }
        line += "\n"
        line.withCString { pointer in
            _ = write(fd, pointer, strlen(pointer))
        }
    }
}

private extension ISO8601DateFormatter {
    static let shared: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
