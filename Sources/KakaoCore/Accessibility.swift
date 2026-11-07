import AppKit
import ApplicationServices
import Foundation

public enum KakaoError: Error, LocalizedError {
    case permissionRequired
    case appNotRunning
    case accessibility(String, Int32)
    case invalidArgument(String)
    case chatNotFound
    case ambiguousChat
    case unsupportedUI(String)

    public var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "Accessibility permission is required. Enable your terminal or VS Code in System Settings > Privacy & Security > Accessibility, then retry. Run 'kakao status --request-access' to show the system prompt."
        case .appNotRunning:
            return "KakaoTalk is not running. Open the macOS app and sign in first."
        case let .accessibility(operation, code):
            return "KakaoTalk Accessibility failed during \(operation) (\(code)). Check that the app is responsive and unlocked."
        case let .invalidArgument(message):
            return message
        case .chatNotFound:
            return "No conversation has that exact title in the current results. Check 'kakao find-chats NAME', or open the intended conversation manually."
        case .ambiguousChat:
            return "More than one open window has that title. Close the duplicate windows before continuing."
        case let .unsupportedUI(message):
            return "Unsupported KakaoTalk screen: \(message) The command was stopped."
        }
    }
}

public struct StatusReport: Encodable, Sendable {
    public let installed: Bool
    public let running: Bool
    public let accessibilityGranted: Bool
    public let appVersion: String?
    public let appPath: String?
    public let processID: pid_t?
}

public enum KakaoApp {
    public static let bundleID = "com.kakao.KakaoTalkMac"

    public static func status(requestAccess: Bool = false) -> StatusReport {
        let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        let version = applicationURL.flatMap { Bundle(url: $0) }?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let trusted: Bool
        if requestAccess {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(options)
        } else {
            trusted = AXIsProcessTrusted()
        }
        return StatusReport(
            installed: applicationURL != nil,
            running: application != nil,
            accessibilityGranted: trusted,
            appVersion: version,
            appPath: applicationURL?.path,
            processID: application?.processIdentifier
        )
    }
}

public struct AccessibilityNode: Codable, Sendable {
    public let path: String
    public let role: String
    public let subrole: String?
    public let title: String?
    public let value: String?
    public let description: String?
    public let identifier: String?
    public let valueSettable: Bool
    public let actions: [String]
    public let children: [AccessibilityNode]
}

public struct AccessibilitySnapshot: Encodable, Sendable {
    public let includesValues: Bool
    public let truncated: Bool
    public let nodeCount: Int
    public let windows: [AccessibilityNode]
}

struct AXElement {
    let raw: AXUIElement

    func attribute(_ name: String) throws -> CFTypeRef? {
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(raw, name as CFString, &result)
        switch error {
        case .success:
            return result
        case .noValue, .attributeUnsupported:
            return nil
        default:
            throw KakaoError.accessibility("reading \(name)", error.rawValue)
        }
    }

    func text(_ name: String) throws -> String? {
        let result = try attribute(name)
        if let text = result as? String { return text }
        if let text = result as? NSAttributedString { return text.string }
        return nil
    }

    func metadata(_ name: String) throws -> String? {
        do {
            return try text(name)
        } catch KakaoError.accessibility(_, let code) where code == AXError.failure.rawValue {
            return nil
        }
    }

    func elements(_ name: String) throws -> [AXElement] {
        let elements = try attribute(name) as? [AXUIElement] ?? []
        return elements.map { AXElement(raw: $0) }
    }

    func isSettable(_ name: String) throws -> Bool {
        var settable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(raw, name as CFString, &settable)
        if error == .attributeUnsupported { return false }
        guard error == .success else {
            throw KakaoError.accessibility("checking \(name)", error.rawValue)
        }
        return settable.boolValue
    }

    func actions() throws -> [String] {
        var names: CFArray?
        let error = AXUIElementCopyActionNames(raw, &names)
        if error == .actionUnsupported { return [] }
        guard error == .success else {
            throw KakaoError.accessibility("listing actions", error.rawValue)
        }
        return names as? [String] ?? []
    }
}

public final class AccessibilityClient {
    let application: NSRunningApplication
    let root: AXElement

    public init() throws {
        guard AXIsProcessTrusted() else { throw KakaoError.permissionRequired }
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: KakaoApp.bundleID
        ).first else { throw KakaoError.appNotRunning }
        self.application = application
        self.root = AXElement(raw: AXUIElementCreateApplication(application.processIdentifier))
        let error = AXUIElementSetMessagingTimeout(root.raw, 2)
        guard error == .success else {
            throw KakaoError.accessibility("setting the response timeout", error.rawValue)
        }
    }

    public func inspect(
        includeValues: Bool = false,
        maxDepth: Int = 8,
        maxNodes: Int = 500,
        menuBar: Bool = false
    ) throws -> AccessibilitySnapshot {
        let elements: [AXElement]
        if menuBar {
            guard let value = try root.attribute(kAXMenuBarAttribute),
                  CFGetTypeID(value) == AXUIElementGetTypeID() else {
                throw KakaoError.unsupportedUI("The app menu bar is unavailable.")
            }
            elements = [AXElement(raw: value as! AXUIElement)]
        } else {
            elements = try root.elements(kAXWindowsAttribute)
        }
        return try snapshot(
            elements,
            includeValues: includeValues, maxDepth: maxDepth, maxNodes: maxNodes
        )
    }

    func snapshot(
        _ elements: [AXElement],
        includeValues: Bool,
        maxDepth: Int,
        maxNodes: Int
    ) throws -> AccessibilitySnapshot {
        guard (1...30).contains(maxDepth) else {
            throw KakaoError.invalidArgument("--max-depth must be between 1 and 30.")
        }
        guard (1...5000).contains(maxNodes) else {
            throw KakaoError.invalidArgument("--max-nodes must be between 1 and 5000.")
        }
        var nodeCount = 0
        var truncated = false

        func visit(_ element: AXElement, path: String, depth: Int, ancestors: [AXUIElement]) throws -> AccessibilityNode? {
            guard nodeCount < maxNodes else {
                truncated = true
                return nil
            }
            guard !ancestors.contains(where: { CFEqual($0, element.raw) }) else {
                truncated = true
                return nil
            }
            nodeCount += 1
            let rawChildren: [AXElement]
            do {
                rawChildren = try element.elements(kAXChildrenAttribute)
            } catch KakaoError.accessibility(_, let code) where code == AXError.invalidUIElement.rawValue {
                truncated = true
                return nil
            }
            var children: [AccessibilityNode] = []
            if depth < maxDepth {
                for (index, child) in rawChildren.enumerated() {
                    if nodeCount >= maxNodes {
                        truncated = true
                        break
                    }
                    if let node = try visit(child, path: "\(path)/\(index)", depth: depth + 1, ancestors: ancestors + [element.raw]) {
                        children.append(node)
                    }
                }
            } else if !rawChildren.isEmpty {
                truncated = true
            }
            return AccessibilityNode(
                path: path,
                role: try element.text(kAXRoleAttribute) ?? "AXUnknown",
                subrole: try element.text(kAXSubroleAttribute),
                title: includeValues ? try element.metadata(kAXTitleAttribute) : nil,
                value: includeValues ? try element.metadata(kAXValueAttribute) : nil,
                description: includeValues ? try element.metadata(kAXDescriptionAttribute) : nil,
                identifier: includeValues ? try element.metadata(kAXIdentifierAttribute) : nil,
                valueSettable: try element.isSettable(kAXValueAttribute),
                actions: try element.actions(),
                children: children
            )
        }

        var windows: [AccessibilityNode] = []
        for (index, window) in elements.enumerated() {
            if let node = try visit(window, path: "window/\(index)", depth: 0, ancestors: []) {
                windows.append(node)
            }
        }
        return AccessibilitySnapshot(
            includesValues: includeValues,
            truncated: truncated,
            nodeCount: nodeCount,
            windows: windows
        )
    }
}