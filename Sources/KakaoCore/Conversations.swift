import ApplicationServices
import Foundation

public struct OpenChat: Encodable, Sendable {
    public let title: String
    public let minimized: Bool
    public let canSend: Bool
}

public struct MessageRecord: Encodable, Equatable, Sendable {
    public let row: Int
    public let text: String
}

public struct MessagesReport: Encodable, Sendable {
    public let chat: String
    public let scope: String
    public let availableRows: Int
    public let scannedRows: Int
    public let limited: Bool
    public let query: String?
    public let messages: [MessageRecord]
}

enum ConversationParser {
    static func windowIndex(titles: [String?], matching title: String) throws -> Int {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KakaoError.invalidArgument("--chat cannot be empty.")
        }
        let matches = titles.indices.filter { titles[$0] == title }
        guard let index = matches.first else { throw KakaoError.chatNotFound }
        guard matches.count == 1 else { throw KakaoError.ambiguousChat }
        return index
    }

    static func isComposer(role: String, valueSettable: Bool) -> Bool {
        role == kAXTextAreaRole && valueSettable
    }

    static func isSendButton(role: String, title: String?, description: String?, actions: [String]) -> Bool {
        guard role == kAXButtonRole, actions.contains(kAXPressAction) else { return false }
        let labels = ["send", "send message", "\u{C804}\u{C1A1}", "\u{BCF4}\u{B0B4}\u{AE30}"]
        return [title, description].compactMap { $0?.lowercased() }.contains { labels.contains($0) }
    }

    static func message(from node: AccessibilityNode, row: Int) -> MessageRecord? {
        func texts(in element: AccessibilityNode) -> [String] {
            if element.role == kAXStaticTextRole || (element.role == kAXTextAreaRole && !element.valueSettable) {
                if let text = element.value ?? element.title,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return [text]
                }
            }
            if [kAXButtonRole, kAXImageRole, kAXScrollBarRole].contains(element.role) || element.valueSettable {
                return []
            }
            return element.children.flatMap { texts(in: $0) }
        }
        let parts = texts(in: node)
        guard !parts.isEmpty else { return nil }
        return MessageRecord(row: row, text: parts.joined(separator: "\n"))
    }
}

struct ConversationWindow {
    let element: AXElement
    let title: String
    let composer: AXElement
    let table: AXElement
    let sendButtons: [AXElement]
}

extension AXElement {
    func descendants(pruning roles: Set<String> = [], maxDepth: Int = 12, maxNodes: Int = 300) throws -> [AXElement] {
        var result: [AXElement] = []
        func visit(_ element: AXElement, depth: Int, ancestors: [AXUIElement]) throws {
            guard !ancestors.contains(where: { CFEqual($0, element.raw) }) else { return }
            guard result.count < maxNodes else {
                throw KakaoError.unsupportedUI("The control tree exceeds the safety limit.")
            }
            result.append(element)
            if roles.contains(try element.text(kAXRoleAttribute) ?? "") { return }
            let children = try element.elements(kAXChildrenAttribute)
            guard depth < maxDepth || children.isEmpty else {
                throw KakaoError.unsupportedUI("The control tree is deeper than expected.")
            }
            for child in children {
                try visit(child, depth: depth + 1, ancestors: ancestors + [element.raw])
            }
        }
        try visit(self, depth: 0, ancestors: [])
        return result
    }
}

extension AccessibilityClient {
    func layout(for window: AXElement) throws -> ConversationWindow? {
        guard try window.text(kAXSubroleAttribute) == kAXStandardWindowSubrole,
              let title = try window.text(kAXTitleAttribute), !title.isEmpty else { return nil }
        let controls = try window.descendants(pruning: [kAXTableRole, kAXOutlineRole, kAXScrollBarRole])
        var composers: [AXElement] = []
        var tables: [AXElement] = []
        var sendButtons: [AXElement] = []
        for control in controls {
            let role = try control.text(kAXRoleAttribute) ?? ""
            if role == kAXTableRole { tables.append(control) }
            if role == kAXTextAreaRole,
               ConversationParser.isComposer(role: role, valueSettable: try control.isSettable(kAXValueAttribute)) {
                composers.append(control)
            }
            if role == kAXButtonRole,
               ConversationParser.isSendButton(
                   role: role,
                   title: try control.metadata(kAXTitleAttribute),
                   description: try control.metadata(kAXDescriptionAttribute),
                   actions: try control.actions()
               ) {
                sendButtons.append(control)
            }
        }
        guard composers.count == 1, tables.count == 1 else { return nil }
        return ConversationWindow(
            element: window, title: title, composer: composers[0], table: tables[0], sendButtons: sendButtons
        )
    }

    func conversation(named title: String) throws -> ConversationWindow {
        let windows = try root.elements(kAXWindowsAttribute)
        let index = try ConversationParser.windowIndex(
            titles: try windows.map { try $0.text(kAXTitleAttribute) }, matching: title
        )
        guard let conversation = try layout(for: windows[index]) else {
            throw KakaoError.unsupportedUI("Expected one message table and one editable message area in the selected window.")
        }
        return conversation
    }

    public func chats() throws -> [OpenChat] {
        var result: [OpenChat] = []
        for window in try root.elements(kAXWindowsAttribute) {
            if let conversation = try layout(for: window) {
                result.append(OpenChat(
                    title: conversation.title,
                    minimized: try window.attribute(kAXMinimizedAttribute) as? Bool ?? false,
                    canSend: conversation.sendButtons.count == 1
                ))
            }
        }
        return result
    }

    public func messages(chat: String, limit: Int = 30, query: String? = nil, autoOpen: Bool = true) throws -> MessagesReport {
        guard (1...200).contains(limit) else {
            throw KakaoError.invalidArgument("--limit must be between 1 and 200.")
        }
        if let query, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw KakaoError.invalidArgument("The search query cannot be empty.")
        }
        let conversation = try ensureConversation(named: chat, autoOpen: autoOpen)
        let rows: [AXElement]
        if let rawRows = try conversation.table.attribute(kAXRowsAttribute) as? [AXUIElement] {
            rows = rawRows.map { AXElement(raw: $0) }
        } else {
            rows = try conversation.table.elements(kAXChildrenAttribute).filter { try $0.text(kAXRoleAttribute) == kAXRowRole }
        }
        let start = max(0, rows.count - limit)
        var messages: [MessageRecord] = []
        for index in start..<rows.count {
            let snapshot = try snapshot([rows[index]], includeValues: true, maxDepth: 12, maxNodes: 300)
            guard !snapshot.truncated else {
                throw KakaoError.unsupportedUI("A message row was truncated. Use 'kakao inspect' to inspect this app version.")
            }
            if let node = snapshot.windows.first,
               let record = ConversationParser.message(from: node, row: index),
               query.map({ record.text.localizedCaseInsensitiveContains($0) }) ?? true {
                messages.append(record)
            }
        }
        return MessagesReport(
            chat: chat, scope: "loaded-ui", availableRows: rows.count,
            scannedRows: rows.count - start, limited: start > 0, query: query, messages: messages
        )
    }
}