import Testing
import Foundation
@testable import ChappieCore

@Suite("Terminal confirmation flow")
struct TerminalConfirmationTests {

    private func marker(_ command: String = "echo hi") -> String {
        PendingTerminalCommand(command: command, threadId: UUID(), timeout: 42).encoded
    }

    // MARK: Flow

    @Test("A tool result that is not a marker passes through untouched")
    func plainResultPassesThrough() async {
        let out = await TerminalConfirmationFlow.resolve(
            toolName: "run_terminal", result: "hello", confirm: { _ in .run }
        ) { _ in "SHOULD NOT RUN" }
        #expect(out == "hello")
    }

    @Test("A marker from another tool is not treated as a confirmation")
    func otherToolIgnored() async {
        let text = marker()
        let out = await TerminalConfirmationFlow.resolve(
            toolName: "read_file", result: text, confirm: { _ in .run }
        ) { _ in "SHOULD NOT RUN" }
        #expect(out == text)
    }

    @Test("Run: the command runs and its real output is returned")
    func runReturnsOutput() async {
        let out = await TerminalConfirmationFlow.resolve(
            toolName: "run_terminal", result: marker("ls"), confirm: { _ in .run }
        ) { pending in "ran \(pending.command) timeout=\(Int(pending.timeout ?? 0))" }
        #expect(out == "ran ls timeout=42")
    }

    @Test("Cancel: the model gets an explicit 'declined' answer and nothing runs")
    func declineIsExplicit() async {
        let out = await TerminalConfirmationFlow.resolve(
            toolName: "run_terminal", result: marker("rm x"), confirm: { _ in .decline }
        ) { _ in "SHOULD NOT RUN" }
        #expect(out.contains("declined"))
        #expect(out.contains("rm x"))
        #expect(out.contains("NOT executed"))
        #expect(!out.contains("CHAPPIE_TERMINAL_CONFIRM"))
    }

    @Test("No handler: the command is not run and the model is told why")
    func noHandler() async {
        let out = await TerminalConfirmationFlow.resolve(
            toolName: "run_terminal", result: marker(), confirm: nil
        ) { _ in "SHOULD NOT RUN" }
        #expect(out.contains("NOT executed"))
        #expect(!out.contains("CHAPPIE_TERMINAL_CONFIRM"))
    }

    @Test("The marker keeps the timeout and decodes an old marker without it")
    func markerRoundTrip() {
        let decoded = PendingTerminalCommand.decode(from: marker("pwd"))
        #expect(decoded?.command == "pwd")
        #expect(decoded?.timeout == 42)

        let id = UUID().uuidString
        let old = "\(PendingTerminalCommand.markerPrefix){\"command\":\"pwd\",\"threadId\":\"\(id)\"}"
        #expect(PendingTerminalCommand.decode(from: old)?.timeout == nil)
    }

    // MARK: Gate

    @Test("The gate returns the decision made while waiting")
    func gateDecisionWhileWaiting() async {
        let gate = TerminalDecisionGate()
        async let decision = gate.wait()
        try? await Task.sleep(nanoseconds: 50_000_000)
        gate.resolve(.run)
        #expect(await decision == .run)
    }

    @Test("A decision made before wait() is not lost")
    func gateDecisionBeforeWait() async {
        let gate = TerminalDecisionGate()
        gate.resolve(.decline)
        #expect(await gate.wait() == .decline)
    }

    @Test("The first decision wins")
    func gateFirstWins() async {
        let gate = TerminalDecisionGate()
        gate.resolve(.run)
        gate.resolve(.decline)
        #expect(await gate.wait() == .run)
    }

    @Test("Stop (task cancellation) while waiting resolves to decline")
    func gateCancellation() async {
        let gate = TerminalDecisionGate()
        let task = Task { await gate.wait() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        #expect(await task.value == .decline)
    }
}
