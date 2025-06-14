#!/usr/bin/env swift
//
// Debug script to examine Find My window structure
//

import Foundation
import ApplicationServices
import AppKit

func getProcessID(forAppName appName: String) -> pid_t? {
    let runningApps = NSWorkspace.shared.runningApplications
    if let app = runningApps.first(where: { $0.localizedName == appName }) {
        return app.processIdentifier
    }
    return nil
}

func debugElement(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 5) {
    guard depth < maxDepth else { return }
    
    let indent = String(repeating: "  ", count: depth)
    
    // Get role
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    let roleStr = role as? String ?? "Unknown"
    
    // Get various attributes
    var desc: CFTypeRef?
    var value: CFTypeRef?
    var title: CFTypeRef?
    
    AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &desc)
    AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
    AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
    
    let descStr = desc as? String
    let valueStr = value as? String
    let titleStr = title as? String
    
    // Print element info
    var info = "\(indent)[\(roleStr)]"
    if let title = titleStr, !title.isEmpty {
        info += " Title: '\(title)'"
    }
    if let desc = descStr, !desc.isEmpty {
        info += " Desc: '\(desc)'"
    }
    if let value = valueStr, !value.isEmpty {
        info += " Value: '\(value)'"
    }
    
    print(info)
    
    // Look for device-like patterns
    if roleStr == "AXStaticText" {
        if let text = descStr ?? valueStr {
            if text.contains(",") && !text.contains("Map pin") && !text.contains("My Location") {
                print("\(indent)  ⭐ POTENTIAL DEVICE: \(text)")
            }
        }
    }
    
    // Process children
    var children: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
       let childArray = children as? [AXUIElement] {
        for child in childArray {
            debugElement(child, depth: depth + 1, maxDepth: maxDepth)
        }
    }
}

// Main
print("Find My Debug Tool")
print("==================")

guard let pid = getProcessID(forAppName: "Find My") else {
    print("❌ Find My not running")
    exit(1)
}

print("✅ Found Find My (PID: \(pid))\n")

let app = AXUIElementCreateApplication(pid)
var windows: CFTypeRef?

if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
   let windowArray = windows as? [AXUIElement], !windowArray.isEmpty {
    
    print("Examining window structure (depth limited to 5):\n")
    debugElement(windowArray[0])
    
} else {
    print("❌ No windows found")
}