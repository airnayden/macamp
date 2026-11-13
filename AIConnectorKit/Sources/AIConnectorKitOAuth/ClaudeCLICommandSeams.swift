// ClaudeCLICommandSeams — the two host facilities `ClaudeCLICredentialStore`
// needs, each behind a protocol so the suite never touches a real Keychain or a
// real home directory.
//
// ── WHY A SUBPROCESS AND NOT `SecItemCopyMatching` ────────────────────────────
//
// The credential belongs to ANOTHER application's Keychain item. Reading it with
// the Security framework directly would work, but every access control decision
// would then be attributed to this process with no user-visible provenance, and
// the item's ACL would have to be widened for us specifically. Shelling out to
// `/usr/bin/security` is what the reference implementation does, it produces the
// standard, recognisable macOS authorisation prompt naming a tool the listener
// already trusts, and — crucially — a REFUSAL is a non-zero exit rather than a
// silent empty read.
//
// This is macOS-only by construction. `AIConnectorKitOAuth` is linked exclusively
// into `macampMac` (`scripts/check-ios-oauth-linkage.sh` enforces that), so a
// hard dependency on `/usr/bin/security` costs the iOS shell nothing.
//
// ── ARGV EXPOSURE, ACKNOWLEDGED ───────────────────────────────────────────────
//
// A write-back passes the patched blob as `-w <value>`, which is visible in this
// user's own `ps` output for the lifetime of the call. `security` offers no
// file-descriptor form for the payload, and the alternative — an interactive
// stdin prompt — cannot be driven from a GUI app. Same-user visibility only:
// another account needs root to read it. Documented rather than hidden.
import Darwin
import Foundation

/// What one `/usr/bin/security` invocation produced. Carries no interpretation —
/// the store decides what a status and a stream mean.
public struct SecurityCommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String

    public init(exitCode: Int32, standardOutput: String = "", standardError: String = "") {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var didSucceed: Bool {
        exitCode == 0
    }
}

/// Runs `/usr/bin/security`. The one seam a test replaces to drive discovery,
/// reads and write-backs without a Keychain.
public protocol SecurityCommandRunning: Sendable {
    func run(arguments: [String]) async -> SecurityCommandResult
}

/// Reads and atomically writes a credential file owned by another application.
public protocol CredentialFileAccessing: Sendable {
    func read(path: String) async -> Data?

    /// Writes `data` atomically at mode `0600`.
    ///
    /// - Returns: `false` on any failure. A write-back must never throw into a
    ///   refresh that already succeeded.
    @discardableResult
    func write(_ data: Data, path: String) async -> Bool
}

// MARK: - Live implementations

/// The production `/usr/bin/security` runner.
public struct SecurityCommandRunner: SecurityCommandRunning {
    /// Absolute, never resolved through `PATH`: a credential read must not be
    /// redirectable by an environment variable.
    public static let executablePath = "/usr/bin/security"

    private let executablePath: String
    private let timeout: Duration

    /// Cancellation or timeout returns exit code -1 and discards partial output.
    public init(executablePath: String = SecurityCommandRunner.executablePath, timeout: Duration = .seconds(30)) {
        self.executablePath = executablePath
        self.timeout = timeout
    }

    public func run(arguments: [String]) async -> SecurityCommandResult {
        let cancellation = CommandCancellation()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                Self.runSynchronously(
                    executablePath: executablePath, arguments: arguments,
                    timeout: timeout, cancellation: cancellation
                )
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func runSynchronously(
        executablePath: String, arguments: [String], timeout: Duration,
        cancellation: CommandCancellation
    ) -> SecurityCommandResult {
        guard !cancellation.isCancelled else { return SecurityCommandResult(exitCode: -1) }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return SecurityCommandResult(exitCode: -1)
        }

        let outputBox = DataBox()
        let errorBox = DataBox()
        let group = DispatchGroup()
        drain(output, into: outputBox, group: group, cancellation: cancellation)
        drain(errors, into: errorBox, group: group, cancellation: cancellation)
        while process.isRunning || group.wait(timeout: .now()) != .success {
            if cancellation.isCancelled || ContinuousClock.now >= deadline {
                cancellation.cancel()
                if process.isRunning {
                    process.terminate()
                    let grace = ContinuousClock.now.advanced(by: .milliseconds(250))
                    while process.isRunning, ContinuousClock.now < grace {
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        group.wait()
        guard !cancellation.isCancelled else { return SecurityCommandResult(exitCode: -1) }

        return SecurityCommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(bytes: outputBox.value, encoding: .utf8) ?? "",
            standardError: String(bytes: errorBox.value, encoding: .utf8) ?? ""
        )
    }

    /// Nonblocking reads let cancellation finish even if a descendant retains a
    /// pipe writer. Both streams drain concurrently to avoid pipe-buffer deadlock.
    private static func drain(
        _ pipe: Pipe, into box: DataBox, group: DispatchGroup,
        cancellation: CommandCancellation
    ) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = pipe.fileHandleForReading
            defer {
                try? handle.close()
                group.leave()
            }
            let descriptor = handle.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                cancellation.cancel()
                return
            }
            var bytes = [UInt8](repeating: 0, count: 65536)
            var data = Data()
            while !cancellation.isCancelled {
                let count = read(descriptor, &bytes, bytes.count)
                if count > 0 {
                    data.append(contentsOf: bytes.prefix(count))
                } else if count == 0 {
                    break
                } else if errno == EAGAIN || errno == EINTR {
                    Thread.sleep(forTimeInterval: 0.001)
                } else {
                    cancellation.cancel()
                    return
                }
            }
            box.value = data
        }
    }
}

private final class CommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

/// Lock-guarded `Data` slot, so two concurrent pipe drains satisfy Swift 6's
/// `@Sendable` capture rules without an actor hop inside a synchronous read.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var value: Data {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
    }
}

/// The production file accessor: atomic temp-then-rename at mode `0600`.
public struct CredentialFileAccessor: CredentialFileAccessing {
    public init() {}

    public func read(path: String) async -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Writes beside the target and renames, so a crash mid-write leaves the other
    /// application's credential intact rather than truncated. The temp file is
    /// created at `0600` BEFORE any bytes reach it — writing first and chmod-ing
    /// after would publish the token at the default mask for the interval between.
    @discardableResult
    public func write(_ data: Data, path: String) async -> Bool {
        let target = URL(fileURLWithPath: path)
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).macamp-\(UUID().uuidString)")
        let manager = FileManager.default
        guard manager.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            return false
        }
        do {
            // NOT `.atomic`: that option writes to a second temp file and renames,
            // which discards the 0600 attributes just established on this one.
            try data.write(to: temporary)
            _ = try manager.replaceItemAt(target, withItemAt: temporary)
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return true
        } catch {
            try? manager.removeItem(at: temporary)
            return false
        }
    }
}
