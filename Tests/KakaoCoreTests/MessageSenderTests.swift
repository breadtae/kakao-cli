import XCTest
@testable import KakaoCore

final class MessageSenderTests: XCTestCase {
    func testDefaultPreviewDoesNotMutateTheApp() throws {
        let session = FakeSendSession()
        let request = try SendRequest(chat: "Fixture Chat", text: "Hello")
        let report = try MessageSender.send(request) { _ in session }
        XCTAssertEqual(report.state, .preview)
        XCTAssertFalse(report.deliveryVerified)
        XCTAssertEqual(session.focusCount, 0)
        XCTAssertEqual(session.writes, [])
        XCTAssertEqual(session.sendCount, 0)
    }

    func testExecuteRequiresConfirmation() {
        XCTAssertThrowsError(try SendRequest(chat: "Fixture Chat", text: "Hello", execute: true)) {
            XCTAssertEqual($0 as? SendError, .confirmationRequired)
        }
    }

    func testConfirmationMustMatchExactly() {
        XCTAssertThrowsError(try SendRequest(chat: "Fixture Chat", text: "Hello", execute: true, confirmChat: "Fixture")) {
            XCTAssertEqual($0 as? SendError, .confirmationMismatch)
        }
    }

    func testConfirmationWithoutExecuteIsRejected() {
        XCTAssertThrowsError(try SendRequest(chat: "Fixture Chat", text: "Hello", confirmChat: "Fixture Chat")) {
            XCTAssertEqual($0 as? SendError, .unexpectedConfirmation)
        }
    }

    func testExistingDraftIsNotOverwritten() throws {
        let session = FakeSendSession()
        session.draft = "Existing draft"
        XCTAssertThrowsError(try MessageSender.send(request()) { _ in session }) {
            XCTAssertEqual($0 as? SendError, .existingDraft)
        }
        XCTAssertEqual(session.focusCount, 0)
        XCTAssertEqual(session.writes, [])
        XCTAssertEqual(session.draft, "Existing draft")
        XCTAssertEqual(session.sendCount, 0)
    }

    func testNewDraftAfterFocusIsNotOverwritten() throws {
        let session = FakeSendSession()
        session.draftAfterFocus = "User started typing"
        XCTAssertThrowsError(try MessageSender.send(request()) { _ in session }) {
            XCTAssertEqual($0 as? SendError, .existingDraft)
        }
        XCTAssertEqual(session.writes, [])
        XCTAssertEqual(session.sendCount, 0)
        XCTAssertEqual(session.draft, "User started typing")
    }

    func testFocusChangeStopsBeforeWriting() throws {
        let session = FakeSendSession()
        session.loseFocus = true
        XCTAssertThrowsError(try MessageSender.send(request()) { _ in session }) {
            XCTAssertEqual($0 as? SendError, .targetChanged)
        }
        XCTAssertEqual(session.writes, [])
        XCTAssertEqual(session.sendCount, 0)
    }

    func testDraftMismatchStopsBeforeSendingAndLeavesDraft() throws {
        let session = FakeSendSession()
        session.rejectWrite = true
        XCTAssertThrowsError(try MessageSender.send(request()) { _ in session }) {
            XCTAssertEqual($0 as? SendError, .inputRejected)
        }
        XCTAssertEqual(session.sendCount, 0)
        XCTAssertEqual(session.draft, "Unexpected text")
    }

    func testConfirmedSendPreservesUnicodeAndNewlines() throws {
        let session = FakeSendSession()
        let text = "\u{C548}\u{B155}\nSecond line \u{1F642}"
        let request = try SendRequest(chat: "Fixture Chat", text: text, execute: true, confirmChat: "Fixture Chat")
        let report = try MessageSender.send(request) { _ in session }
        XCTAssertEqual(report.state, .submitted)
        XCTAssertFalse(report.deliveryVerified)
        XCTAssertEqual(session.writes, [text])
        XCTAssertEqual(session.sendCount, 1)
    }

    func testUnclearedDraftIsUncertainAndNeverRetried() throws {
        let session = FakeSendSession()
        session.clearsDraft = false
        XCTAssertThrowsError(try MessageSender.send(request()) { _ in session }) {
            XCTAssertEqual($0 as? SendError, .submissionUncertain)
        }
        XCTAssertEqual(session.sendCount, 1)
        XCTAssertEqual(session.writes.count, 1)
    }

    func testSendFailureIsNeverRetried() throws {
        let session = FakeSendSession()
        session.failSend = true
        XCTAssertThrowsError(try MessageSender.send(request()) { _ in session }) {
            XCTAssertEqual($0 as? SendError, .submissionUncertain)
        }
        XCTAssertEqual(session.sendCount, 1)
    }

    func testFailedVerificationIsReportedAsUncertain() throws {
        let session = FakeSendSession()
        session.failVerification = true
        XCTAssertThrowsError(try MessageSender.send(request()) { _ in session }) {
            XCTAssertEqual($0 as? SendError, .submissionUncertain)
        }
        XCTAssertEqual(session.sendCount, 1)
    }

    func testRejectsEmptyOversizedAndControlCharacterMessages() {
        for text in [" \n", String(repeating: "a", count: 4001), "Hello\0", "\u{1B}[31m"] {
            XCTAssertThrowsError(try SendRequest(chat: "Fixture Chat", text: text))
        }
        XCTAssertThrowsError(try SendRequest(chat: " ", text: "Hello"))
    }

    func testSendLockRejectsConcurrentWritersAndReleasesOnClose() throws {
        try withLockURL { url in
            var first: SendLock? = try SendLock(url: url)
            try withExtendedLifetime(first) {
                XCTAssertThrowsError(try SendLock(url: url)) {
                    XCTAssertEqual($0 as? SendError, .sendInProgress)
                }
            }
            first = nil
            XCTAssertNoThrow(try SendLock(url: url))
        }
    }

    func testSendLockRejectsSymbolicLinks() throws {
        try withLockURL { url in
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: url.appendingPathExtension("target"))
            XCTAssertThrowsError(try SendLock(url: url)) {
                XCTAssertEqual($0 as? SendError, .lockUnavailable)
            }
        }
    }

    private func withLockURL(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kakao-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("send.lock"))
    }

    private func request() throws -> SendRequest {
        try SendRequest(chat: "Fixture Chat", text: "Hello", execute: true, confirmChat: "Fixture Chat")
    }
}

private final class FakeSendSession: SendSession {
    var draft = ""
    var draftAfterFocus: String?
    var focusCount = 0
    var writes: [String] = []
    var sendCount = 0
    var loseFocus = false
    var rejectWrite = false
    var clearsDraft = true
    var failSend = false
    var failVerification = false

    func validateTarget(requireFocus: Bool) throws {
        if requireFocus && loseFocus { throw SendError.targetChanged }
    }

    func currentDraft() throws -> String { draft }

    func focus() throws {
        focusCount += 1
        if let draftAfterFocus { draft = draftAfterFocus }
    }

    func writeDraft(_ text: String) throws {
        writes.append(text)
        draft = rejectWrite ? "Unexpected text" : text
    }

    func pressSend() throws {
        sendCount += 1
        if failSend { throw SendError.submissionUncertain }
    }

    func waitForDraftToClear() throws -> Bool {
        if failVerification { throw SendError.targetChanged }
        if clearsDraft { draft = "" }
        return clearsDraft
    }
}