import AppKit
import ApplicationServices

/// Debug helper: dump titled/valued elements of Allume's windows into the log.
enum AXDump {
    static func attr(_ el: AXUIElement, _ name: String) -> Any? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, name as CFString, &v)
        return v
    }

    static func dump(pid: pid_t) {
        let appEl = AXUIElementCreateApplication(pid)
        let wins = attr(appEl, kAXWindowsAttribute) as? [AXUIElement] ?? []
        Log.info("axdump: \(wins.count) windows")
        for w in wins {
            Log.info("window title=\(attr(w, kAXTitleAttribute) ?? "nil") doc=\(attr(w, kAXDocumentAttribute) ?? "nil") subrole=\(attr(w, kAXSubroleAttribute) ?? "nil")")
        }
        var found = 0
        func walk(_ el: AXUIElement, _ depth: Int) {
            if depth > 14 || found > 80 { return }
            let role = attr(el, kAXRoleAttribute) as? String ?? "?"
            let title = attr(el, kAXTitleAttribute) as? String ?? ""
            let value = attr(el, kAXValueAttribute).map { "\($0)" } ?? ""
            let desc = attr(el, kAXDescriptionAttribute) as? String ?? ""
            let ident = attr(el, kAXIdentifierAttribute) as? String ?? ""
            if !title.isEmpty || (!value.isEmpty && value.count < 80) || !ident.isEmpty || !desc.isEmpty {
                Log.info(String(repeating: "  ", count: depth) + "\(role) title=\(title) value=\(value.prefix(60)) desc=\(desc) id=\(ident)")
                found += 1
            }
            for c in attr(el, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(c, depth + 1) }
        }
        if let w = wins.first { walk(w, 0) }
    }
}
