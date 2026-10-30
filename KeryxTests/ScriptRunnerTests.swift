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

@MainActor
@Suite("/exec through sh")
struct ScriptRunnerShellTests {
    /// Runs only when an `sh` script is installed.
    @Test("A command that isn't a script goes to sh as typed, in the home folder",
          .enabled(if: ScriptRunner.resolve("sh") != nil))
    func shell() async {
        let request = ScriptRunner.request(for: "-o echo \"a  b\" && pwd")
        #expect(request == .init(script: "sh", arguments: ["echo \"a  b\" && pwd"], send: true))
        guard let request else { return }
        let outcome = await ScriptRunner.shared.run(request)
        guard case let .finished(output, _) = outcome else { Issue.record("unexpected \(outcome)"); return }
        #expect(output == ["a  b", NSHomeDirectory().replacingOccurrences(of: "/Library/Containers/im.keryx.mac/Data", with: "")])
    }
}
