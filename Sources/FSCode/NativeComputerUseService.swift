import AppKit
import ApplicationServices
import AgentConnectionCore

/// A deliberately small Accessibility bridge. It exposes no screenshots and only
/// accepts actions against elements returned by the most recent inspection.
@MainActor
final class NativeComputerUseService {
    private struct SnapshotElement {
        let processIdentifier: pid_t
        let applicationBundleID: String
        let element: AXUIElement
    }

    private var snapshotID = UUID()
    private var elements: [String: SnapshotElement] = [:]
    private let blockedBundleIDs: Set<String> = [
        "com.apple.securityagent",
        "com.apple.keychainaccess",
        "com.apple.passwords"
    ]

    func handle(_ request: AgentDynamicToolRequest) async -> AgentDynamicToolResult {
        guard request.namespace == nil, request.toolName == "computer_use" else {
            return .rejected("Unsupported computer-use tool.")
        }
        guard AXIsProcessTrusted() else {
            return .rejected("Accessibility permission is required before Computer Use can inspect or act on apps.")
        }
        guard let arguments = arguments(from: request.arguments) else {
            return .rejected("computer_use requires action and app_bundle_id string arguments.")
        }
        guard !blockedBundleIDs.contains(arguments.bundleID.lowercased()) else {
            return .rejected("Computer Use is unavailable for authentication and keychain apps.")
        }
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: arguments.bundleID).first,
              !application.isTerminated else {
            return .rejected("The requested app is not running.")
        }

        switch arguments.action {
        case "inspect":
            return inspect(application: application, bundleID: arguments.bundleID)
        case "press", "set_text":
            guard let elementID = arguments.elementID else {
                return .rejected("computer_use \(arguments.action) requires an element_id from the current inspection.")
            }
            return perform(
                action: arguments.action,
                text: arguments.text,
                elementID: elementID,
                application: application,
                bundleID: arguments.bundleID
            )
        default:
            return .rejected("computer_use action must be inspect, press, or set_text.")
        }
    }

    private func inspect(application: NSRunningApplication, bundleID: String) -> AgentDynamicToolResult {
        let process = AXUIElementCreateApplication(application.processIdentifier)
        guard AXUIElementSetMessagingTimeout(process, 0.15) == .success else {
            return .rejected("Computer Use could not contact the requested app.")
        }
        snapshotID = UUID()
        elements.removeAll(keepingCapacity: true)
        var rows: [[String: String]] = []
        var visited = 0
        let deadline = Date().addingTimeInterval(0.35)
        collect(
            from: process,
            processIdentifier: application.processIdentifier,
            bundleID: bundleID,
            rows: &rows,
            visited: &visited,
            depth: 0,
            deadline: deadline
        )
        guard let data = try? JSONSerialization.data(withJSONObject: ["snapshot_id": snapshotID.uuidString, "elements": rows]),
              let message = String(data: data, encoding: .utf8) else {
            return .rejected("Computer Use could not encode the accessibility snapshot.")
        }
        return .accepted(message)
    }

    private func perform(action: String, text: String?, elementID: String, application: NSRunningApplication, bundleID: String) -> AgentDynamicToolResult {
        guard let entry = elements[elementID], entry.applicationBundleID == bundleID,
              entry.processIdentifier == application.processIdentifier else {
            return .rejected("That element_id is stale. Inspect the app again before acting.")
        }
        guard !isSecure(entry.element) else {
            return .rejected("Computer Use never reads or writes secure text fields.")
        }
        let result: AXError
        if action == "press" {
            result = AXUIElementPerformAction(entry.element, kAXPressAction as CFString)
        } else {
            guard let text, text.utf8.count <= 16_384 else {
                return .rejected("set_text requires text up to 16 KiB.")
            }
            result = AXUIElementSetAttributeValue(entry.element, kAXValueAttribute as CFString, text as CFTypeRef)
        }
        guard result == .success else { return .rejected("Accessibility action failed (\(result.rawValue)).") }
        snapshotID = UUID()
        elements.removeAll(keepingCapacity: false)
        return .accepted(action == "press" ? "Pressed \(elementID)." : "Updated \(elementID).")
    }

    private func collect(
        from element: AXUIElement,
        processIdentifier: pid_t,
        bundleID: String,
        rows: inout [[String: String]],
        visited: inout Int,
        depth: Int,
        deadline: Date
    ) {
        guard rows.count < 80, visited < 240, depth < 12, Date() < deadline else { return }
        visited += 1
        let role = stringAttribute(kAXRoleAttribute, from: element) ?? "AXUnknown"
        let title = stringAttribute(kAXTitleAttribute, from: element)
            ?? stringAttribute(kAXDescriptionAttribute, from: element)
            ?? stringAttribute(kAXValueAttribute, from: element)
            ?? ""
        if isActionable(element, role: role) {
            let id = "\(snapshotID.uuidString)-\(rows.count)"
            elements[id] = SnapshotElement(processIdentifier: processIdentifier, applicationBundleID: bundleID, element: element)
            rows.append(["element_id": id, "role": role, "title": String(title.prefix(240))])
        } else if role == kAXStaticTextRole, !title.isEmpty {
            rows.append(["role": role, "title": String(title.prefix(240)), "kind": "static_text"])
        }
        guard let children = arrayAttribute(kAXChildrenAttribute, from: element) else { return }
        for child in children where rows.count < 80 && visited < 240 && Date() < deadline {
            collect(from: child, processIdentifier: processIdentifier, bundleID: bundleID, rows: &rows, visited: &visited, depth: depth + 1, deadline: deadline)
        }
    }

    private func isActionable(_ element: AXUIElement, role: String) -> Bool {
        if isSecure(element) { return false }
        if [kAXButtonRole, kAXMenuItemRole, kAXTextFieldRole, kAXTextAreaRole].contains(role) { return true }
        var actions: CFArray?
        return AXUIElementCopyActionNames(element, &actions) == .success && !(actions as? [String] ?? []).isEmpty
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        stringAttribute(kAXSubroleAttribute, from: element) == kAXSecureTextFieldSubrole
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func arrayAttribute(_ attribute: String, from element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    private func arguments(from value: AgentJSONValue) -> (action: String, bundleID: String, elementID: String?, text: String?)? {
        guard case let .object(object) = value,
              case let .string(action)? = object["action"],
              case let .string(bundleID)? = object["app_bundle_id"] else { return nil }
        let elementID: String?
        if case let .string(value)? = object["element_id"] { elementID = value } else { elementID = nil }
        let text: String?
        if case let .string(value)? = object["text"] { text = value } else { text = nil }
        return (action, bundleID, elementID, text)
    }
}
