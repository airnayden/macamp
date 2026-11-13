import AIConnectorKitOAuth
import Darwin
import Foundation
import Testing

@Suite("SecurityCommandRunnerTests", .serialized)
struct SecurityCommandRunnerTests {
    @Test("Cancelling a credential command stops noncooperative work promptly")
    func cancellationStopsCommand() async throws {
        let runner = SecurityCommandRunner(executablePath: "/bin/sh")
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let task = Task { await runner.run(arguments: [
            "-c", "trap '' TERM; echo $$ > \"$1\"; sleep 2; printf synthetic", "fixture", pidFile.path,
        ]) }
        for _ in 0 ..< 200 {
            if FileManager.default.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid =
            try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        let start = ContinuousClock.now
        task.cancel()
        let result = await task.value
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(result.didSucceed == false)
        #expect(result.standardOutput.isEmpty)
        #expect(kill(pid, 0) == -1)
    }

    @Test("Credential command timeout bounds inherited pipe lifetime")
    func timeoutBoundsPipeLifetime() async {
        let runner = SecurityCommandRunner(executablePath: "/bin/sh", timeout: .milliseconds(100))
        let start = ContinuousClock.now
        let result = await runner.run(arguments: ["-c", "sleep 2 & exit 0"])
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(result.exitCode == -1)
        #expect(result.standardOutput.isEmpty)
    }

    @Test("Timeout reaps a child that ignores SIGTERM")
    func timeoutReapsStubbornChild() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let runner = SecurityCommandRunner(executablePath: "/bin/sh", timeout: .milliseconds(200))
        let start = ContinuousClock.now
        let result = await runner.run(arguments: [
            "-c", "trap '' TERM; echo $$ > \"$1\"; while :; do :; done", "fixture", pidFile.path,
        ])
        let pid =
            try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(result.exitCode == -1)
        #expect(kill(pid, 0) == -1)
    }

    @Test("Large synthetic stdout and stderr are drained without deadlock")
    func drainsBothStreams() async {
        let runner = SecurityCommandRunner(executablePath: "/bin/sh")
        let result = await runner.run(arguments: [
            "-c",
            "i=0; while [ $i -lt 10000 ]; do printf synthetic; printf synthetic >&2; i=$((i+1)); done",
        ])
        #expect(result.exitCode == 0)
        #expect(result.standardOutput.count == 90000)
        #expect(result.standardError.count == 90000)
    }
}
