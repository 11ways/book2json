import Foundation
import ApplicationServices
import AppKit

struct LocationInfo {
    let deviceName: String
    let locationText: String
    let timestamp: String?
}

func getProcessID(forAppName appName: String) -> pid_t? {
    let runningApps = NSWorkspace.shared.runningApplications
    for app in runningApps {
        if app.localizedName == appName || app.bundleIdentifier?.contains(appName.lowercased()) == true {
            return app.processIdentifier
        }
    }
    return nil
}

func extractTextFromElement(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 10) -> [String] {
    var texts: [String] = []
    let indent = String(repeating: "  ", count: depth)
    
    if depth > maxDepth { return texts }
    
    // Get role
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    let roleStr = role as? String ?? ""
    
    // Get value (for text elements)
    var value: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
       let valueStr = value as? String, !valueStr.isEmpty {
        print("\(indent)[\(roleStr)] Value: \(valueStr)")
        texts.append(valueStr)
    }
    
    // Get title
    var title: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success,
       let titleStr = title as? String, !titleStr.isEmpty {
        print("\(indent)[\(roleStr)] Title: \(titleStr)")
        texts.append(titleStr)
    }
    
    // Get description
    var desc: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &desc) == .success,
       let descStr = desc as? String, !descStr.isEmpty {
        print("\(indent)[\(roleStr)] Description: \(descStr)")
        texts.append(descStr)
    }
    
    // Recursively process children
    var children: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
       let childArray = children as? [AXUIElement] {
        for child in childArray {
            texts.append(contentsOf: extractTextFromElement(child, depth: depth + 1, maxDepth: maxDepth))
        }
    }
    
    return texts
}

func findLocationGroups(_ element: AXUIElement, depth: Int = 0) -> [[String]] {
    var groups: [[String]] = []
    var currentGroup: [String] = []
    
    func processElement(_ elem: AXUIElement, _ depth: Int) {
        // Get role
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &role)
        let roleStr = role as? String ?? ""
        
        // Check if this is a group or similar container
        if roleStr == "AXGroup" || roleStr == "AXList" || roleStr == "AXRow" {
            if !currentGroup.isEmpty {
                groups.append(currentGroup)
                currentGroup = []
            }
        }
        
        // Extract text from this element
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(elem, kAXValueAttribute as CFString, &value) == .success,
           let valueStr = value as? String, !valueStr.isEmpty {
            currentGroup.append(valueStr)
        }
        
        var title: CFTypeRef?
        if AXUIElementCopyAttributeValue(elem, kAXTitleAttribute as CFString, &title) == .success,
           let titleStr = title as? String, !titleStr.isEmpty {
            currentGroup.append(titleStr)
        }
        
        // Process children
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &children) == .success,
           let childArray = children as? [AXUIElement] {
            for child in childArray {
                processElement(child, depth + 1)
            }
        }
    }
    
    processElement(element, depth)
    
    if !currentGroup.isEmpty {
        groups.append(currentGroup)
    }
    
    return groups
}

// Main execution
print("Looking for Find My app...")

guard let pid = getProcessID(forAppName: "Find My") else {
    print("Find My app is not running!")
    exit(1)
}

print("Found Find My with PID: \(pid)")

let appElement = AXUIElementCreateApplication(pid)

// Get all windows
var windows: CFTypeRef?
if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windows) == .success,
   let windowArray = windows as? [AXUIElement], !windowArray.isEmpty {
    
    print("\nFound \(windowArray.count) window(s)")
    
    for (index, window) in windowArray.enumerated() {
        print("\n=== Window \(index + 1) ===")
        
        // Get window title
        var windowTitle: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &windowTitle) == .success,
           let titleStr = windowTitle as? String {
            print("Window Title: \(titleStr)")
        }
        
        print("\nExtracting all text content:")
        print(String(repeating: "=", count: 50))
        
        let allTexts = extractTextFromElement(window)
        
        print("\n\nSummary of extracted texts:")
        print(String(repeating: "=", count: 50))
        for (i, text) in allTexts.enumerated() {
            print("\(i+1). \(text)")
        }
        
        print("\n\nLooking for location groups:")
        print(String(repeating: "=", count: 50))
        let groups = findLocationGroups(window)
        for (i, group) in groups.enumerated() {
            print("\nGroup \(i+1):")
            for text in group {
                print("  - \(text)")
            }
        }
    }
} else {
    print("No windows found for Find My app")
}