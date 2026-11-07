import Foundation
import KakaoCore
import MCP
import XCTest
@testable import KakaoMCP

final class MCPServerTests: XCTestCase, @unchecked Sendable {
    func testHandshakeListsStatusTool() async throws {
        try await withClient { client in
            let (tools, cursor) = try await client.listTools()
            XCTAssertNil(cursor)
            XCTAssertEqual(tools.count, 8)
            XCTAssertTrue(tools.contains { $0.name == "kakao_send_message" })
            XCTAssertEqual(tools.first?.annotations.readOnlyHint, true)
        }
    }

    func testStatusReturnsJSON() async throws {
        try await withClient { client in
            let (content, isError) = try await client.callTool(name: "kakao_status")
            XCTAssertNotEqual(isError, true)
            guard case let .text(text, _, _) = content.first else { return XCTFail("Expected text content") }
            let payload = try JSONDecoder().decode([String: Value].self, from: Data(text.utf8))
            XCTAssertNotNil(payload["accessibilityGranted"]?.boolValue)
        }
    }

    func testUnexpectedArgumentsAreRejected() async throws {
        try await withClient { client in
            do {
                _ = try await client.callTool(name: "kakao_status", arguments: ["execute": true])
                XCTFail("Expected invalid parameters")
            } catch let error as MCPError {
                guard case .invalidParams = error else { return XCTFail("Wrong protocol error") }
            }
        }
    }

    func testReadOpensClosedChatsByDefault() async throws {
        let backend = await FakeBackend()
        try await withClient(backend: backend) { client in
            _ = try await client.callTool(name: "kakao_read_messages", arguments: ["chat": "Fixture Chat"])
        }
        let calls = await backend.calls
        XCTAssertEqual(calls, [.readMessages(chat: "Fixture Chat", limit: 30, autoOpen: true)])
    }

    func testSearchCanDisableAutomaticOpening() async throws {
        let backend = await FakeBackend()
        try await withClient(backend: backend) { client in
            _ = try await client.callTool(name: "kakao_search_messages", arguments: [
                "chat": "Fixture Chat", "query": "lunch", "limit": 12, "auto_open": false
            ])
        }
        let calls = await backend.calls
        XCTAssertEqual(calls, [.searchMessages(chat: "Fixture Chat", query: "lunch", limit: 12, autoOpen: false)])
    }

    func testPreviewDoesNotAskForApprovalOrSend() async throws {
        let backend = await FakeBackend()
        let approval = await FakeApproval(accepts: true)
        try await withClient(backend: backend, approval: approval) { client in
            _ = try await client.callTool(name: "kakao_preview_message", arguments: ["chat": "Fixture Chat", "text": "Hello"])
        }
        let calls = await backend.calls
        let confirmations = await approval.confirmations
        XCTAssertEqual(calls, [.previewMessage(chat: "Fixture Chat", text: "Hello")])
        XCTAssertTrue(confirmations.isEmpty)
    }

    func testApprovedSendUsesTheExactPreviewedRecipientAndBody() async throws {
        let backend = await FakeBackend()
        let approval = await FakeApproval(accepts: true)
        let text = "\u{C548}\u{B155}\n\"Quoted\" text"
        try await withClient(backend: backend, approval: approval) { client in
            let (_, isError) = try await client.callTool(name: "kakao_send_message", arguments: ["chat": "Fixture Chat", "text": .string(text)])
            XCTAssertNotEqual(isError, true)
        }
        let calls = await backend.calls
        let confirmations = await approval.confirmations
        XCTAssertEqual(calls, [.previewMessage(chat: "Fixture Chat", text: text), .sendMessage(chat: "Fixture Chat", text: text)])
        XCTAssertEqual(confirmations, [["Fixture Chat", text]])
    }

    func testDeclinedSendNeverWrites() async throws {
        let backend = await FakeBackend()
        let approval = await FakeApproval(accepts: false)
        try await withClient(backend: backend, approval: approval) { client in
            let (content, isError) = try await client.callTool(name: "kakao_send_message", arguments: ["chat": "Fixture Chat", "text": "Hello"])
            XCTAssertNotEqual(isError, true)
            guard case let .text(text, _, _) = content.first else { return XCTFail("Expected text") }
            let result = try JSONDecoder().decode([String: Value].self, from: Data(text.utf8))
            XCTAssertEqual(result["state"], "cancelled")
        }
        let calls = await backend.calls
        XCTAssertEqual(calls, [.previewMessage(chat: "Fixture Chat", text: "Hello")])
    }

    func testPreflightFailureDoesNotRequestApproval() async throws {
        let backend = await FakeBackend(failPreview: true)
        let approval = await FakeApproval(accepts: true)
        try await withClient(backend: backend, approval: approval) { client in
            let (_, isError) = try await client.callTool(name: "kakao_send_message", arguments: ["chat": "Fixture Chat", "text": "Hello"])
            XCTAssertEqual(isError, true)
        }
        let confirmations = await approval.confirmations
        XCTAssertTrue(confirmations.isEmpty)
    }

    func testUncertainSendIsNotRetried() async throws {
        let backend = await FakeBackend(failSend: true)
        let approval = await FakeApproval(accepts: true)
        try await withClient(backend: backend, approval: approval) { client in
            let (_, isError) = try await client.callTool(name: "kakao_send_message", arguments: ["chat": "Fixture Chat", "text": "Hello"])
            XCTAssertEqual(isError, true)
        }
        let calls = await backend.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testReadOnlyModeDisablesSendingEvenWhenInvokedDirectly() async throws {
        let backend = await FakeBackend()
        try await withClient(backend: backend, allowsSending: false) { client in
            let (tools, _) = try await client.listTools()
            XCTAssertFalse(tools.contains { $0.name == "kakao_send_message" })
            do {
                _ = try await client.callTool(name: "kakao_send_message", arguments: ["chat": "Fixture Chat", "text": "Hello"])
                XCTFail("Disabled tool was callable")
            } catch let error as MCPError {
                guard case .invalidParams = error else { return XCTFail("Wrong error") }
            }
        }
        let calls = await backend.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testModelCannotSupplyApprovalOrExecutionFlags() throws {
        for key in ["approved", "execute", "confirm_chat", "command"] {
            XCTAssertThrowsError(try ToolCatalog.invocation(
                name: "kakao_send_message",
                arguments: ["chat": "Fixture Chat", "text": "Hello", key: true], allowsSending: true
            ))
        }
    }

    func testInvalidLimitsTypesAndBodiesFailBeforeBackendAccess() throws {
        for value in [Value.int(0), .int(201), .double(1.5), .string("30"), .bool(true)] {
            XCTAssertThrowsError(try ToolCatalog.invocation(name: "kakao_read_messages", arguments: ["chat": "Fixture Chat", "limit": value], allowsSending: true))
        }
        XCTAssertThrowsError(try ToolCatalog.invocation(name: "kakao_read_messages", arguments: ["chat": "Fixture Chat", "auto_open": "true"], allowsSending: true))
        for text in ["", " \n", "Hello\0", String(repeating: "a", count: 4001)] {
            XCTAssertThrowsError(try ToolCatalog.invocation(name: "kakao_send_message", arguments: ["chat": "Fixture Chat", "text": .string(text)], allowsSending: true))
        }
    }

    func testCancellationAfterApprovalPreventsSending() async throws {
        let backend = await FakeBackend()
        let approval = await FakeApproval(accepts: true, cancelsTask: true)
        let router = await KakaoToolRouter(backend: backend, approval: approval, allowsSending: true)
        let task = Task {
            try await router.call(.init(name: "kakao_send_message", arguments: ["chat": "Fixture Chat", "text": "Hello"]))
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        let calls = await backend.calls
        XCTAssertEqual(calls, [.previewMessage(chat: "Fixture Chat", text: "Hello")])
    }

    func testDisconnectedRequestCannotSendAfterApproval() async throws {
        let backend = await FakeBackend()
        let lifetime = ServerLifetime()
        let approval = await FakeApproval(accepts: true, disconnects: lifetime)
        let router = await KakaoToolRouter(backend: backend, approval: approval, allowsSending: true, lifetime: lifetime)
        do {
            _ = try await router.call(.init(name: "kakao_send_message", arguments: ["chat": "Fixture Chat", "text": "Hello"]))
            XCTFail("A disconnected request must not send")
        } catch is CancellationError {}
        let calls = await backend.calls
        XCTAssertEqual(calls, [.previewMessage(chat: "Fixture Chat", text: "Hello")])
    }

    func testNativeApprovalTimesOutWithoutSending() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KAKAO_UI_TESTS"] == "1", "Opt-in Mac dialog test")
        let approval = await MacSendApproval(timeout: 0.3)
        let accepted = try await approval.confirm(chat: "Approval test (no recipient)", text: "This is a local dialog test. No message can be sent.")
        XCTAssertFalse(accepted)
    }

    func testNativeApprovalClosesWhenConnectionStops() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KAKAO_UI_TESTS"] == "1", "Opt-in Mac dialog test")
        let approval = await MacSendApproval()
        let cancellation = Task.detached {
            try await Task.sleep(for: .milliseconds(300))
            approval.cancelPendingRequest()
        }
        let accepted = try await approval.confirm(chat: "Approval test (no recipient)", text: "Connection-close test. No message can be sent.")
        try await cancellation.value
        XCTAssertFalse(accepted)
    }

    private func withClient(
        backend: (any KakaoToolBackend)? = nil,
        approval: (any SendApproval)? = nil,
        allowsSending: Bool = true,
        _ body: (Client) async throws -> Void
    ) async throws {
        let transports = await InMemoryTransport.createConnectedPair()
        let server = await KakaoMCPService.makeServer(backend: backend, approval: approval, allowsSending: allowsSending)
        let client = Client(name: "kakao-tests", version: "1.0.0")
        do {
            try await server.start(transport: transports.server)
            let initialization = try await client.connect(transport: transports.client)
            XCTAssertEqual(initialization.serverInfo.name, "kakao-mac")
            try await body(client)
        } catch {
            await client.disconnect()
            await server.stop()
            throw error
        }
        await client.disconnect()
        await server.stop()
    }
}

@MainActor
private final class FakeBackend: KakaoToolBackend {
    var calls: [KakaoInvocation] = []
    let failPreview: Bool
    let failSend: Bool

    init(failPreview: Bool = false, failSend: Bool = false) {
        self.failPreview = failPreview
        self.failSend = failSend
    }

    func perform(_ invocation: KakaoInvocation) throws -> Value {
        calls.append(invocation)
        if case .previewMessage = invocation, failPreview { throw SendError.existingDraft }
        if case .sendMessage = invocation, failSend { throw SendError.submissionUncertain }
        return .object(["fixture": true])
    }
}

@MainActor
private final class FakeApproval: SendApproval {
    let accepts: Bool
    let cancelsTask: Bool
    let disconnects: ServerLifetime?
    var confirmations: [[String]] = []

    init(accepts: Bool, cancelsTask: Bool = false, disconnects: ServerLifetime? = nil) {
        self.accepts = accepts
        self.cancelsTask = cancelsTask
        self.disconnects = disconnects
    }

    func confirm(chat: String, text: String) async throws -> Bool {
        confirmations.append([chat, text])
        if cancelsTask { withUnsafeCurrentTask { $0?.cancel() } }
        disconnects?.close()
        return accepts
    }

    nonisolated func cancelPendingRequest() {}
}