import AppKit

/// `/exec`: runs one of *your* scripts, outside Keryx's sandbox.
///
/// A sandboxed app may only run what the user has put in its Application
/// Scripts folder (`~/Library/Application Scripts/im.keryx.mac/`), through
/// `NSUserUnixTask`. Keryx can't write there, so nothing runs that you didn't
/// place yourself. For WeeChat-style `/exec <any command>`, put a script
/// named `sh` there that runs its arguments.
@MainActor
final class ScriptRunner {
    static let shared = ScriptRunner()

    struct Request: Equatable, Sendable {
        var script: String
        var arguments: [String]
        /// `-o`: send the output to the conversation instead of showing it to you.
        var send: Bool
    }

    enum Outcome: Sendable {
        case finished(output: [String], status: String?)
        case timedOut(output: [String])
        case failed(String)
    }

    static let timeout: Duration = .seconds(30)
    static let maxLines = 200

    /// Runs in progress, so `/exec -kill` can stop waiting for them.
    private var running: [UUID: CheckedContinuation<Outcome, Never>] = [:]

    // MARK: - Where scripts live

    nonisolated static var folder: URL? {
        try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: false)
    }

    /// The scripts you can run: executable files in the folder.
    nonisolated static func available() -> [String] {
        guard let folder,
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.filter { !$0.hasPrefix(".") && FileManager.default.isExecutableFile(atPath: folder.appending(path: $0).path) }
            .sorted()
    }

    /// A script by name, with or without its extension. Never a path: no
    /// "/" and no "..", so nothing outside the folder can be named.
    nonisolated static func resolve(_ name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix("."), let folder else { return nil }
        let names = available()
        guard let match = names.first(where: { $0 == name })
                ?? names.first(where: { ($0 as NSString).deletingPathExtension == name }) else { return nil }
        return folder.appending(path: match)
    }

    /// `/exec [-o] script args…`, split on spaces with "quoted strings" kept whole.
    nonisolated static func parse(_ text: String) -> Request? {
        var words: [String] = []
        var current = ""
        var quote: Character?
        for char in text {
            if let q = quote {
                if char == q { quote = nil } else { current.append(char) }
            } else if char == "\"" || char == "'" {
                quote = char
            } else if char == " " {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { words.append(current) }
        var send = false
        if words.first == "-o" { send = true; words.removeFirst() }
        guard let script = words.first else { return nil }
        return Request(script: script, arguments: Array(words.dropFirst()), send: send)
    }

    // MARK: - Running

    func run(_ request: Request) async -> Outcome {
        guard let url = Self.resolve(request.script) else {
            return .failed(String(localized: "There’s no script “\(request.script)” in the scripts folder."))
        }
        let task: NSUserUnixTask
        do { task = try NSUserUnixTask(url: url) } catch {
            return .failed(error.localizedDescription)
        }
        let collector = OutputCollector()
        let pipe = Pipe()
        task.standardOutput = pipe.fileHandleForWriting
        task.standardError = pipe.fileHandleForWriting
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collector.append(data) }
        }
        let id = UUID()
        let outcome: Outcome = await withCheckedContinuation { continuation in
            running[id] = continuation
            task.execute(withArguments: request.arguments) { error in
                Task { @MainActor in
                    try? pipe.fileHandleForWriting.close()
                    // Let the last bytes arrive before reading them out.
                    try? await Task.sleep(for: .milliseconds(150))
                    let status = (error as NSError?).map { $0.localizedDescription }
                    self.finish(id, .finished(output: collector.lines(max: Self.maxLines), status: status))
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: Self.timeout)
                self.finish(id, .timedOut(output: collector.lines(max: Self.maxLines)))
            }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        return outcome
    }

    private func finish(_ id: UUID, _ outcome: Outcome) {
        running.removeValue(forKey: id)?.resume(returning: outcome)
    }

    /// Stops waiting for every run. NSUserUnixTask can't kill the process,
    /// so it may carry on; its output just won't show.
    @discardableResult
    func stopWaiting() -> Int {
        let count = running.count
        for id in Array(running.keys) { finish(id, .timedOut(output: [])) }
        return count
    }

    /// Confirms before sending more than a few lines to a conversation.
    static func confirmSending(_ lines: Int, to target: String) -> Bool {
        guard lines > 5 else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Send \(lines) lines to \(target)?")
        alert.informativeText = String(localized: "Everyone in the conversation will see the command’s output.")
        alert.addButton(withTitle: String(localized: "Send"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Gathers a script's output from the pipe's background queue.
private final class OutputCollector: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }

    /// The output as lines, terminal colour codes removed, at most `max`.
    func lines(max: Int) -> [String] {
        lock.lock(); let copy = data; lock.unlock()
        let text = String(decoding: copy, as: UTF8.self)
        let clean = ScriptOutput.strip(text)
        var lines = clean.split(separator: "\n", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return Array(lines.prefix(max))
    }
}

enum ScriptOutput {
    /// Removes ANSI escape sequences (colours, cursor moves) and stray
    /// control characters other than tab.
    static func strip(_ text: String) -> String {
        let noANSI = text.replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[ -/]*[@-~]|\x{1B}\][^\x{07}]*\x{07}|\x{1B}[@-Z\\-_]"#,
                                               with: "", options: .regularExpression)
        return String(noANSI.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || $0.value >= 0x20 }.map(Character.init))
    }
}
