import AppKit
import ApplicationServices
import Foundation

public struct ChatSearchReport: Encodable, Sendable {
    public let query: String
    public let matches: [String]
}

private enum PendingSearch: Error {
    case tooManyRows
}

enum ChatSearchPolicy {
    static func exactResultIndex(titles: [String], chat: String) throws -> Int {
        let index = try ConversationParser.windowIndex(titles: titles.map(Optional.some), matching: chat)
        guard titles.count == 1 else {
            throw KakaoError.unsupportedUI("The search has multiple results. Use a unique conversation title or open the intended conversation manually.")
        }
        return index
    }
}

extension AXElement {
    func element(_ name: String) throws -> AXElement? {
        guard let value = try attribute(name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(raw: value as! AXUIElement)
    }
}

extension AccessibilityClient {
    func activate(window: AXElement) throws {
        let activated: Bool
        if #available(macOS 14.0, *) {
            activated = application.activate()
        } else {
            activated = application.activate(options: [.activateIgnoringOtherApps])
        }
        guard activated else { throw SendError.targetChanged }
        let deadline = Date().addingTimeInterval(2)
        while !application.isActive && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        if (try window.attribute(kAXMinimizedAttribute) as? Bool) == true {
            try window.set(kAXMinimizedAttribute, to: kCFBooleanFalse)
        }
        try window.perform(kAXRaiseAction)
        guard application.isActive else { throw SendError.targetChanged }
    }

    func mainWindow() throws -> AXElement {
        let titles = ["KakaoTalk", "\u{CE74}\u{CE74}\u{C624}\u{D1A1}"]
        let windows = try root.elements(kAXWindowsAttribute).filter {
            let title = try $0.text(kAXTitleAttribute) ?? ""
            let subrole = try $0.text(kAXSubroleAttribute)
            return titles.contains(title) && subrole == kAXStandardWindowSubrole
        }
        guard windows.count == 1 else {
            throw KakaoError.unsupportedUI("The KakaoTalk main window must be available and unlocked.")
        }
        return windows[0]
    }

    func searchField(in window: AXElement) throws -> AXElement? {
        let fields = try window.descendants(pruning: [kAXTableRole, kAXOutlineRole, kAXScrollBarRole]).filter {
            try $0.text(kAXRoleAttribute) == kAXTextFieldRole && $0.isSettable(kAXValueAttribute)
        }
        guard fields.count <= 1 else {
            throw KakaoError.unsupportedUI("More than one search field is present.")
        }
        return fields.first
    }

    func prepareChatSearch(query: String) throws -> (window: AXElement, field: AXElement) {
        try Task.checkCancellation()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              query.utf16.count <= 200,
              !query.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw KakaoError.invalidArgument("The chat search query must contain 1-200 characters without control characters.")
        }
        let window = try mainWindow()
        try activate(window: window)
        guard try root.hasSameElement(in: kAXFocusedWindowAttribute, as: window) else {
            throw SendError.targetChanged
        }
        if try searchField(in: window) == nil {
            guard let menuBar = try root.element(kAXMenuBarAttribute) else {
                throw KakaoError.unsupportedUI("The app menu is unavailable.")
            }
            let editMenus = try menuBar.elements(kAXChildrenAttribute).filter {
                ["Edit", "\u{D3B8}\u{C9D1}"].contains(try $0.text(kAXTitleAttribute) ?? "")
            }
            guard editMenus.count == 1 else {
                throw KakaoError.unsupportedUI("The Edit menu is unavailable.")
            }
            let findItems = try editMenus[0].descendants().filter {
                let title = try $0.text(kAXTitleAttribute) ?? ""
                let actions = try $0.actions()
                return ["Find", "\u{CC3E}\u{AE30}"].contains(title) && actions.contains(kAXPressAction)
            }
            guard findItems.count == 1,
                  (try findItems[0].attribute(kAXEnabledAttribute) as? Bool) == true else {
                throw KakaoError.unsupportedUI("The Find menu action is unavailable.")
            }
            try Task.checkCancellation()
            try findItems[0].perform(kAXPressAction)
        }
        let deadline = Date().addingTimeInterval(2)
        var field = try searchField(in: window)
        while field == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            field = try searchField(in: window)
        }
        guard let field,
              try root.hasSameElement(in: kAXFocusedWindowAttribute, as: window) else {
            throw KakaoError.unsupportedUI("The main-window search field did not appear.")
        }
        try Task.checkCancellation()
        try field.set(kAXFocusedAttribute, to: kCFBooleanTrue)
        try field.set(kAXValueAttribute, to: query as CFString)
        guard try field.text(kAXValueAttribute) == query else {
            throw KakaoError.unsupportedUI("The search field did not accept the requested name.")
        }
        return (window, field)
    }

    func searchRows(in window: AXElement) throws -> [AXElement] {
        let tables = try window.descendants(pruning: [kAXTableRole, kAXOutlineRole, kAXScrollBarRole]).filter {
            try $0.text(kAXRoleAttribute) == kAXTableRole
        }
        guard tables.count == 1 else {
            throw KakaoError.unsupportedUI("Expected one chat search results table.")
        }
        if let rows = try tables[0].attribute(kAXRowsAttribute) as? [AXUIElement] {
            guard rows.count <= 200 else { throw PendingSearch.tooManyRows }
            return rows.map { AXElement(raw: $0) }
        }
        return try tables[0].elements(kAXChildrenAttribute).filter { try $0.text(kAXRoleAttribute) == kAXRowRole }
    }

    func searchRowTitle(_ row: AXElement) throws -> String? {
        for element in try row.descendants(maxNodes: 100) {
            if try element.text(kAXRoleAttribute) == kAXStaticTextRole,
               let title = try element.text(kAXValueAttribute), !title.isEmpty {
                return title
            }
        }
        return nil
    }

    func settledSearchMatches(window: AXElement, field: AXElement, query: String) throws -> [(row: AXElement, title: String)] {
        let started = Date()
        let deadline = started.addingTimeInterval(4)
        var previousTitles: [String?]?
        var stableSince = started
        repeat {
            try Task.checkCancellation()
            guard try field.text(kAXValueAttribute) == query,
                  application.isActive,
                  try root.hasSameElement(in: kAXFocusedWindowAttribute, as: window) else {
                throw SendError.targetChanged
            }
            do {
                let rows = try searchRows(in: window)
                let titles = try rows.map { try searchRowTitle($0) }
                if titles != previousTitles {
                    previousTitles = titles
                    stableSince = Date()
                }
                if Date().timeIntervalSince(started) >= 0.7 && Date().timeIntervalSince(stableSince) >= 0.3 {
                    return zip(rows, titles).compactMap { row, title in
                        guard let title, title.localizedCaseInsensitiveContains(query) else { return nil }
                        return (row, title)
                    }
                }
            } catch PendingSearch.tooManyRows {
                previousTitles = nil
                stableSince = Date()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        throw KakaoError.unsupportedUI("Chat search did not settle. Use a more specific name or retry when the app is responsive.")
    }

    public func findChats(query: String) throws -> ChatSearchReport {
        let lock = try SendLock()
        return try withExtendedLifetime(lock) {
            let search = try prepareChatSearch(query: query)
            let matches = try settledSearchMatches(window: search.window, field: search.field, query: query)
            return ChatSearchReport(query: query, matches: matches.map(\.title))
        }
    }

    private func openSearchRow(_ row: AXElement, chat: String, mainWindow: AXElement) throws {
        guard CGPreflightPostEventAccess() else { throw KakaoError.permissionRequired }
        guard let label = try row.descendants(maxNodes: 100).first(where: {
            try $0.text(kAXRoleAttribute) == kAXStaticTextRole && $0.text(kAXValueAttribute) == chat
        }),
        let positionValue = try label.attribute(kAXPositionAttribute),
        let sizeValue = try label.attribute(kAXSizeAttribute),
        CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            throw KakaoError.unsupportedUI("The exact result label has no accessible bounds.")
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else {
            throw KakaoError.unsupportedUI("The search result bounds are invalid.")
        }
        let point = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        guard point.x.isFinite, point.y.isFinite else { throw SendError.targetChanged }
        let source = CGEventSource(stateID: .hidSystemState)
        for clickCount in 1...2 {
            try Task.checkCancellation()
            guard application.isActive,
                  try root.hasSameElement(in: kAXFocusedWindowAttribute, as: mainWindow),
                  try searchRowTitle(row) == chat else { throw SendError.targetChanged }
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
                  let hit else { throw SendError.targetChanged }
            var current: AXElement? = AXElement(raw: hit)
            var belongsToRow = false
            for _ in 0..<12 {
                guard let element = current else { break }
                if CFEqual(element.raw, row.raw) { belongsToRow = true; break }
                current = try element.element(kAXParentAttribute)
            }
            guard belongsToRow,
                  let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
                throw SendError.targetChanged
            }
            down.flags = []
            up.flags = []
            down.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
            down.post(tap: .cghidEventTap)
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            up.post(tap: .cghidEventTap)
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        }
    }

    public func openChat(chat: String) throws -> OpenChat {
        let lock = try SendLock()
        return try withExtendedLifetime(lock) {
            let search = try prepareChatSearch(query: chat)
            let matches = try settledSearchMatches(window: search.window, field: search.field, query: chat)
            let index = try ChatSearchPolicy.exactResultIndex(titles: matches.map(\.title), chat: chat)
            let row = matches[index].row
            guard try searchRowTitle(row) == chat,
                  try search.field.text(kAXValueAttribute) == chat,
                  application.isActive,
                  try root.hasSameElement(in: kAXFocusedWindowAttribute, as: search.window),
                  try row.isSettable(kAXSelectedAttribute) else {
                throw KakaoError.unsupportedUI("The exact search result cannot be selected safely.")
            }
            try row.set(kAXSelectedAttribute, to: kCFBooleanTrue)
            guard (try row.attribute(kAXSelectedAttribute) as? Bool) == true,
                  try root.hasSameElement(in: kAXFocusedUIElementAttribute, as: search.field) else {
                throw SendError.targetChanged
            }
            try Task.checkCancellation()
            try openSearchRow(row, chat: chat, mainWindow: search.window)
            let deadline = Date().addingTimeInterval(3)
            repeat {
                do {
                    let opened = try conversation(named: chat)
                    return OpenChat(title: opened.title, minimized: false, canSend: opened.sendButtons.count == 1)
                } catch KakaoError.chatNotFound {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
            } while Date() < deadline
            throw KakaoError.unsupportedUI("The requested conversation window did not open. No message was sent.")
        }
    }

    func ensureConversation(named chat: String, autoOpen: Bool) throws -> ConversationWindow {
        do {
            return try conversation(named: chat)
        } catch KakaoError.chatNotFound where autoOpen {
            _ = try openChat(chat: chat)
            return try conversation(named: chat)
        }
    }
}