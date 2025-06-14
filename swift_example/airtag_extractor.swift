#!/usr/bin/env swift
//
// AirTag Location Extractor
// 
// This tool uses macOS Accessibility API to extract AirTag location data
// directly from the Find My app window, eliminating the need for screenshots.
//
// Requirements:
// - macOS with Find My app
// - Accessibility permissions for Terminal/iTerm
// - Find My app open with "Items" tab selected
//
// Output: JSON array of device locations to stdout

import Foundation
import ApplicationServices
import AppKit

// MARK: - Data Models

/// Represents an AirTag or Find My device with its location information
struct AirTagDevice: Codable {
    let name: String
    let location: String
    let timeStatus: String  // e.g., "Now", "5 min ago", "Paused"
    let distance: String    // e.g., "0 km", "1.5 km", "-"
    let rawText: String     // Original text for debugging
    let extractedAt: Date
    
    var description: String {
        return """
        Device: \(name)
          Location: \(location)
          Status: \(timeStatus)
          Distance: \(distance)
        """
    }
}

// MARK: - Process Management

/// Find the process ID for a given application name
/// - Parameter appName: The name of the application (e.g., "Find My")
/// - Returns: Process ID if found, nil otherwise
func getProcessID(forAppName appName: String) -> pid_t? {
    let runningApps = NSWorkspace.shared.runningApplications
    
    // Try exact match first
    if let app = runningApps.first(where: { $0.localizedName == appName }) {
        return app.processIdentifier
    }
    
    // Try bundle identifier match (more reliable)
    if let app = runningApps.first(where: { 
        $0.bundleIdentifier?.lowercased().contains(appName.lowercased()) == true 
    }) {
        return app.processIdentifier
    }
    
    return nil
}

// MARK: - Device Information Parsing

/// Parse device information from Find My text format
/// - Parameter text: Raw text from Find My UI element
/// - Returns: Parsed AirTagDevice if format matches, nil otherwise
func parseDeviceInfo(from text: String) -> AirTagDevice? {
    // Known patterns:
    // 1. "Device Name, Location, Time, Distance" - e.g. "Auto, François Laurentplein, Ghent , 10 min ago, 0,7 km"
    // 2. "Device Name, Location, Time, Distance" - e.g. "Black Valize, Home , 4 min ago, 0 km"
    // 3. "Device Name, Location, Status, Distance" - e.g. "Black Valize, Home , Now, 0 km"
    // 4. "Device Name, Location, Status, Distance" - e.g. "Black Valize, Home , Paused, 0 km"
    // 5. "Device Name, Status" - e.g. "Backpack, Paused" (no location)
    // 6. "Device Name, No location found"
    
    // Clean up the text and split by comma
    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let components = trimmedText.split(separator: ",").map { 
        $0.trimmingCharacters(in: .whitespaces) 
    }
    
    // Need at least device name and one other component
    guard components.count >= 2 else { return nil }
    
    let deviceName = components[0]
    
    // Case 1: Device with no location (2 components)
    if components.count == 2 {
        let status = components[1]
        if status == "Paused" || status == "No location found" {
            return AirTagDevice(
                name: deviceName,
                location: "No location found",
                timeStatus: status,
                distance: "-",
                rawText: trimmedText,
                extractedAt: Date()
            )
        }
    }
    
    // Case 2: Device with full location info (4+ components)
    if components.count >= 4 {
        // Last component should be distance
        let distance = components[components.count - 1]
        
        // Second to last should be time/status
        let timeStatus = components[components.count - 2]
        
        // Everything between device name and status is location
        // Handle multi-part locations (e.g., "Street, City")
        let locationParts = components[1..<components.count - 2]
        let location = locationParts.joined(separator: ", ")
        
        // Check for special case: decimal distances like "0,7 km" 
        // These get split incorrectly because of the comma
        var actualDistance = distance
        var actualTimeStatus = timeStatus
        var actualLocation = location
        
        // If we have extra components and distance looks wrong, check for split decimal
        if components.count >= 5 && distance == "7 km" {
            // Check if previous component is "0"
            let possibleDecimalPart = components[components.count - 3]
            if possibleDecimalPart == "0" {
                // This is likely "0,7 km" that got split
                actualDistance = "0,7 km"
                actualTimeStatus = components[components.count - 4]
                // Recalculate location
                let locationParts = components[1..<components.count - 4]
                actualLocation = locationParts.joined(separator: ", ")
            }
        }
        
        // Validate that this looks like device info
        // Distance should contain "km" or "m" or be a number
        let looksLikeDistance = actualDistance.contains("km") || 
                               actualDistance.contains("m") || 
                               Double(actualDistance.replacingOccurrences(of: ",", with: ".")) != nil
        
        // Time status patterns: "Now", "Paused", "X min ago", "X hours ago", etc.
        let looksLikeTimeStatus = actualTimeStatus == "Now" || 
                                 actualTimeStatus == "Paused" ||
                                 actualTimeStatus.contains("ago") ||
                                 actualTimeStatus.contains("min") ||
                                 actualTimeStatus.contains("hour")
        
        if looksLikeDistance || looksLikeTimeStatus {
            return AirTagDevice(
                name: deviceName,
                location: actualLocation.isEmpty ? "Unknown" : actualLocation,
                timeStatus: actualTimeStatus,
                distance: actualDistance,
                rawText: trimmedText,
                extractedAt: Date()
            )
        }
    }
    
    return nil
}

// MARK: - Accessibility API Extraction

/// Extract AirTag devices from Find My window using Accessibility API
/// - Parameter element: The AXUIElement to search within
/// - Returns: Array of found AirTag devices
func extractAirTagDevices(from element: AXUIElement) -> [AirTagDevice] {
    var devices: [AirTagDevice] = []
    var processedTexts = Set<String>() // Avoid duplicates
    
    /// Recursively process UI elements
    func processElement(_ elem: AXUIElement, depth: Int = 0) {
        // Limit recursion depth to prevent infinite loops
        guard depth < 20 else { return }
        
        // Get element role
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &role)
        let roleStr = role as? String ?? ""
        
        // Look for static text elements (these contain device info)
        if roleStr == "AXStaticText" {
            // Try to get description (primary text source)
            var desc: CFTypeRef?
            if AXUIElementCopyAttributeValue(elem, kAXDescriptionAttribute as CFString, &desc) == .success,
               let descStr = desc as? String,
               !descStr.isEmpty {
                
                // Check if this looks like device info and hasn't been processed
                if descStr.contains(",") && !processedTexts.contains(descStr) {
                    processedTexts.insert(descStr)
                    
                    // Filter out UI elements that aren't devices
                    let isNotDevice = descStr.contains("Map pin") ||
                                     descStr.contains("My Location") ||
                                     descStr.hasPrefix("AXURL")
                    
                    if !isNotDevice, let device = parseDeviceInfo(from: descStr) {
                        devices.append(device)
                    }
                }
            }
            
            // Also check value attribute as fallback
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(elem, kAXValueAttribute as CFString, &value) == .success,
               let valueStr = value as? String,
               !valueStr.isEmpty && !processedTexts.contains(valueStr) {
                
                if valueStr.contains(","), let device = parseDeviceInfo(from: valueStr) {
                    processedTexts.insert(valueStr)
                    devices.append(device)
                }
            }
        }
        
        // Recursively process children
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(elem, kAXChildrenAttribute as CFString, &children) == .success,
           let childArray = children as? [AXUIElement] {
            for child in childArray {
                processElement(child, depth: depth + 1)
            }
        }
    }
    
    processElement(element)
    
    // Remove duplicates based on device name
    var uniqueDevices: [AirTagDevice] = []
    var seenNames = Set<String>()
    
    for device in devices {
        if !seenNames.contains(device.name) {
            seenNames.insert(device.name)
            uniqueDevices.append(device)
        }
    }
    
    return uniqueDevices
}

// MARK: - Main Execution

func main() {
    // Setup
    printToStderr("AirTag Location Extractor")
    printToStderr(String(repeating: "=", count: 50))
    printToStderr("")
    
    // Check if Find My is running
    var pid = getProcessID(forAppName: "Find My")
    
    if pid == nil {
        printToStderr("⚠️  Find My app is not running. Attempting to open it...")
        
        // Open Find My app
        let workspace = NSWorkspace.shared
        let findMyURL = URL(fileURLWithPath: "/System/Applications/FindMy.app")
        
        // Use NSWorkspace to open Find My
        let opened = workspace.open(findMyURL)
        
        if !opened {
            printToStderr("❌ Failed to open Find My app")
            print("[]")
            exit(1)
        }
        
        printToStderr("✅ Launching Find My app...")
        
        // Wait for app to launch (up to 10 seconds)
        var attempts = 0
        while attempts < 20 {
            Thread.sleep(forTimeInterval: 0.5)
            if let newPid = getProcessID(forAppName: "Find My") {
                pid = newPid
                printToStderr("✅ Find My app launched successfully (PID: \(newPid))")
                
                // Give it a bit more time to fully initialize
                Thread.sleep(forTimeInterval: 2.0)
                break
            }
            attempts += 1
        }
        
        if pid == nil {
            printToStderr("❌ Failed to launch Find My app after 10 seconds")
            print("[]")
            exit(1)
        }
    }
    
    guard let finalPid = pid else {
        printToStderr("❌ Unable to get Find My process ID")
        print("[]")
        exit(1)
    }
    
    printToStderr("✅ Found Find My app (PID: \(finalPid))")
    
    // Get Find My application element
    let appElement = AXUIElementCreateApplication(finalPid)
    
    // Get all windows
    var windows: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windows) == .success,
          let windowArray = windows as? [AXUIElement],
          !windowArray.isEmpty else {
        printToStderr("❌ No windows found for Find My app")
        print("[]")
        exit(1)
    }
    
    printToStderr("📍 Extracting AirTag locations from \(windowArray.count) window(s)...")
    printToStderr("")
    
    // Extract devices from all windows (usually just one)
    var allDevices: [AirTagDevice] = []
    for window in windowArray {
        let devices = extractAirTagDevices(from: window)
        allDevices.append(contentsOf: devices)
    }
    
    // Remove any remaining duplicates
    let uniqueDevices = Array(Set(allDevices.map { $0.name }))
        .compactMap { name in allDevices.first { $0.name == name } }
        .sorted { $0.name < $1.name } // Sort by name for consistency
    
    // Report findings to stderr
    if uniqueDevices.isEmpty {
        printToStderr("⚠️  No AirTag devices found.")
        printToStderr("Make sure the 'Items' tab is selected in Find My.")
    } else {
        printToStderr("Found \(uniqueDevices.count) device(s):")
        printToStderr("")
        
        for (index, device) in uniqueDevices.enumerated() {
            printToStderr("\(index + 1). \(device.description)")
            printToStderr("")
        }
    }
    
    // Output JSON to stdout for parsing
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    
    do {
        let jsonData = try encoder.encode(uniqueDevices)
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            print(jsonString) // This goes to stdout
        } else {
            print("[]")
        }
    } catch {
        printToStderr("❌ Failed to encode JSON: \(error)")
        print("[]")
        exit(1)
    }
}

// MARK: - Extensions

/// Simple stderr printing
func printToStderr(_ message: String) {
    fputs(message + "\n", stderr)
}

/// String extension for numeric checking
extension String {
    func isNumeric() -> Bool {
        return Double(self) != nil
    }
}

// Run the main function
main()