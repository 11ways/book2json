#!/usr/bin/env swift

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

func findDeviceInfo(_ element: AXUIElement, currentPath: String = "") {
    // Get role
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    let roleStr = role as? String ?? ""
    
    // Get all text attributes
    var desc: CFTypeRef?
    var value: CFTypeRef?
    var title: CFTypeRef?
    
    AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &desc)
    AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
    AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
    
    let descStr = desc as? String ?? ""
    let valueStr = value as? String ?? ""
    let titleStr = title as? String ?? ""
    
    // Check if this element or nearby elements contain device info
    let deviceNames = ["Black Valize", "Yellow Valize", "Auto", "Keys", "Backpack", "Dongle", "Fitness"]
    let allText = descStr + valueStr + titleStr
    
    for deviceName in deviceNames {
        if allText.contains(deviceName) && !allText.contains("Map pin") {
            print("\n🔍 Found '\(deviceName)' in \(roleStr)")
            print("   Path: \(currentPath)")
            print("   Description: \(descStr)")
            print("   Value: \(valueStr)")
            print("   Title: \(titleStr)")
            
            // Look for siblings/nearby elements
            if let parent = getParent(of: element) {
                print("   --- Checking siblings ---")
                checkSiblings(of: element, parent: parent)
            }
        }
    }
    
    // Recursively check children
    var children: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
       let childArray = children as? [AXUIElement] {
        for (index, child) in childArray.enumerated() {
            findDeviceInfo(child, currentPath: "\(currentPath)/\(roleStr)[\(index)]")
        }
    }
}

func getParent(of element: AXUIElement) -> AXUIElement? {
    var parent: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
       let parentElement = parent {
        return (parentElement as! AXUIElement)
    }
    return nil
}

func checkSiblings(of element: AXUIElement, parent: AXUIElement) {
    var children: CFTypeRef?
    if AXUIElementCopyAttributeValue(parent, kAXChildrenAttribute as CFString, &children) == .success,
       let childArray = children as? [AXUIElement] {
        
        for child in childArray {
            var role: CFTypeRef?
            var desc: CFTypeRef?
            var value: CFTypeRef?
            
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &desc)
            AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &value)
            
            let roleStr = role as? String ?? ""
            let descStr = desc as? String ?? ""
            let valueStr = value as? String ?? ""
            
            if !descStr.isEmpty || !valueStr.isEmpty {
                print("     Sibling [\(roleStr)] Desc: '\(descStr)' Value: '\(valueStr)'")
            }
        }
    }
}

// Main
print("Device Info Finder")
print("==================\n")

guard let pid = getProcessID(forAppName: "Find My") else {
    print("❌ Find My not running")
    exit(1)
}

let app = AXUIElementCreateApplication(pid)
var windows: CFTypeRef?

if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
   let windowArray = windows as? [AXUIElement], !windowArray.isEmpty {
    
    findDeviceInfo(windowArray[0])
    
} else {
    print("❌ No windows found")
}