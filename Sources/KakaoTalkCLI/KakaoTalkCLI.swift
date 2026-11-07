import ArgumentParser
import Foundation
import KakaoCore

@main
struct KakaoTalkCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kakao",
        abstract: "An independent CLI for the KakaoTalk macOS app.",
        version: "0.2.0",
        subcommands: [Status.self, Chats.self, FindChats.self, OpenChatCommand.self, Messages.self, Search.self, Send.self, Inspect.self, MCPCommand.self]
    )
}

extension KakaoTalkCLI {
    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check the app and Accessibility permission without reading chats."
        )

        @Flag(help: "Print machine-readable JSON.")
        var json = false

        @Flag(help: "Ask macOS to show the Accessibility permission prompt.")
        var requestAccess = false

        func run() throws {
            let report = KakaoApp.status(requestAccess: requestAccess)

            if json {
                try printJSON(report)
            } else {
                print("KakaoTalk: \(report.installed ? "installed" : "not installed")")
                print("Running: \(report.running ? "yes" : "no")")
                print("Accessibility: \(report.accessibilityGranted ? "granted" : "not granted")")
                if !report.accessibilityGranted {
                    print("Enable your terminal or VS Code in System Settings > Privacy & Security > Accessibility.")
                }
            }
        }
    }

    struct Inspect: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Inspect the app's Accessibility tree. Text is hidden by default."
        )

        @Flag(help: "Include private window titles and message text in the output.")
        var includeValues = false

        @Flag(help: "Inspect the application menu bar instead of windows.")
        var menuBar = false

        @Option(help: "Maximum tree depth (1-30).")
        var maxDepth = 8

        @Option(help: "Maximum number of elements (1-5000).")
        var maxNodes = 500

        func validate() throws {
            guard (1...30).contains(maxDepth), (1...5000).contains(maxNodes) else {
                throw ValidationError("--max-depth must be 1-30 and --max-nodes must be 1-5000.")
            }
        }

        func run() throws {
            let snapshot = try AccessibilityClient().inspect(
                includeValues: includeValues, maxDepth: maxDepth, maxNodes: maxNodes, menuBar: menuBar
            )
            try printJSON(snapshot)
        }
    }
}

func printJSON<Value: Encodable>(_ value: Value) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}