import Darwin
import Foundation

/// Captures a single app-owned CLI invocation. No output or diagnostics reach the UI.
final class AntigravityProcess: @unchecked Sendable {
    static let maximumOutputBytes = 128 * 1024
    static let maximumDiagnosticBytes = 32 * 1024
    private let process = Process()
    private let output = Pipe()
    private let diagnostics = Pipe()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutEnded = false
    private var stderrEnded = false
    private var exited = false
    private var failure: Error?
    private var deadline: DispatchWorkItem?
    private let validateLine: (@Sendable (Data) throws -> Void)?
    private var pendingLine = Data()

    static func run(executable: URL, arguments: [String], environment: [String: String],
                    directory: URL, timeout: TimeInterval,
                    validateLine: (@Sendable (Data) throws -> Void)? = nil) async throws -> Data {
        try Task.checkCancellation()
        let owner = AntigravityProcess(executable: executable, arguments: arguments,
                                       environment: environment, directory: directory, validateLine: validateLine)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { owner.start(timeout: timeout, continuation: $0) }
        } onCancel: { owner.stop(with: CancellationError()) }
    }

    private init(executable: URL, arguments: [String], environment: [String: String], directory: URL,
                 validateLine: (@Sendable (Data) throws -> Void)?) {
        self.validateLine = validateLine
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = diagnostics
    }

    private func start(timeout: TimeInterval, continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        self.continuation = continuation
        if let failure {
            self.continuation = nil
            lock.unlock()
            continuation.resume(throwing: failure)
            return
        }
        process.terminationHandler = { [self] _ in
            lock.lock(); exited = true; lock.unlock()
            finishIfReady()
        }
        do {
            // Holding the lock makes cancellation before/during launch deterministic.
            try process.run()
        } catch {
            process.terminationHandler = nil
            self.continuation = nil
            lock.unlock()
            continuation.resume(throwing: AntigravityError.unavailable)
            return
        }
        let timer = DispatchWorkItem { [self] in stop(with: AntigravityError.timedOut) }
        deadline = timer
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0.01, timeout), execute: timer)
        read(output.fileHandleForReading, diagnostic: false)
        read(diagnostics.fileHandleForReading, diagnostic: true)
    }

    private func read(_ handle: FileHandle, diagnostic: Bool) {
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                lock.lock()
                let limit = diagnostic ? Self.maximumDiagnosticBytes : Self.maximumOutputBytes
                let count = diagnostic ? stderr.count : stdout.count
                let remaining = max(0, limit - count)
                if diagnostic { stderr.append(chunk.prefix(remaining)) }
                else { stdout.append(chunk.prefix(remaining)) }
                let overflow = chunk.count > remaining
                lock.unlock()
                if overflow { stop(with: AntigravityError.invalidResponse) }
                else if !diagnostic, let validateLine {
                    pendingLine.append(chunk)
                    while let newline = pendingLine.firstIndex(of: 0x0A) {
                        let line = Data(pendingLine[..<newline])
                        pendingLine.removeSubrange(...newline)
                        if !line.isEmpty {
                            do { try validateLine(line) }
                            catch { stop(with: error) }
                        }
                    }
                }
                // Continue draining after the limit so a full pipe cannot strand cleanup.
            }
            try? handle.close()
            lock.lock()
            if diagnostic { stderrEnded = true } else { stdoutEnded = true }
            lock.unlock()
            finishIfReady()
        }
    }

    private func stop(with error: Error) {
        lock.lock()
        if failure == nil { failure = error }
        let running = process.isRunning
        let pid = process.processIdentifier
        lock.unlock()
        guard running else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in
            // The Process object still owns this exact child; never signal unrelated daemons.
            if process.isRunning && process.processIdentifier == pid { Darwin.kill(pid, SIGKILL) }
        }
    }

    private func finishIfReady() {
        lock.lock()
        guard exited, stdoutEnded, stderrEnded, let continuation else { lock.unlock(); return }
        self.continuation = nil
        process.terminationHandler = nil
        deadline?.cancel(); deadline = nil
        let data = stdout
        let error = failure
        let status = process.terminationStatus
        let diagnostic = String(data: stderr, encoding: .utf8) ?? ""
        lock.unlock()
        if let error { continuation.resume(throwing: error) }
        else if Self.requiresAuthentication(output: data, diagnostic: diagnostic) {
            continuation.resume(throwing: AntigravityError.authenticationRequired)
        } else if diagnostic.lowercased().contains("returning partial") {
            // CLI 1.3.2 can emit SUCCESS for a print-timeout snapshot of an unfinished
            // turn. A valid-looking JSON response in that snapshot is not completion.
            continuation.resume(throwing: AntigravityError.timedOut)
        } else if status != 0 { continuation.resume(throwing: AntigravityError.unavailable) }
        else { continuation.resume(returning: data) }
    }

    static func requiresAuthentication(output: Data, diagnostic: String) -> Bool {
        let envelope = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any]
        let text = (diagnostic + " " + (envelope?["error"] as? String ?? "")).lowercased()
        return text.contains("authentication required") || text.contains("not authenticated")
            || text.contains("not signed in") || text.contains("stored credentials are invalid or expired")
            || text.contains("please sign in") || text.contains("please log in")
            || text.contains("login required")
    }
}
