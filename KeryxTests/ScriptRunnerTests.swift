import Testing
import Foundation
@testable import Keryx

@MainActor
@Suite("/exec")
struct ScriptRunnerTests {
    @Test("Arguments split on spaces, quotes kept whole, -o first")
    func parsing() {
        #expect(ScriptRunner.parse("sh uptime") == .init(script: "sh", arguments: ["uptime"], send: false))
        #expect(ScriptRunner.parse("-o sh \"df -h\" /") == .init(script: "sh", arguments: ["df -h", "/"], send: true))
        #expect(ScriptRunner.parse("-o") == nil)
    }

    @Test("Only names from the scripts folder, never paths")
    func noPaths() {
        #expect(ScriptRunner.resolve("../../bin/sh") == nil)
        #expect(ScriptRunner.resolve("/bin/sh") == nil)
        #expect(ScriptRunner.resolve(".hidden") == nil)
    }

    @Test("Terminal colours and control characters are stripped")
    func ansi() {
        #expect(ScriptOutput.strip("\u{1B}[1;32mok\u{1B}[0m\tdone\u{07}") == "ok\tdone")
    }

    /// Runs only when ~/Library/Application Scripts/im.keryx.mac/keryx-selftest exists.
    @Test("A real script runs outside the sandbox and its output comes back",
          .enabled(if: ScriptRunner.resolve("keryx-selftest") != nil))
    func realRun() async {
        let outcome = await ScriptRunner.shared.run(.init(script: "keryx-selftest", arguments: ["a b", "c"], send: false))
        guard case let .finished(output, status) = outcome else { Issue.record("unexpected \(outcome)"); return }
        #expect(status == nil)
        #expect(output == ["args: a b|c", "home is readable: yes"])
    }
}
