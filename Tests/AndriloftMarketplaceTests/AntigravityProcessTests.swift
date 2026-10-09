import Darwin
import Foundation
import XCTest
@testable import AndriloftMarketplace

final class AntigravityProcessTests: XCTestCase {
    private func run(_ arguments: [String], executable: String = "/bin/sh", timeout: TimeInterval = 5) async throws -> Data {
        try await AntigravityProcess.run(executable: URL(fileURLWithPath: executable), arguments: arguments,
            environment: AntigravityCLI.environment(), directory: FileManager.default.temporaryDirectory, timeout: timeout)
    }

    func testCapturesOnlyStdoutAndAwaitsCompleteExit() async throws {
        let output = try await run(["-c", "printf '%s' '{\"status\":\"SUCCESS\"}'; printf '%s' 'private diagnostics' >&2"])
        XCTAssertEqual(String(data: output, encoding: .utf8), "{\"status\":\"SUCCESS\"}")
    }

    func testNonzeroExitDoesNotExposeDiagnostics() async throws {
        do {
            _ = try await run(["-c", "printf '%s' 'private account details' >&2; exit 7"])
            XCTFail("Failed processes must not produce a usable choice.")
        } catch { XCTAssertEqual(error as? AntigravityError, .unavailable) }
    }

    func testAuthenticationErrorsRequestGoogleConnection() async throws {
        do {
            _ = try await run(["-c", "printf '%s' 'Print mode: not signed in' >&2; exit 1"])
            XCTFail("Missing authentication must require account connection.")
        } catch { XCTAssertEqual(error as? AntigravityError, .authenticationRequired) }
    }

    func testPartialTimeoutCannotMasqueradeAsSuccessfulSelection() async throws {
        do {
            _ = try await run(["-c", "printf '%s' '{\"status\":\"SUCCESS\",\"response\":\"{\\\"index\\\":0}\"}'; printf '%s' 'Print mode: print timeout after 3m with a turn in progress; returning partial' >&2"])
            XCTFail("A partial turn cannot begin a download, even when exit status is zero.")
        } catch { XCTAssertEqual(error as? AntigravityError, .timedOut) }
    }

    func testOutputLimitStopsAnOwnedProcess() async throws {
        do {
            _ = try await run(["x"], executable: "/usr/bin/yes")
            XCTFail("Unbounded output must be rejected.")
        } catch { XCTAssertEqual(error as? AntigravityError, .invalidResponse) }
    }

    func testTimeoutTerminatesTheOwnedChild() async throws {
        do {
            _ = try await run(["30"], executable: "/bin/sleep", timeout: 0.1)
            XCTFail("A timed-out process must stop.")
        } catch { XCTAssertEqual(error as? AntigravityError, .timedOut) }
    }

    func testCancellationReapsTheOwnedChildBeforeReturning() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("andriloft-process-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task { try await run(["-c", "printf '%s' \"$$\" > '\(marker.path)'; exec /bin/sleep 30"]) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: marker, encoding: .utf8)))
        XCTAssertEqual(Darwin.kill(pid, 0), 0)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must stop the request.") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testEnvironmentKeepsGoogleKeyringAndExcludesAlternativeModelProviders() {
        let environment = AntigravityCLI.environment(source: [
            "HOME": "/Users/example", "USER": "example", "TMPDIR": "/tmp/example",
            "GEMINI_API_KEY": "private", "GOOGLE_API_KEY": "private", "AGY_ADC_AUTH": "1",
            "AGY_LLM_GATEWAY_URL": "https://untrusted.example", "CASCADE_GLOBAL_CONFIG_OVERRIDE": "{}",
            "HTTP_PROXY": "https://proxy.example", "PATH": "/private/bin"
        ])
        XCTAssertEqual(environment["HOME"], "/Users/example")
        XCTAssertEqual(environment["TMPDIR"], "/tmp/example")
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        for key in ["GEMINI_API_KEY", "GOOGLE_API_KEY", "AGY_ADC_AUTH", "AGY_LLM_GATEWAY_URL", "CASCADE_GLOBAL_CONFIG_OVERRIDE", "HTTP_PROXY"] {
            XCTAssertNil(environment[key])
        }
    }
}

final class AntigravityStreamTests: XCTestCase {
    private func line(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func initialization(tools: [String] = ["finish"], model: String = AntigravityRunner.model,
                                permissionMode: String = "request-review") throws -> Data {
        try line(["event": "init", "init": ["model": model, "agent": AntigravityCLI.agentName,
                                               "tools": tools, "permission_mode": permissionMode]])
    }

    func testPinnedRemoteModelIsRequiredAndRegisteredToolsAreAdvisory() throws {
        XCTAssertNoThrow(try AntigravitySelectionStream().accept(initialization(tools: ["finish", "run_command"])))
        XCTAssertThrowsError(try AntigravitySelectionStream().accept(initialization(model: "local-gemma")))
        XCTAssertNoThrow(try AntigravitySelectionStream().accept(initialization()))
    }

    func testExistingSafeUserPermissionPreferencesDoNotBlockSelection() throws {
        for permissionMode in ["request-review", "strict", "proceed-in-sandbox"] {
            XCTAssertNoThrow(try AntigravitySelectionStream().accept(initialization(permissionMode: permissionMode)))
        }
        for permissionMode in ["always-proceed", "unknown"] {
            XCTAssertThrowsError(try AntigravitySelectionStream().accept(initialization(permissionMode: permissionMode)))
        }
    }

    func testRequiresInitializationAndExactlyOneTerminalResult() throws {
        let stream = AntigravitySelectionStream()
        let result = try line(["event": "result", "result": ["status": "SUCCESS"]])
        XCTAssertThrowsError(try stream.accept(result))
        try stream.accept(initialization())
        XCTAssertThrowsError(try stream.accept(initialization()))
        XCTAssertThrowsError(try stream.result(from: initialization()))
        XCTAssertThrowsError(try stream.accept(result))
        try stream.accept(line(["event": "step_update", "step_update": ["step_type": "agent_response", "state": "DONE"]]))
        try stream.accept(result)
        XCTAssertThrowsError(try stream.accept(result))
        let envelope = try stream.result(from: initialization() + Data([0x0A]) + result + Data([0x0A]))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: envelope) as? [String: Any])?["status"] as? String, "SUCCESS")
    }

    func testUnexpectedToolStepsAreRejected() throws {
        let stream = AntigravitySelectionStream()
        try stream.accept(initialization())
        XCTAssertThrowsError(try stream.accept(line(["event": "step_update", "step_update": ["step_type": "tool", "tool_name": "run_command"]])))
        XCTAssertThrowsError(try stream.accept(line(["event": "step_update", "step_update": ["step_type": "tool", "tool_name": "finish"]])))
    }

    func testAuthenticationFailureBeforeInitializationRequiresConnection() throws {
        let data = try line(["status": "ERROR", "error": "authentication required"])
        XCTAssertThrowsError(try AntigravitySelectionStream().accept(data)) { error in
            XCTAssertEqual(error as? AntigravityError, .authenticationRequired)
        }
        let streamed = try line(["event": "result", "result": ["status": "ERROR", "error": "not signed in"]])
        XCTAssertThrowsError(try AntigravitySelectionStream().accept(streamed)) { error in
            XCTAssertEqual(error as? AntigravityError, .authenticationRequired)
        }
    }

    func testActiveResponseOrPendingNextTurnCannotBecomeACompleteChoice() throws {
        let stream = AntigravitySelectionStream()
        let result = try line(["event": "result", "result": ["status": "SUCCESS"]])
        try stream.accept(initialization())
        try stream.accept(line(["event": "step_update", "step_update": ["step_type": "agent_response", "state": "ACTIVE"]]))
        XCTAssertThrowsError(try stream.accept(result))
        try stream.accept(line(["event": "step_update", "step_update": ["step_type": "agent_response", "state": "DONE"]]))
        try stream.accept(line(["event": "step_update", "step_update": ["step_type": "user_input", "state": "DONE"]]))
        XCTAssertThrowsError(try stream.accept(result))
    }
}
