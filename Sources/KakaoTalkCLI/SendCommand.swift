import ArgumentParser
import Darwin
import Foundation
import KakaoCore

extension KakaoTalkCLI {
    struct Send: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Preview a message by default. Sending requires --execute and --confirm-chat."
        )

        @Option(help: "Exact title of an already-open chat window.")
        var chat: String

        @Argument(help: "Message text. Use --stdin instead to avoid shell history.")
        var message: String?

        @Flag(help: "Read UTF-8 message text from piped standard input.")
        var stdin = false

        @Flag(help: "Explicitly request a preview. This is the default.")
        var dryRun = false

        @Flag(help: "Actually send the message after safety checks.")
        var execute = false

        @Option(help: "Repeat the exact chat title to confirm the recipient.")
        var confirmChat: String?

        @Flag(help: "Print machine-readable JSON.")
        var json = false

        func validate() throws {
            guard !(dryRun && execute) else {
                throw ValidationError("--dry-run and --execute cannot be used together.")
            }
            guard stdin != (message != nil) else {
                throw ValidationError("Provide either a message argument or --stdin, but not both.")
            }
            if stdin && isatty(STDIN_FILENO) != 0 {
                throw ValidationError("--stdin requires piped input. It will not open an interactive prompt.")
            }
        }

        func run() throws {
            let text = try stdin ? readStandardInput() : (message ?? "")
            let request = try SendRequest(chat: chat, text: text, execute: execute, confirmChat: confirmChat)
            let report = try MessageSender.send(request) { title in
                try AccessibilityClient().prepareSendSession(chat: title)
            }
            if json {
                try printJSON(report)
            } else {
                print("\(report.state == .preview ? "PREVIEW (not sent)" : "SUBMITTED (delivery not verified)"): \(terminalText(report.chat))")
                print(terminalText(report.text))
            }
        }

        private func readStandardInput() throws -> String {
            var data = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= 16000 else {
                    throw ValidationError("Standard input exceeds the 16000-byte safety limit.")
                }
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw ValidationError("Standard input must be valid UTF-8.")
            }
            return text
        }
    }
}