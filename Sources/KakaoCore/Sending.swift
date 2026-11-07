import AppKit
import ApplicationServices
import Darwin
import Foundation

public enum SendError: Error, LocalizedError, Equatable {
    case confirmationRequired
    case confirmationMismatch
    case unexpectedConfirmation
    case existingDraft
    case targetChanged
    case inputRejected
    case submissionUncertain
    case sendInProgress
    case lockUnavailable

    public var errorDescription: String? {
        switch self {
        case .confirmationRequired:
            return "Sending requires --execute and --confirm-chat with the exact chat title. Without --execute, only a preview is produced."
        case .confirmationMismatch:
            return "--confirm-chat must exactly match --chat. No action was performed."
        case .unexpectedConfirmation:
            return "--confirm-chat requires --execute. Omit both flags to preview."
        case .existingDraft:
            return "The message input already contains a draft. It was not overwritten. Clear or send it manually before retrying."
        case .targetChanged:
            return "The target window or keyboard focus changed. Sending was stopped; any draft was left in place."
        case .inputRejected:
            return "The app did not accept the exact draft or its Send button is unavailable. No send was attempted; check the input manually."
        case .submissionUncertain:
            return "The Send action was attempted, but submission could not be verified. Do not retry automatically. Check the conversation in KakaoTalk."
        case .sendInProgress:
            return "Another kakao process is sending a message. Wait for it to finish and check the conversation before retrying."
        case .lockUnavailable:
            return "The local send lock could not be acquired safely. No send was attempted."
        }
    }
}

public struct SendRequest: Sendable {
    public let chat: String
    public let text: String
    public let execute: Bool

    public init(chat: String, text: String, execute: Bool = false, confirmChat: String? = nil) throws {
        guard !chat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KakaoError.invalidArgument("--chat cannot be empty.")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KakaoError.invalidArgument("The message cannot be empty.")
        }
        guard text.utf16.count <= 4000 else {
            throw KakaoError.invalidArgument("This CLI limits a message to 4000 UTF-16 code units.")
        }
        guard !text.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t"
        }) else {
            throw KakaoError.invalidArgument("The message contains unsupported control characters.")
        }
        if execute {
            guard let confirmChat else { throw SendError.confirmationRequired }
            guard confirmChat == chat else { throw SendError.confirmationMismatch }
        } else if confirmChat != nil {
            throw SendError.unexpectedConfirmation
        }
        self.chat = chat
        self.text = text
        self.execute = execute
    }
}

public struct SendReport: Encodable, Sendable {
    public enum State: String, Encodable, Sendable {
        case preview
        case submitted
    }

    public let state: State
    public let chat: String
    public let text: String
    public let deliveryVerified: Bool
}

public protocol SendSession {
    func validateTarget(requireFocus: Bool) throws
    func currentDraft() throws -> String
    func focus() throws
    func writeDraft(_ text: String) throws
    func pressSend() throws
    func waitForDraftToClear() throws -> Bool
}

public enum MessageSender {
    public static func send(
        _ request: SendRequest,
        makeSession: (String) throws -> any SendSession
    ) throws -> SendReport {
        try Task.checkCancellation()
        let session = try makeSession(request.chat)
        try session.validateTarget(requireFocus: false)
        guard try session.currentDraft().isEmpty else { throw SendError.existingDraft }
        if !request.execute {
            return SendReport(state: .preview, chat: request.chat, text: request.text, deliveryVerified: false)
        }

        try Task.checkCancellation()
        try session.focus()
        try session.validateTarget(requireFocus: true)
        guard try session.currentDraft().isEmpty else { throw SendError.existingDraft }
        try Task.checkCancellation()
        try session.writeDraft(request.text)
        try session.validateTarget(requireFocus: true)
        guard try session.currentDraft() == request.text else { throw SendError.inputRejected }
        try Task.checkCancellation()
        try session.pressSend()
        do {
            guard try session.waitForDraftToClear() else { throw SendError.submissionUncertain }
        } catch {
            throw SendError.submissionUncertain
        }
        return SendReport(state: .submitted, chat: request.chat, text: request.text, deliveryVerified: false)
    }
}

final class SendLock {
    private let descriptor: Int32

    init(url: URL = FileManager.default.temporaryDirectory.appendingPathComponent("kakao-send-\(getuid()).lock")) throws {
        let opened = Darwin.open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard opened >= 0 else { throw SendError.lockUnavailable }
        var information = stat()
        guard fstat(opened, &information) == 0,
              information.st_uid == getuid(),
              information.st_nlink == 1,
              (information.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              (information.st_mode & 0o077) == 0 else {
            close(opened)
            throw SendError.lockUnavailable
        }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(opened)
            throw code == EWOULDBLOCK ? SendError.sendInProgress : SendError.lockUnavailable
        }
        descriptor = opened
    }

    deinit {
        close(descriptor)
    }
}

extension AXElement {
    func set(_ name: String, to value: CFTypeRef) throws {
        let error = AXUIElementSetAttributeValue(raw, name as CFString, value)
        guard error == .success else {
            throw KakaoError.accessibility("setting \(name)", error.rawValue)
        }
    }

    func perform(_ action: String) throws {
        let error = AXUIElementPerformAction(raw, action as CFString)
        guard error == .success else {
            throw KakaoError.accessibility("performing \(action)", error.rawValue)
        }
    }

    func hasSameElement(in attribute: String, as expected: AXElement) throws -> Bool {
        guard let value = try self.attribute(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return false
        }
        return CFEqual(value, expected.raw)
    }
}

extension AccessibilityClient {
    public func prepareSendSession(
        chat: String, autoOpen: Bool = false, isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> any SendSession {
        let window = try ensureConversation(named: chat, autoOpen: autoOpen)
        guard window.sendButtons.count == 1 else {
            throw KakaoError.unsupportedUI("Expected exactly one accessible Send button.")
        }
        return NativeSendSession(client: self, window: window, sendButton: window.sendButtons[0], isCancelled: isCancelled)
    }
}

private final class NativeSendSession: SendSession {
    let client: AccessibilityClient
    let window: ConversationWindow
    let sendButton: AXElement
    let isCancelled: @Sendable () -> Bool
    var expectedDraft: String?
    private var sendLock: SendLock?

    init(client: AccessibilityClient, window: ConversationWindow, sendButton: AXElement, isCancelled: @escaping @Sendable () -> Bool) {
        self.client = client
        self.window = window
        self.sendButton = sendButton
        self.isCancelled = isCancelled
    }

    func validateTarget(requireFocus: Bool) throws {
        try checkCancellation()
        let current = try client.conversation(named: window.title)
        guard CFEqual(current.element.raw, window.element.raw),
              CFEqual(current.composer.raw, window.composer.raw),
              current.sendButtons.count == 1,
              CFEqual(current.sendButtons[0].raw, sendButton.raw),
              try window.element.elements(kAXChildrenAttribute).allSatisfy({
                  try $0.text(kAXRoleAttribute) != kAXSheetRole
              }),
              (try window.element.attribute(kAXMinimizedAttribute) as? Bool) != true else {
            throw SendError.targetChanged
        }
        if requireFocus {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == client.application.processIdentifier,
                  try client.root.hasSameElement(in: kAXFocusedWindowAttribute, as: window.element),
                  try client.root.hasSameElement(in: kAXFocusedUIElementAttribute, as: window.composer) else {
                throw SendError.targetChanged
            }
        }
    }

    func currentDraft() throws -> String {
        guard let text = try window.composer.text(kAXValueAttribute) else {
            throw KakaoError.unsupportedUI("The message input cannot be read safely.")
        }
        return text
    }

    func focus() throws {
        sendLock = try SendLock()
        try validateTarget(requireFocus: false)
        try checkCancellation()
        let activated: Bool
        if #available(macOS 14.0, *) {
            activated = client.application.activate()
        } else {
            activated = client.application.activate(options: [.activateIgnoringOtherApps])
        }
        guard activated else { throw SendError.targetChanged }
        let deadline = Date().addingTimeInterval(2)
        while !client.application.isActive && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard client.application.isActive else { throw SendError.targetChanged }
        try checkCancellation()
        try window.element.perform(kAXRaiseAction)
        try window.composer.set(kAXFocusedAttribute, to: kCFBooleanTrue)
    }

    func writeDraft(_ text: String) throws {
        try validateTarget(requireFocus: true)
        guard try currentDraft().isEmpty else { throw SendError.existingDraft }
        try checkCancellation()
        try window.composer.set(kAXValueAttribute, to: text as CFString)
        expectedDraft = text
    }

    func pressSend() throws {
        try validateTarget(requireFocus: true)
        guard let expectedDraft,
              try currentDraft() == expectedDraft,
              (try sendButton.attribute(kAXEnabledAttribute) as? Bool) == true else {
            throw SendError.inputRejected
        }
                try checkCancellation()
        do {
            try sendButton.perform(kAXPressAction)
        } catch {
            throw SendError.submissionUncertain
        }
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        guard !isCancelled() else { throw CancellationError() }
    }

    func waitForDraftToClear() throws -> Bool {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if try currentDraft().isEmpty { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < deadline
        return false
    }
}