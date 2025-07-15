#!/usr/bin/env swift
//
// Apple Books Page Content Extractor
// 
// This tool uses macOS Accessibility API to extract page content
// from the Apple Books application.
//
// Requirements:
// - macOS with Books app
// - Accessibility permissions for Terminal/iTerm
// - Books app open with a book displayed
//
// Output: JSON with page content to stdout
//

import Foundation
import ApplicationServices
import AppKit
import NaturalLanguage
import AVFoundation

// MARK: - Error Types

enum ExtractionError: LocalizedError {
    case booksNotRunning
    case noWindowsFound
    case noContentFound
    case accessibilityDenied
    case navigationFailed
    case audioGenerationFailed
    case fileWriteError(String)
    
    var errorDescription: String? {
        switch self {
        case .booksNotRunning:
            return "Books app is not running"
        case .noWindowsFound:
            return "No windows found for Books app. Make sure you have a book open in Books."
        case .noContentFound:
            return "Could not extract any page content"
        case .accessibilityDenied:
            return "Terminal lacks Accessibility permissions. Please grant access in System Preferences."
        case .navigationFailed:
            return "Failed to navigate to next page"
        case .audioGenerationFailed:
            return "Failed to generate audio file"
        case .fileWriteError(let path):
            return "Failed to write file to: \(path)"
        }
    }
}

// MARK: - Configuration

struct ExtractorConfiguration {
    let debugMode: Bool
    let speakMode: Bool
    let diagnosticMode: Bool
    let pagesToExtract: Int
    let pageTransitionDelay: TimeInterval
    let outputFile: String?
    let startTime: Date
    
    static func parse(from arguments: [String]) -> ExtractorConfiguration {
        let debugMode = arguments.contains("debug")
        let diagnosticMode = arguments.contains("--diagnostic")
        
        return ExtractorConfiguration(
            debugMode: debugMode || diagnosticMode,
            speakMode: arguments.contains("--speak"),
            diagnosticMode: diagnosticMode,
            pagesToExtract: parsePages(from: arguments) ?? 1,
            pageTransitionDelay: parseDelay(from: arguments) ?? 0.3,
            outputFile: parseOutput(from: arguments),
            startTime: Date()
        )
    }
    
    private static func parsePages(from arguments: [String]) -> Int? {
        guard let pagesIndex = arguments.firstIndex(of: "--pages"),
              pagesIndex + 1 < arguments.count,
              let pages = Int(arguments[pagesIndex + 1]),
              pages > 0 else { return nil }
        return pages
    }
    
    private static func parseDelay(from arguments: [String]) -> TimeInterval? {
        guard let delayIndex = arguments.firstIndex(of: "--delay"),
              delayIndex + 1 < arguments.count,
              let delayMs = Int(arguments[delayIndex + 1]),
              delayMs > 0 else { return nil }
        return Double(delayMs) / 1000.0
    }
    
    private static func parseOutput(from arguments: [String]) -> String? {
        guard let outputIndex = arguments.firstIndex(of: "--output"),
              outputIndex + 1 < arguments.count else { return nil }
        return arguments[outputIndex + 1]
    }
}

// MARK: - Data Models

/// Represents a single chapter with its content
struct Chapter: Codable {
    let chapterTitle: String?
    let chapterContent: String
    let charactersCount: Int
    let wordCount: Int
    
    private enum CodingKeys: String, CodingKey {
        case chapterTitle = "chapter-title"
        case chapterContent = "chapter-content"
        case charactersCount = "chars_count"
        case wordCount = "word_count"
    }
}

/// Represents the complete extracted book content
struct BookContent: Codable {
    let title: String
    let totalCharactersCount: Int
    let totalWordCount: Int
    let extractionTimeMs: Int
    let language: String
    let content: [Chapter]
    
    private enum CodingKeys: String, CodingKey {
        case title
        case totalCharactersCount = "total_chars_count"
        case totalWordCount = "total_word_count"
        case extractionTimeMs = "extraction_time_ms"
        case language
        case content
    }
}

/// Represents extracted page content from Books (used internally)
struct PageContent {
    let title: String
    let content: String
    let wordsCount: Int
    let charactersCount: Int
    let extractionTimeMs: Int
    let language: String
    let chapterTitle: String?
}

// MARK: - Global Configuration

var globalConfig: ExtractorConfiguration!

// MARK: - Process Management

/// Find the process ID for Apple Books
/// - Returns: Result containing Process ID if found, error otherwise
func findBooksProcessID() -> Result<pid_t, ExtractionError> {
    let runningApps = NSWorkspace.shared.runningApplications
    
    // Try to find Books app by bundle identifier (most reliable)
    if let app = runningApps.first(where: { 
        $0.bundleIdentifier == "com.apple.iBooksX" 
    }) {
        return .success(app.processIdentifier)
    }
    
    // Fallback: try by name
    if let app = runningApps.first(where: { 
        $0.localizedName == "Books" || $0.localizedName == "Apple Books" 
    }) {
        return .success(app.processIdentifier)
    }
    
    return .failure(.booksNotRunning)
}

/// Check if the current process has accessibility permissions
/// - Returns: true if permissions are granted, false otherwise
func checkAccessibilityPermissions() -> Bool {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    return AXIsProcessTrustedWithOptions(options as CFDictionary)
}

// MARK: - Accessibility API Extraction

/// Structure to hold extracted content with headings separated
struct ExtractedContent {
    var headings: [String] = []
    var texts: [String] = []
}

/// Diagnostic function to explore all accessibility attributes
func exploreAccessibilityAttributes(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 5) {
    guard depth < maxDepth else { return }
    
    let indent = String(repeating: "  ", count: depth)
    
    // Get element role
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    let roleStr = role as? String ?? "Unknown"
    
    logDebug("\(indent)[\(roleStr)]")
    
    // Get all attribute names
    var attributeNames: CFArray?
    let result = AXUIElementCopyAttributeNames(element, &attributeNames)
    
    if result == .success, let attributes = attributeNames as? [String] {
        logDebug("\(indent)  Available attributes: \(attributes.count)")
        
        // Explore each attribute
        for attribute in attributes.sorted() {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success {
                let valueStr: String
                if let str = value as? String {
                    valueStr = str.prefix(100) + (str.count > 100 ? "..." : "")
                } else if let num = value as? NSNumber {
                    valueStr = num.description
                } else if let arr = value as? [Any] {
                    valueStr = "Array[\(arr.count) items]"
                } else if value != nil {
                    valueStr = "[\(type(of: value!))]"
                } else {
                    valueStr = "nil"
                }
                
                // Only print non-empty values
                if !valueStr.isEmpty && valueStr != "nil" {
                    logDebug("\(indent)    \(attribute): \(valueStr)")
                }
            }
        }
    }
    
    // Also try some common attributes that might not be in the list
    let additionalAttributes = [
        "AXIdentifier",
        "AXLabel", 
        "AXHelp",
        "AXRoleDescription",
        "AXSubrole",
        "AXTitle",
        "AXDescription",
        "AXValue",
        "AXURL",
        "AXFilename",
        "AXSelected",
        "AXEnabled",
        "AXFocused",
        "AXParent",
        "AXTopLevelUIElement",
        "AXPosition",
        "AXSize",
        "AXChildren"
    ]
    
    logDebug("\(indent)  Checking additional attributes:")
    for attr in additionalAttributes {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success {
            if let str = value as? String, !str.isEmpty {
                logDebug("\(indent)    \(attr): \(str.prefix(100))")
            }
        }
    }
    
    // If not too deep, explore children
    if depth < maxDepth - 1 {
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
           let childArray = children as? [AXUIElement] {
            logDebug("\(indent)  Children: \(childArray.count)")
            
            // Limit children exploration to avoid too much output
            let maxChildren = globalConfig.diagnosticMode ? 10 : 5
            for (index, child) in childArray.prefix(maxChildren).enumerated() {
                logDebug("\(indent)  Child \(index):")
                exploreAccessibilityAttributes(child, depth: depth + 1, maxDepth: maxDepth)
            }
            
            if childArray.count > maxChildren {
                logDebug("\(indent)  ... and \(childArray.count - maxChildren) more children")
            }
        }
    }
}

/// Extract structured content from a UI element recursively
/// 
/// This function traverses the accessibility tree to extract text content,
/// distinguishing between headings and regular text. It handles:
/// - AXHeading elements as chapter/section titles
/// - AXStaticText, AXTextField, and AXTextArea as regular content
/// - Recursive traversal of child elements
///
/// - Parameters:
///   - element: The AXUIElement to extract content from
///   - depth: Current recursion depth to prevent infinite loops
///   - maxDepth: Maximum recursion depth (default: 15)
/// - Returns: ExtractedContent with headings and texts separated
func extractStructuredContent(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 15) -> ExtractedContent {
    var content = ExtractedContent()
    
    // Prevent infinite recursion
    guard depth < maxDepth else { return content }
    
    // Get element role
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    let roleStr = role as? String ?? ""
    
    // Debug: Print element info
    if globalConfig.debugMode && depth < 5 {
        let indent = String(repeating: "  ", count: depth)
        logDebug("\(indent)[\(roleStr)]")
    }
    
    // Check if this is a heading
    if roleStr == "AXHeading" {
        if globalConfig.debugMode {
            let indent = String(repeating: "  ", count: depth)
            logDebug("\(indent)  -> Found heading element")
        }
        
        // Try to get value directly from heading
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
           let valueStr = value as? String, !valueStr.isEmpty {
            content.headings.append(valueStr)
            if globalConfig.debugMode {
                let indent = String(repeating: "  ", count: depth)
                logDebug("\(indent)  -> Heading value: \(valueStr)")
            }
        }
        
        // Try title attribute
        var title: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success,
           let titleStr = title as? String, !titleStr.isEmpty {
            if !content.headings.contains(titleStr) {
                content.headings.append(titleStr)
                if globalConfig.debugMode {
                    let indent = String(repeating: "  ", count: depth)
                    logDebug("\(indent)  -> Heading title: \(titleStr)")
                }
            }
        }
        
        // Extract heading text from children
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
           let childArray = children as? [AXUIElement] {
            for child in childArray {
                let childTexts = extractTextFromElement(child, depth: depth + 1, maxDepth: maxDepth)
                content.headings.append(contentsOf: childTexts)
            }
        }
    } else if roleStr == "AXStaticText" || roleStr == "AXTextField" || roleStr == "AXTextArea" {
        // Extract regular text
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
           let valueStr = value as? String, !valueStr.isEmpty {
            content.texts.append(valueStr)
            if globalConfig.debugMode && depth < 5 {
                let indent = String(repeating: "  ", count: depth)
                logDebug("\(indent)  -> Value: \(valueStr.prefix(50))...")
            }
        }
    } else {
        // For other elements, recursively process children
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
           let childArray = children as? [AXUIElement] {
            for child in childArray {
                let childContent = extractStructuredContent(child, depth: depth + 1, maxDepth: maxDepth)
                content.headings.append(contentsOf: childContent.headings)
                content.texts.append(contentsOf: childContent.texts)
            }
        }
    }
    
    return content
}

/// Extract all text content from a UI element recursively
/// - Parameters:
///   - element: The AXUIElement to extract text from
///   - depth: Current recursion depth
///   - maxDepth: Maximum recursion depth
/// - Returns: Array of extracted text strings
func extractTextFromElement(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 15) -> [String] {
    var texts: [String] = []
    
    // Prevent infinite recursion
    guard depth < maxDepth else { return texts }
    
    // Get element role
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
    let roleStr = role as? String ?? ""
    
    // Debug: Print element info
    if globalConfig.debugMode && depth < 5 {  // Only print first few levels to avoid spam
        let indent = String(repeating: "  ", count: depth)
        logDebug("\(indent)[\(roleStr)]")
    }
    
    // Extract text based on role
    if roleStr == "AXStaticText" || roleStr == "AXTextField" || roleStr == "AXTextArea" {
        // Try value attribute first
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
           let valueStr = value as? String, !valueStr.isEmpty {
            texts.append(valueStr)
            if globalConfig.debugMode && depth < 5 {
                let indent = String(repeating: "  ", count: depth)
                logDebug("\(indent)  -> Value: \(valueStr.prefix(50))...")
            }
        }
        
        // Try description attribute
        var desc: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &desc) == .success,
           let descStr = desc as? String, !descStr.isEmpty {
            // Only add if different from value
            if !texts.contains(descStr) {
                texts.append(descStr)
            }
        }
    }
    
    // For other elements, check title
    var title: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success,
       let titleStr = title as? String, !titleStr.isEmpty {
        if !texts.contains(titleStr) && !titleStr.hasPrefix("AXURL") {
            texts.append(titleStr)
        }
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

/// Searches the accessibility hierarchy for the main content area of Books app.
/// 
/// The Books app typically structures its content in either:
/// - AXScrollArea: For standard EPUB books
/// - AXWebArea: For PDF or web-based content
/// - AXGroup with AXDocumentContent subrole: For special layouts
///
/// - Parameter window: The main Books window to search within
/// - Returns: The content area element if found, nil otherwise
func findBooksContentArea(_ window: AXUIElement) -> AXUIElement? {
    var contentArea: AXUIElement?
    
    func searchForContentArea(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 10 else { return nil }
        
        // Get role
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let roleStr = role as? String ?? ""
        
        // Get subrole
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        let subroleStr = subrole as? String ?? ""
        
        // Look for scroll areas or groups that might contain book content
        if roleStr == "AXScrollArea" || 
           (roleStr == "AXGroup" && subroleStr == "AXDocumentContent") ||
           roleStr == "AXWebArea" {
            
            // Check if this element has substantial text content
            let texts = extractTextFromElement(element, maxDepth: 3)
            if texts.joined(separator: " ").count > 100 {
                return element
            }
        }
        
        // Search children
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
           let childArray = children as? [AXUIElement] {
            for child in childArray {
                if let found = searchForContentArea(child, depth: depth + 1) {
                    return found
                }
            }
        }
        
        return nil
    }
    
    contentArea = searchForContentArea(window)
    return contentArea
}

/// Extract page content from Books window
/// 
/// This function performs the main content extraction logic:
/// 1. Attempts to find the specific content area within the Books window
/// 2. Extracts structured content including headings and body text
/// 3. Processes chapter titles if present
/// 4. Calculates word and character counts
/// 5. Detects the language of the content
///
/// - Parameters:
///   - window: The Books window element
///   - extractionTime: The time taken for extraction in milliseconds
/// - Returns: PageContent if successful, nil if no content found
func extractPageContent(from window: AXUIElement, extractionTime: Int) -> PageContent? {
    // Get window title (might contain book name)
    var windowTitle: CFTypeRef?
    var bookTitle: String = "Unknown"
    if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &windowTitle) == .success,
       let titleStr = windowTitle as? String {
        bookTitle = titleStr
        logDebug("Window title: \(titleStr)")
    }
    
    // Find the main content area
    logDebug("\nSearching for book content area...")
    
    var structuredContent: ExtractedContent
    
    if let contentArea = findBooksContentArea(window) {
        logDebug("Found content area! Extracting structured content...")
        structuredContent = extractStructuredContent(contentArea)
    } else {
        logDebug("Could not find content area. Extracting from entire window...")
        // Fallback: extract from entire window
        structuredContent = extractStructuredContent(window)
    }
    
    if !structuredContent.texts.isEmpty {
        // Process chapter title (if any)
        var chapterTitle: String? = nil
        if !structuredContent.headings.isEmpty {
            // Take the first heading as chapter title
            chapterTitle = structuredContent.headings.first
            logDebug("Found chapter title: \(chapterTitle ?? "")")
        }
        
        // Join texts and clean up
        let pageText = structuredContent.texts
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        
        let wordsCount = wordCount(pageText)
        let charactersCount = characterCount(pageText)
        let language = detectLanguage(pageText)
        
        return PageContent(
            title: bookTitle,
            content: pageText,
            wordsCount: wordsCount,
            charactersCount: charactersCount,
            extractionTimeMs: extractionTime,
            language: language,
            chapterTitle: chapterTitle
        )
    }
    
    return nil
}

// MARK: - Navigation

/// Navigate to next page using AppleScript
/// 
/// Sends a right arrow key press to the Books app to navigate to the next page.
/// This approach is more reliable than trying to find and click UI buttons.
///
/// - Parameter window: The Books window element (currently unused but kept for future enhancements)
/// - Returns: true if the AppleScript executed successfully, false otherwise
func navigateToNextPage(_ window: AXUIElement) -> Bool {
    logDebug("Navigating to next page using AppleScript...")
    
    let script = """
    tell application "Books"
        activate
    end tell
    tell application "System Events"
        tell process "Books"
            key code 124
        end tell
    end tell
    """
    
    var error: NSDictionary?
    if let scriptObject = NSAppleScript(source: script) {
        scriptObject.executeAndReturnError(&error)
        if error != nil {
            logDebug("AppleScript error: \(error!)")
            return false
        } else {
            logDebug("Sent arrow right via AppleScript")
            return true
        }
    }
    
    logDebug("Failed to execute AppleScript")
    return false
}

// MARK: - Main Execution

/// Main entry point for the Books Page Content Extractor.
/// 
/// Execution flow:
/// 1. Parse command line arguments and create configuration
/// 2. Check accessibility permissions
/// 3. Find or launch Books app
/// 4. Access Books window and content
/// 5. Extract content from one or more pages
/// 6. Organize content by chapters
/// 7. Output as JSON or generate audio
///
/// Exit codes:
/// - 0: Success
/// - 1: Error (permissions, app not found, no content, etc.)
func main() {
    // Parse configuration from command line arguments
    globalConfig = ExtractorConfiguration.parse(from: CommandLine.arguments)
    
    // Setup
    if globalConfig.debugMode {
        logDebug("Apple Books Page Content Extractor")
        logDebug(String(repeating: "=", count: 50))
        logDebug("")
        if globalConfig.speakMode {
            logDebug("Speech mode enabled")
        }
        logDebug("Will extract \(globalConfig.pagesToExtract) page(s)")
        logDebug("Page transition delay: \(Int(globalConfig.pageTransitionDelay * 1000))ms")
        if let outputFile = globalConfig.outputFile {
            logDebug("Output will be saved to: \(outputFile)")
        }
    }
    
    // Check accessibility permissions first
    if !checkAccessibilityPermissions() {
        logError("Terminal lacks Accessibility permissions")
        logError("Please grant access in System Preferences → Security & Privacy → Privacy → Accessibility")
        exit(1)
    }
    
    // Check if Books is running
    let pidResult = findBooksProcessID()
    var pid: pid_t?
    
    switch pidResult {
    case .success(let processId):
        pid = processId
    case .failure:
        logDebug("⚠️  Books app is not running. Attempting to open it...")
        
        // Open Books app
        let workspace = NSWorkspace.shared
        let booksURL = URL(fileURLWithPath: "/System/Applications/Books.app")
        
        let opened = workspace.open(booksURL)
        
        if !opened {
            logDebug("❌ Failed to open Books app")
            exit(1)
        }
        
        logDebug("✅ Launching Books app...")
        
        // Wait for app to launch
        var attempts = 0
        while attempts < 20 {
            Thread.sleep(forTimeInterval: 0.5)
            switch findBooksProcessID() {
            case .success(let newPid):
                pid = newPid
                logDebug("✅ Books app launched successfully (PID: \(newPid))")
                Thread.sleep(forTimeInterval: 2.0)
                break
            case .failure:
                break
            }
            attempts += 1
        }
        
        if pid == nil {
            logDebug("❌ Failed to launch Books app after 10 seconds")
            exit(1)
        }
    }
    
    guard let finalPid = pid else {
        logDebug("❌ Unable to get Books process ID")
        exit(1)
    }
    
    logDebug("✅ Found Books app (PID: \(finalPid))")
    
    // Get Books application element
    let appElement = AXUIElementCreateApplication(finalPid)
    
    // Get all windows
    var windows: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windows) == .success,
          let windowArray = windows as? [AXUIElement],
          !windowArray.isEmpty else {
        logDebug("❌ No windows found for Books app")
        logDebug("Make sure you have a book open in Books.")
        exit(1)
    }
    
    logDebug("📚 Found \(windowArray.count) window(s)")
    logDebug("")
    
    // Process the first window (main book window)
    guard let mainWindow = windowArray.first else {
        logDebug("❌ No windows found")
        exit(1)
    }
    
    // If diagnostic mode, explore accessibility tree and exit
    if globalConfig.diagnosticMode {
        logDebug("🔍 DIAGNOSTIC MODE: Exploring accessibility attributes")
        logDebug(String(repeating: "=", count: 60))
        logDebug("\nWindow-level attributes:")
        exploreAccessibilityAttributes(mainWindow, maxDepth: 4)
        
        logDebug("\n\nSearching for content area...")
        if let contentArea = findBooksContentArea(mainWindow) {
            logDebug("\n✅ Found content area! Exploring its attributes:")
            logDebug(String(repeating: "-", count: 60))
            exploreAccessibilityAttributes(contentArea, maxDepth: 3)
        } else {
            logDebug("\n❌ Could not find specific content area")
        }
        
        logDebug("\n\nApplication-level attributes:")
        logDebug(String(repeating: "-", count: 60))
        exploreAccessibilityAttributes(appElement, maxDepth: 2)
        
        logDebug("\n🔍 Diagnostic exploration complete")
        exit(0)
    }
    
    // Variables to collect content from all pages
    var chapters: [Chapter] = []
    var currentChapterTitle: String? = nil
    var currentChapterContent: [String] = []
    var bookTitle = "Unknown"
    var totalWords = 0
    var totalChars = 0
    var detectedLanguage = "unknown"
    var previousPageContent: String? = nil
    var duplicateCount = 0
    
    // Extract content from multiple pages
    for pageNumber in 1...globalConfig.pagesToExtract {
        logDebug("Extracting page \(pageNumber) of \(globalConfig.pagesToExtract)...")
        
        // Calculate elapsed time since start
        let elapsedTime = Int(Date().timeIntervalSince(globalConfig.startTime) * 1000)
        
        if let pageContent = extractPageContent(from: mainWindow, extractionTime: elapsedTime) {
            // Check for duplicate content
            if pageContent.content == previousPageContent {
                duplicateCount += 1
                logDebug("⚠️  Duplicate content detected (occurrence #\(duplicateCount)/10)")
                
                // If we get 10 consecutive duplicate pages, stop extraction
                if duplicateCount >= 10 {
                    logDebug("🛑 Stopping extraction: 10 consecutive duplicate pages detected")
                    logDebug("   (Likely reached end of book or navigation failure)")
                    break
                }
                
                // Continue with navigation for empty pages or temporary issues
                logDebug("   Continuing extraction (may be empty page)...")
            } else {
                // Reset duplicate count if we get new content
                duplicateCount = 0
            }
            
            // Store current content for next comparison
            previousPageContent = pageContent.content
            
            // Update metadata from first page
            if pageNumber == 1 {
                bookTitle = pageContent.title
                detectedLanguage = pageContent.language
                currentChapterTitle = pageContent.chapterTitle
            }
            
            // Check if we've entered a new chapter
            if pageContent.chapterTitle != nil && pageContent.chapterTitle != currentChapterTitle {
                // Save the previous chapter if it has content
                if !currentChapterContent.isEmpty {
                    let chapterText = currentChapterContent.joined(separator: "\n\n")
                    let titleText = currentChapterTitle ?? ""
                    let combinedText = titleText + " " + chapterText
                    chapters.append(Chapter(
                        chapterTitle: currentChapterTitle,
                        chapterContent: chapterText,
                        charactersCount: characterCount(combinedText),
                        wordCount: wordCount(combinedText)
                    ))
                    currentChapterContent = []
                }
                currentChapterTitle = pageContent.chapterTitle
                logDebug("📖 New chapter detected: \(currentChapterTitle ?? "Untitled")")
            }
            
            // Add page content to current chapter
            currentChapterContent.append(pageContent.content)
            
            // Accumulate stats
            totalWords += pageContent.wordsCount
            totalChars += pageContent.charactersCount
            
            if globalConfig.debugMode {
                logDebug("✅ Extracted page \(pageNumber): \(pageContent.wordsCount) words")
                if let chapterTitle = pageContent.chapterTitle {
                    logDebug("   Chapter: \(chapterTitle)")
                }
            }
            
            // Navigate to next page if not the last page
            if pageNumber < globalConfig.pagesToExtract {
                let navSuccess = navigateToNextPage(mainWindow)
                if !navSuccess {
                    logDebug("Warning: Navigation might have failed")
                }
                // Wait for page transition
                Thread.sleep(forTimeInterval: globalConfig.pageTransitionDelay)
            }
        } else {
            logDebug("❌ Failed to extract page \(pageNumber)")
            break
        }
    }
    
    // Don't forget to add the last chapter
    if !currentChapterContent.isEmpty {
        let chapterText = currentChapterContent.joined(separator: "\n\n")
        let titleText = currentChapterTitle ?? ""
        let combinedText = titleText + " " + chapterText
        chapters.append(Chapter(
            chapterTitle: currentChapterTitle,
            chapterContent: chapterText,
            charactersCount: characterCount(combinedText),
            wordCount: wordCount(combinedText)
        ))
    }
    
    // Check if we extracted any content
    if chapters.isEmpty {
        logDebug("\n❌ Could not extract any page content.")
        logDebug("Make sure:")
        logDebug("  1. You have a book open in Books")
        logDebug("  2. The book content is visible on screen")
        logDebug("  3. Terminal has Accessibility permissions")
        exit(1)
    }
    
    let totalElapsedTime = Int(Date().timeIntervalSince(globalConfig.startTime) * 1000)
    
    if globalConfig.debugMode {
        logDebug("\n✅ Successfully extracted \(chapters.count) chapter(s)!")
        logDebug(String(repeating: "-", count: 50))
        logDebug("Total words: \(totalWords)")
        logDebug("Total characters: \(totalChars)")
        logDebug("Language: \(detectedLanguage)")
        logDebug("Total processing time: \(totalElapsedTime) ms")
        logDebug(String(repeating: "-", count: 50))
    }
    
    // Create BookContent object
    let bookContent = BookContent(
        title: bookTitle,
        totalCharactersCount: totalChars,
        totalWordCount: totalWords,
        extractionTimeMs: totalElapsedTime,
        language: detectedLanguage,
        content: chapters
    )
    
    // Output JSON using Codable
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    
    do {
        let jsonData = try encoder.encode(bookContent)
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            if let outputPath = globalConfig.outputFile {
                // Write to file
                let fileURL = URL(fileURLWithPath: outputPath)
                try jsonString.write(to: fileURL, atomically: true, encoding: .utf8)
                logDebug("✅ JSON saved to: \(outputPath)")
                print("Successfully saved to: \(outputPath)")
            } else {
                // Print to stdout
                print(jsonString)
            }
        }
    } catch {
        logDebug("Error encoding/saving JSON: \(error)")
        exit(1)
    }
    
    // Speak the content if requested
    if globalConfig.speakMode {
        let allContent = chapters.map { $0.chapterContent }.joined(separator: "\n\n")
        do {
            try speakText(allContent, language: detectedLanguage, title: bookTitle)
        } catch {
            logError("Speech generation failed: \(error.localizedDescription)")
        }
    }
    
    exit(0)
}

// MARK: - Utilities

/// Log debug information to stderr
func logDebug(_ message: String) {
    if globalConfig.debugMode {
        fputs(message + "\n", stderr)
    }
}

/// Log error information to stderr
func logError(_ message: String) {
    fputs("❌ " + message + "\n", stderr)
}

/// Calculate word count for a text efficiently
func wordCount(_ text: String) -> Int {
    var count = 0
    var inWord = false
    
    for character in text {
        if character.isWhitespace || character.isNewline {
            if inWord {
                count += 1
                inWord = false
            }
        } else {
            inWord = true
        }
    }
    
    if inWord { count += 1 }
    return count
}

/// Calculate character count for a text
func characterCount(_ text: String) -> Int {
    return text.count
}

// Note: escapeJSON function removed - using Codable for JSON encoding

/// Detect language of text using NaturalLanguage framework
func detectLanguage(_ text: String) -> String {
    // Use NLLanguageRecognizer to detect the dominant language
    if let language = NLLanguageRecognizer.dominantLanguage(for: text) {
        // Return ISO 639-1 code (2-letter code) if available, otherwise use the raw identifier
        return language.rawValue
    }
    
    // Fallback if language detection fails
    return "unknown"
}

/// Find the best available voice for a language, preferring Siri voices
func findBestVoice(for language: String) -> AVSpeechSynthesisVoice? {
    let allVoices = AVSpeechSynthesisVoice.speechVoices()
    let languageVoices = allVoices.filter { $0.language.hasPrefix(language) }
    
    // First, try to find a Siri voice (premium quality)
    if #available(macOS 13.0, *) {
        if let siriVoice = languageVoices.first(where: { $0.quality == .premium || $0.name.contains("Siri") }) {
            logDebug("Found Siri voice: \(siriVoice.name) for language: \(language)")
            return siriVoice
        }
    } else {
        // For older macOS versions, just check for Siri in name
        if let siriVoice = languageVoices.first(where: { $0.name.contains("Siri") }) {
            logDebug("Found Siri voice: \(siriVoice.name) for language: \(language)")
            return siriVoice
        }
    }
    
    // Then try enhanced quality
    if let enhancedVoice = languageVoices.first(where: { $0.quality == .enhanced }) {
        logDebug("Found enhanced voice: \(enhancedVoice.name) for language: \(language)")
        return enhancedVoice
    }
    
    // Finally, use any available voice for the language
    if let defaultVoice = languageVoices.first {
        logDebug("Using default voice: \(defaultVoice.name) for language: \(language)")
        return defaultVoice
    }
    
    // Fallback to system default
    return AVSpeechSynthesisVoice(language: language)
}

/// Generate speech audio file using the 'say' command securely
func speakText(_ text: String, language: String, title: String? = nil) throws {
    // Create the full text to speak
    var fullText = ""
    if let title = title {
        fullText = "Title: \(title). "
    }
    fullText += text
    
    // Create output file path
    let outputPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("books_audio.aiff")
    logDebug("Saving speech to: \(outputPath.path)")
    
    // Find the best voice for the language
    var voiceName: String? = nil
    if let voice = findBestVoice(for: language) {
        // Extract just the voice name from the identifier
        if let lastComponent = voice.identifier.split(separator: ".").last {
            voiceName = String(lastComponent)
        }
    }
    
    // Save text to temporary file with UUID to avoid conflicts
    let tempPath = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + "_books_text.txt")
    
    defer {
        // Always clean up temp file
        try? FileManager.default.removeItem(at: tempPath)
    }
    
    do {
        try fullText.write(to: tempPath, atomically: true, encoding: .utf8)
    } catch {
        throw ExtractionError.fileWriteError(tempPath.path)
    }
    
    // Use Process API without shell to avoid injection vulnerabilities
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    task.arguments = ["-f", tempPath.path, "-o", outputPath.path]
    
    if let voiceName = voiceName {
        task.arguments?.append(contentsOf: ["-v", voiceName])
        logDebug("Using voice: \(voiceName)")
    }
    
    let pipe = Pipe()
    task.standardError = pipe
    
    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        throw ExtractionError.audioGenerationFailed
    }
    
    if task.terminationStatus == 0 {
        logDebug("✅ Audio saved successfully to: \(outputPath.path)")
        
        // Get file size
        if let attributes = try? FileManager.default.attributesOfItem(atPath: outputPath.path),
           let fileSize = attributes[.size] as? Int64 {
            let sizeInMB = Double(fileSize) / (1024 * 1024)
            logDebug("Audio file size: \(String(format: "%.2f", sizeInMB)) MB")
        }
    } else {
        let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
        if let errorString = String(data: errorData, encoding: .utf8) {
            logError("Failed to generate audio: \(errorString)")
        }
        throw ExtractionError.audioGenerationFailed
    }
}

// Run the main function
main()