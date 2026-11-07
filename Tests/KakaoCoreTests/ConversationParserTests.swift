import ApplicationServices
import Foundation
import XCTest
@testable import KakaoCore

final class ConversationParserTests: XCTestCase {
    func testClosedChatOpensAutomatically() throws {
        guard ProcessInfo.processInfo.environment["KAKAO_UI_TESTS"] == "1",
              let title = ProcessInfo.processInfo.environment["KAKAO_TEST_CHAT"], !title.isEmpty else {
            throw XCTSkip("Opt-in live test requires KAKAO_UI_TESTS=1 and KAKAO_TEST_CHAT.")
        }
        let client = try AccessibilityClient()
        do {
            let existing = try client.conversation(named: title)
            try XCTSkipUnless(try existing.composer.text(kAXValueAttribute) == "", "Preserve the user's existing draft")
            guard let close = try existing.element.element(kAXCloseButtonAttribute) else {
                throw XCTSkip("The chat has no accessible close button")
            }
            try close.perform(kAXPressAction)
        } catch KakaoError.chatNotFound {}
        let deadline = Date().addingTimeInterval(2)
        var closed = false
        repeat {
            do { _ = try client.conversation(named: title) }
            catch KakaoError.chatNotFound { closed = true; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        XCTAssertTrue(closed)
        guard closed else { return }
        let result = try client.messages(chat: title, limit: 2)
        XCTAssertEqual(result.chat, title)
        XCTAssertEqual(result.scope, "loaded-ui")
        XCTAssertLessThanOrEqual(result.scannedRows, 2)
        let reopened = try client.conversation(named: title)
        XCTAssertEqual(try reopened.composer.text(kAXValueAttribute), "")
    }

    func testOpeningRequiresOneExactSearchResult() throws {
        XCTAssertEqual(try ChatSearchPolicy.exactResultIndex(titles: ["Fixture Chat"], chat: "Fixture Chat"), 0)
        XCTAssertThrowsError(try ChatSearchPolicy.exactResultIndex(titles: ["Fixture Chat"], chat: "Fixture"))
        XCTAssertThrowsError(try ChatSearchPolicy.exactResultIndex(titles: [], chat: "Fixture Chat"))
    }

    func testOpeningRejectsDuplicatesAndAdditionalPartialMatches() {
        XCTAssertThrowsError(try ChatSearchPolicy.exactResultIndex(titles: ["Fixture Chat", "Fixture Chat"], chat: "Fixture Chat"))
        XCTAssertThrowsError(try ChatSearchPolicy.exactResultIndex(titles: ["Fixture Chat 2", "Fixture Chat"], chat: "Fixture Chat"))
    }

    func testSelectsOnlyTheExactWindowTitle() throws {
        XCTAssertEqual(try ConversationParser.windowIndex(titles: [nil, "Fixture", "Fixture Chat"], matching: "Fixture Chat"), 2)
        XCTAssertThrowsError(try ConversationParser.windowIndex(titles: ["Fixture Chat"], matching: "Fixture"))
        XCTAssertThrowsError(try ConversationParser.windowIndex(titles: ["Fixture Chat"], matching: "fixture chat"))
    }

    func testRejectsDuplicateWindowTitles() {
        XCTAssertThrowsError(try ConversationParser.windowIndex(titles: ["Fixture Chat", "Fixture Chat"], matching: "Fixture Chat")) {
            guard case KakaoError.ambiguousChat = $0 else { return XCTFail("Expected an ambiguous-chat error") }
        }
    }

    func testRejectsMissingAndEmptyWindowTitles() {
        XCTAssertThrowsError(try ConversationParser.windowIndex(titles: [], matching: "Fixture Chat")) {
            guard case KakaoError.chatNotFound = $0 else { return XCTFail("Expected a missing-chat error") }
        }
        XCTAssertThrowsError(try ConversationParser.windowIndex(titles: [" "], matching: " "))
    }

    func testReadsMessageBodyAndMetadataInOrder() {
        let row = node("AXRow", children: [
            node("AXStaticText", value: "Example Sender"),
            node("AXScrollArea", children: [node("AXTextArea", value: "First line\nSecond line")]),
            node("AXStaticText", value: "12:34")
        ])
        XCTAssertEqual(
            ConversationParser.message(from: row, row: 7),
            MessageRecord(row: 7, text: "Example Sender\nFirst line\nSecond line\n12:34")
        )
    }

    func testDoesNotReadDraftsOrButtonsAsMessages() {
        let row = node("AXRow", children: [
            node("AXTextArea", value: "Private draft", settable: true),
            node("AXButton", children: [node("AXStaticText", value: "Menu")]),
            node("AXTextArea", value: "Message body")
        ])
        XCTAssertEqual(ConversationParser.message(from: row, row: 0)?.text, "Message body")
    }

    func testEmptyAndImageOnlyRowsAreOmitted() {
        XCTAssertNil(ConversationParser.message(from: node("AXRow", children: [
            node("AXImage"), node("AXStaticText", value: "  \n")
        ]), row: 0))
    }

    func testRepeatedTextIsPreserved() {
        let row = node("AXRow", children: [
            node("AXStaticText", value: "Same"), node("AXTextArea", value: "Same")
        ])
        XCTAssertEqual(ConversationParser.message(from: row, row: 0)?.text, "Same\nSame")
    }

    func testComposerMustBeAnEditableTextArea() {
        XCTAssertTrue(ConversationParser.isComposer(role: "AXTextArea", valueSettable: true))
        XCTAssertFalse(ConversationParser.isComposer(role: "AXTextArea", valueSettable: false))
        XCTAssertFalse(ConversationParser.isComposer(role: "AXTextField", valueSettable: true))
    }

    func testSendButtonMustHaveAnExactLabelAndPressAction() {
        XCTAssertTrue(ConversationParser.isSendButton(role: "AXButton", title: "Send", description: nil, actions: ["AXPress"]))
        XCTAssertTrue(ConversationParser.isSendButton(role: "AXButton", title: "\u{C804}\u{C1A1}", description: nil, actions: ["AXPress"]))
        XCTAssertFalse(ConversationParser.isSendButton(role: "AXButton", title: "Send file", description: nil, actions: ["AXPress"]))
        XCTAssertFalse(ConversationParser.isSendButton(role: "AXButton", title: "Send", description: nil, actions: []))
    }

    private func node(
        _ role: String,
        value: String? = nil,
        settable: Bool = false,
        children: [AccessibilityNode] = []
    ) -> AccessibilityNode {
        AccessibilityNode(
            path: "fixture", role: role, subrole: nil, title: nil, value: value,
            description: nil, identifier: nil, valueSettable: settable, actions: [], children: children
        )
    }
}