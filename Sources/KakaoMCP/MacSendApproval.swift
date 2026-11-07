import AppKit
import Foundation

private final class ApprovalCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private final class ApprovalState: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var active: ApprovalCancellation?

    func begin() throws -> ApprovalCancellation {
        try lock.withLock {
            guard !stopped, active == nil else { throw CancellationError() }
            let cancellation = ApprovalCancellation()
            active = cancellation
            return cancellation
        }
    }

    func finish() { lock.withLock { active = nil } }

    func stop() {
        let cancellation = lock.withLock {
            stopped = true
            return active
        }
        cancellation?.cancel()
    }
}

@MainActor
public final class MacSendApproval: SendApproval {
    private nonisolated let state = ApprovalState()
    private let timeout: TimeInterval

    public init() { timeout = 45 }

    init(timeout: TimeInterval) { self.timeout = timeout }

    public func confirm(chat: String, text: String) async throws -> Bool {
        let cancellation = try state.begin()
        defer { state.finish() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let approved = present(chat: chat, text: text, cancellation: cancellation)
            try Task.checkCancellation()
            return approved && !cancellation.isCancelled
        } onCancel: {
            cancellation.cancel()
        }
    }

    public nonisolated func cancelPendingRequest() {
        state.stop()
    }

    private func present(chat: String, text: String, cancellation: ApprovalCancellation) -> Bool {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Send a KakaoTalk message?"
        alert.informativeText = "To: \(display(chat))\nThis request expires automatically."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Send")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let body = NSTextView(frame: scroll.contentView.bounds)
        body.isEditable = false
        body.isSelectable = true
        body.isRichText = false
        body.isVerticallyResizable = true
        body.isHorizontallyResizable = false
        body.autoresizingMask = [.width]
        body.textContainer?.widthTracksTextView = true
        body.font = .systemFont(ofSize: 13)
        body.string = display(text)
        scroll.documentView = body
        alert.accessoryView = scroll

        let deadline = Date().addingTimeInterval(timeout)
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            if cancellation.isCancelled || Date() >= deadline {
                MainActor.assumeIsolated { NSApplication.shared.abortModal() }
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer {
            timer.invalidate()
            alert.window.orderOut(nil)
        }
        if #available(macOS 14.0, *) {
            _ = NSRunningApplication.current.activate()
        } else {
            application.activate(ignoringOtherApps: true)
        }
        let response = alert.runModal()
        return response == .alertSecondButtonReturn && Date() < deadline && !cancellation.isCancelled
    }

    private func display(_ text: String) -> String {
        text.unicodeScalars.map { scalar in
            if (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) {
                return "\\u{\(String(scalar.value, radix: 16))}"
            }
            return String(scalar)
        }.joined()
    }
}