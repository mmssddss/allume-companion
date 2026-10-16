import AppKit
import ApplicationServices

/// Debug helper: dump Allume's accessibility tree into the log (`ALLUME_AXDUMP=1` + SIGUSR2).
/// Every node is printed with role, title/value, frame, focus/selection state and the names of
/// any non-standard attributes, so one can see what the tree exposes beyond card titles.
enum AXDump {
    static func attr(_ el: AXUIElement, _ name: String) -> Any? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }

    static func attrNames(_ el: AXUIElement) -> [String] {
        var arr: CFArray?
        AXUIElementCopyAttributeNames(el, &arr)
        return (arr as? [String]) ?? []
    }

    private static func geometry(_ el: AXUIElement, _ name: String) -> String {
        guard let v = attr(el, name) else { return "-" }
        let ax = v as! AXValue
        var p = CGPoint.zero, s = CGSize.zero
        switch AXValueGetType(ax) {
        case .cgPoint: AXValueGetValue(ax, .cgPoint, &p); return "\(Int(p.x)),\(Int(p.y))"
        case .cgSize: AXValueGetValue(ax, .cgSize, &s); return "\(Int(s.width))×\(Int(s.height))"
        default: return "?"
        }
    }

    private static let standard: Set<String> = [
        "AXRole", "AXSubrole", "AXRoleDescription", "AXTitle", "AXValue", "AXDescription", "AXIdentifier", "AXHelp",
        "AXChildren", "AXParent", "AXWindow", "AXTopLevelUIElement", "AXPosition", "AXSize", "AXFrame",
        "AXEnabled", "AXFocused", "AXSelected", "AXChildrenInNavigationOrder", "AXCustomContent", "AXLanguage",
        "AXActivationPoint", "AXCustomRotors",
    ]

    static func dump(pid: pid_t) {
        let appEl = AXUIElementCreateApplication(pid)
        Log.info("axdump: app attrs \(attrNames(appEl))")
        if let f = attr(appEl, kAXFocusedUIElementAttribute) {
            let fe = f as! AXUIElement
            Log.info("axdump: FOCUSED \(describe(fe))")
        }
        let wins = attr(appEl, kAXWindowsAttribute) as? [AXUIElement] ?? []
        Log.info("axdump: \(wins.count) windows")
        var count = 0
        func walk(_ el: AXUIElement, _ depth: Int) {
            if depth > 30 || count > 2000 { return }
            count += 1
            Log.info(String(repeating: "  ", count: depth) + describe(el))
            for c in attr(el, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(c, depth + 1) }
        }
        for w in wins { walk(w, 0) }
        Log.info("axdump: \(count) nodes")
    }

    private static func describe(_ el: AXUIElement) -> String {
        let role = attr(el, kAXRoleAttribute) as? String ?? "?"
        let sub = attr(el, kAXSubroleAttribute) as? String ?? ""
        let title = attr(el, kAXTitleAttribute) as? String ?? ""
        let value = attr(el, kAXValueAttribute).map { "\($0)" }?.replacingOccurrences(of: "\n", with: "⏎") ?? ""
        let desc = attr(el, kAXDescriptionAttribute) as? String ?? ""
        let ident = attr(el, kAXIdentifierAttribute) as? String ?? ""
        let focused = attr(el, kAXFocusedAttribute).map { "\($0)" } ?? "-"
        let selected = attr(el, kAXSelectedAttribute).map { "\($0)" } ?? "-"
        let kids = (attr(el, kAXChildrenAttribute) as? [AXUIElement])?.count ?? 0
        let extra = attrNames(el).filter { !standard.contains($0) }
        var s = "\(role)\(sub.isEmpty ? "" : "/\(sub)")"
        if !title.isEmpty { s += " t=\"\(title.prefix(40))\"" }
        if !value.isEmpty { s += " v=\"\(value.prefix(50))\"" }
        if !desc.isEmpty { s += " d=\"\(desc.prefix(30))\"" }
        if !ident.isEmpty { s += " id=\(ident)" }
        s += " @\(geometry(el, kAXPositionAttribute)) \(geometry(el, kAXSizeAttribute)) foc=\(focused) sel=\(selected) kids=\(kids)"
        if !extra.isEmpty { s += " extra=\(extra)" }
        if extra.contains("AXSelectedChildren") {
            var v: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(el, "AXSelectedChildren" as CFString, &v)
            s += " selChildrenErr=\(err.rawValue)"
            var actions: CFArray?
            AXUIElementCopyActionNames(el, &actions)
            s += " actions=\((actions as? [String]) ?? [])"
        }
        for name in ["AXDocument", "AXSelectedChildren", "AXSections", "AXLinkedUIElements", "AXCustomActions", "AXUserInputLabels", "AXVisibleCharacterRange", "AXSelectedTextRange", "AXNumberOfCharacters"] where extra.contains(name) {
            if let v = attr(el, name) {
                if let arr = v as? [AXUIElement] { s += " \(name)=[\(arr.count) el]" }
                else { s += " \(name)=\("\(v)".replacingOccurrences(of: "\n", with: "⏎").prefix(80))" }
            }
        }
        return s
    }
}
