import Foundation
import ApplicationServices

func getFrontmostAppPID() -> pid_t? {
    guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
    return frontApp.processIdentifier
}

func dumpAXTree(element: AXUIElement, depth: Int = 0) {
    let indent = String(repeating: "  ", count: depth)

    var role: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
       let roleStr = role as? String {
        print("\(indent)Role: \(roleStr)")
    }

    var title: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success,
       let titleStr = title as? String {
        print("\(indent)Title: \(titleStr)")
    }

    var children: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
       let childArray = children as? [AXUIElement] {
        for child in childArray {
            dumpAXTree(element: child, depth: depth + 1)
        }
    }
}

guard let pid = getFrontmostAppPID() else {
    print("Kon PID van voorgrondapplicatie niet ophalen.")
    exit(1)
}

let appElem = AXUIElementCreateApplication(pid)
var frontWindow: CFTypeRef?

if AXUIElementCopyAttributeValue(appElem, kAXFocusedWindowAttribute as CFString, &frontWindow) == .success,
   let windowElem = frontWindow as? AXUIElement {
    print("=== Accessibility Tree ===")
    dumpAXTree(element: windowElem)
} else {
    print("Kon het voorgrondvenster niet ophalen.")
}
