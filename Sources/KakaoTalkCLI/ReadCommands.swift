import ArgumentParser
import Foundation
import KakaoCore

struct ReadOptions: ParsableArguments {
    @Option(help: "Exact conversation title. Closed chats are opened automatically.")
    var chat: String

    @Flag(help: "Only read an already-open window; do not navigate the app.")
    var noOpen = false

    @Option(help: "Number of trailing loaded UI rows to read (1-200), not full history.")
    var limit = 30

    @Flag(help: "Print machine-readable JSON.")
    var json = false

    func validate() throws {
        guard !chat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--chat cannot be empty.")
        }
        guard (1...200).contains(limit) else {
            throw ValidationError("--limit must be between 1 and 200.")
        }
    }
}

extension KakaoTalkCLI {
    struct OpenChatCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "open-chat",
            abstract: "Search for and open one exact conversation. May mark messages as read."
        )

        @Option(help: "Exact conversation title to open.")
        var chat: String

        @Flag(help: "Print machine-readable JSON.")
        var json = false

        func run() throws {
            let report = try AccessibilityClient().openChat(chat: chat)
            if json { try printJSON(report) }
            else { print("Opened: \(terminalText(report.title))") }
        }
    }

    struct FindChats: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Search for conversations in the KakaoTalk main window.")

        @Argument(help: "Conversation name to search for.")
        var query: String

        @Flag(help: "Print machine-readable JSON.")
        var json = false

        func run() throws {
            let report = try AccessibilityClient().findChats(query: query)
            if json {
                try printJSON(report)
            } else {
                for title in report.matches { print(terminalText(title)) }
            }
        }
    }

    struct Chats: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List already-open chat windows, not the entire account.")

        @Flag(help: "Print machine-readable JSON.")
        var json = false

        func run() throws {
            let chats = try AccessibilityClient().chats()
            if json {
                try printJSON(chats)
            } else if chats.isEmpty {
                print("No open conversations. Open a chat window in KakaoTalk first.")
            } else {
                for chat in chats {
                    print("\(terminalText(chat.title))\(chat.minimized ? " [minimized]" : "")\(chat.canSend ? "" : " [read only]")")
                }
            }
        }
    }

    struct Messages: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Read loaded text, automatically opening a closed conversation if needed.")

        @OptionGroup var options: ReadOptions

        func run() throws {
            let report = try AccessibilityClient().messages(chat: options.chat, limit: options.limit, autoOpen: !options.noOpen)
            try printMessages(report, json: options.json)
        }
    }

    struct Search: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Search loaded text, opening the conversation if needed. Not full history.")

        @Argument(help: "Case-insensitive text to find.")
        var query: String

        @OptionGroup var options: ReadOptions

        func validate() throws {
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError("The search query cannot be empty.")
            }
        }

        func run() throws {
            let report = try AccessibilityClient().messages(chat: options.chat, limit: options.limit, query: query, autoOpen: !options.noOpen)
            try printMessages(report, json: options.json)
        }
    }
}

func printMessages(_ report: MessagesReport, json: Bool) throws {
    if json {
        try printJSON(report)
    } else {
        print("\(terminalText(report.chat)): \(report.messages.count) text rows (loaded UI only)")
        for message in report.messages {
            print("[\(message.row)] \(terminalText(message.text))\n")
        }
    }
}

func terminalText(_ text: String) -> String {
    text.unicodeScalars.map { scalar in
        if (CharacterSet.controlCharacters.contains(scalar) && scalar != "\n" && scalar != "\t") ||
            (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) {
            return "\\u{\(String(scalar.value, radix: 16))}"
        }
        return String(scalar)
    }.joined()
}