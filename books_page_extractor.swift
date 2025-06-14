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

// MARK: - Data Models

/// Represents a single chapter with its content
struct Chapter: Codable {
    let chapter_title: String?
    let chapter_content: String
    let chars_count: Int
    let word_count: Int
    
    private enum CodingKeys: String, CodingKey {
        case chapter_title = "chapter-title"
        case chapter_content = "chapter-content"
        case chars_count
        case word_count
    }
}

/// Represents the complete extracted book content
struct BookContent: Codable {
    let title: String
    let total_chars_count: Int
    let total_word_count: Int
    let extraction_time_ms: Int
    let language: String
    let content: [Chapter]
}

/// Represents extracted page content from Books (used internally)
struct PageContent {
    let title: String
    let content: String
    let words_count: Int
    let chars_count: Int
    let extraction_time_ms: Int
    let language: String
    let chapter_title: String?
}

// MARK: - Global variables

var debugMode = false
var speakMode = false
var diagnosticMode = false
var startTime = Date()
var pagesToExtract = 1
var pageTransitionDelay = 0.3 // Default 300ms
var outputFile: String? = nil

// MARK: - Process Management

/// Find the process ID for Apple Books
/// - Returns: Process ID if found, nil otherwise
func getBooksProcessID() -> pid_t? {
    let runningApps = NSWorkspace.shared.runningApplications
    
    // Try to find Books app by bundle identifier (most reliable)
    if let app = runningApps.first(where: { 
        $0.bundleIdentifier == "com.apple.iBooksX" 
    }) {
        return app.processIdentifier
    }
    
    // Fallback: try by name
    if let app = runningApps.first(where: { 
        $0.localizedName == "Books" || $0.localizedName == "Apple Books" 
    }) {
        return app.processIdentifier
    }
    
    return nil
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
    
    printDebug("\(indent)[\(roleStr)]")
    
    // Get all attribute names
    var attributeNames: CFArray?
    let result = AXUIElementCopyAttributeNames(element, &attributeNames)
    
    if result == .success, let attributes = attributeNames as? [String] {
        printDebug("\(indent)  Available attributes: \(attributes.count)")
        
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
                    printDebug("\(indent)    \(attribute): \(valueStr)")
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
    
    printDebug("\(indent)  Checking additional attributes:")
    for attr in additionalAttributes {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success {
            if let str = value as? String, !str.isEmpty {
                printDebug("\(indent)    \(attr): \(str.prefix(100))")
            }
        }
    }
    
    // If not too deep, explore children
    if depth < maxDepth - 1 {
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
           let childArray = children as? [AXUIElement] {
            printDebug("\(indent)  Children: \(childArray.count)")
            
            // Limit children exploration to avoid too much output
            let maxChildren = diagnosticMode ? 10 : 5
            for (index, child) in childArray.prefix(maxChildren).enumerated() {
                printDebug("\(indent)  Child \(index):")
                exploreAccessibilityAttributes(child, depth: depth + 1, maxDepth: maxDepth)
            }
            
            if childArray.count > maxChildren {
                printDebug("\(indent)  ... and \(childArray.count - maxChildren) more children")
            }
        }
    }
}

/// Extract structured content from a UI element recursively
/// - Parameters:
///   - element: The AXUIElement to extract content from
///   - depth: Current recursion depth
///   - maxDepth: Maximum recursion depth
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
    if debugMode && depth < 5 {
        let indent = String(repeating: "  ", count: depth)
        printDebug("\(indent)[\(roleStr)]")
    }
    
    // Check if this is a heading
    if roleStr == "AXHeading" {
        if debugMode {
            let indent = String(repeating: "  ", count: depth)
            printDebug("\(indent)  -> Found heading element")
        }
        
        // Try to get value directly from heading
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
           let valueStr = value as? String, !valueStr.isEmpty {
            content.headings.append(valueStr)
            if debugMode {
                let indent = String(repeating: "  ", count: depth)
                printDebug("\(indent)  -> Heading value: \(valueStr)")
            }
        }
        
        // Try title attribute
        var title: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success,
           let titleStr = title as? String, !titleStr.isEmpty {
            if !content.headings.contains(titleStr) {
                content.headings.append(titleStr)
                if debugMode {
                    let indent = String(repeating: "  ", count: depth)
                    printDebug("\(indent)  -> Heading title: \(titleStr)")
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
            if debugMode && depth < 5 {
                let indent = String(repeating: "  ", count: depth)
                printDebug("\(indent)  -> Value: \(valueStr.prefix(50))...")
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
    if debugMode && depth < 5 {  // Only print first few levels to avoid spam
        let indent = String(repeating: "  ", count: depth)
        printDebug("\(indent)[\(roleStr)]")
    }
    
    // Extract text based on role
    if roleStr == "AXStaticText" || roleStr == "AXTextField" || roleStr == "AXTextArea" {
        // Try value attribute first
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
           let valueStr = value as? String, !valueStr.isEmpty {
            texts.append(valueStr)
            if debugMode && depth < 5 {
                let indent = String(repeating: "  ", count: depth)
                printDebug("\(indent)  -> Value: \(valueStr.prefix(50))...")
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

/// Find the main content area in Books app
/// - Parameter window: The Books window element
/// - Returns: The content area element if found
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
/// - Parameters:
///   - window: The Books window element
///   - extractionTime: The time taken for extraction in milliseconds
/// - Returns: PageContent if successful
func extractPageContent(from window: AXUIElement, extractionTime: Int) -> PageContent? {
    // Get window title (might contain book name)
    var windowTitle: CFTypeRef?
    var bookTitle: String = "Unknown"
    if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &windowTitle) == .success,
       let titleStr = windowTitle as? String {
        bookTitle = titleStr
        printDebug("Window title: \(titleStr)")
    }
    
    // Find the main content area
    printDebug("\nSearching for book content area...")
    
    var structuredContent: ExtractedContent
    
    if let contentArea = findBooksContentArea(window) {
        printDebug("Found content area! Extracting structured content...")
        structuredContent = extractStructuredContent(contentArea)
    } else {
        printDebug("Could not find content area. Extracting from entire window...")
        // Fallback: extract from entire window
        structuredContent = extractStructuredContent(window)
    }
    
    if !structuredContent.texts.isEmpty {
        // Process chapter title (if any)
        var chapterTitle: String? = nil
        if !structuredContent.headings.isEmpty {
            // Take the first heading as chapter title
            chapterTitle = structuredContent.headings.first
            printDebug("Found chapter title: \(chapterTitle ?? "")")
        }
        
        // Join texts and clean up
        let pageText = structuredContent.texts
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        
        let wordsCount = pageText.split(separator: " ").count
        let charsCount = pageText.count
        let language = detectLanguage(pageText)
        
        return PageContent(
            title: bookTitle,
            content: pageText,
            words_count: wordsCount,
            chars_count: charsCount,
            extraction_time_ms: extractionTime,
            language: language,
            chapter_title: chapterTitle
        )
    }
    
    return nil
}

// MARK: - Navigation

/// Navigate to next page using AppleScript
func navigateToNextPage(_ window: AXUIElement) -> Bool {
    printDebug("Navigating to next page using AppleScript...")
    
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
            printDebug("AppleScript error: \(error!)")
            return false
        } else {
            printDebug("Sent arrow right via AppleScript")
            return true
        }
    }
    
    printDebug("Failed to execute AppleScript")
    return false
}

// MARK: - Main Execution

func main() {
    // Start timing
    startTime = Date()
    
    // Check for command line flags
    let args = CommandLine.arguments
    debugMode = args.contains("debug")
    speakMode = args.contains("--speak")
    diagnosticMode = args.contains("--diagnostic")
    
    // Diagnostic mode implies debug mode
    if diagnosticMode {
        debugMode = true
    }
    
    // Parse --pages argument
    if let pagesIndex = args.firstIndex(of: "--pages"),
       pagesIndex + 1 < args.count,
       let pages = Int(args[pagesIndex + 1]),
       pages > 0 {
        pagesToExtract = pages
        printDebug("Will extract \(pagesToExtract) page(s)")
    }
    
    // Parse --delay argument (in milliseconds)
    if let delayIndex = args.firstIndex(of: "--delay"),
       delayIndex + 1 < args.count,
       let delayMs = Int(args[delayIndex + 1]),
       delayMs > 0 {
        pageTransitionDelay = Double(delayMs) / 1000.0
        printDebug("Page transition delay: \(delayMs)ms")
    }
    
    // Parse --output argument
    if let outputIndex = args.firstIndex(of: "--output"),
       outputIndex + 1 < args.count {
        outputFile = args[outputIndex + 1]
        printDebug("Output will be saved to: \(outputFile!)")
    }
    
    // Setup
    if debugMode {
        printDebug("Apple Books Page Content Extractor")
        printDebug(String(repeating: "=", count: 50))
        printDebug("")
        if speakMode {
            printDebug("Speech mode enabled")
        }
    }
    
    // Check if Books is running
    var pid = getBooksProcessID()
    
    if pid == nil {
        printDebug("⚠️  Books app is not running. Attempting to open it...")
        
        // Open Books app
        let workspace = NSWorkspace.shared
        let booksURL = URL(fileURLWithPath: "/System/Applications/Books.app")
        
        let opened = workspace.open(booksURL)
        
        if !opened {
            printDebug("❌ Failed to open Books app")
            exit(1)
        }
        
        printDebug("✅ Launching Books app...")
        
        // Wait for app to launch
        var attempts = 0
        while attempts < 20 {
            Thread.sleep(forTimeInterval: 0.5)
            if let newPid = getBooksProcessID() {
                pid = newPid
                printDebug("✅ Books app launched successfully (PID: \(newPid))")
                Thread.sleep(forTimeInterval: 2.0)
                break
            }
            attempts += 1
        }
        
        if pid == nil {
            printDebug("❌ Failed to launch Books app after 10 seconds")
            exit(1)
        }
    }
    
    guard let finalPid = pid else {
        printDebug("❌ Unable to get Books process ID")
        exit(1)
    }
    
    printDebug("✅ Found Books app (PID: \(finalPid))")
    
    // Get Books application element
    let appElement = AXUIElementCreateApplication(finalPid)
    
    // Get all windows
    var windows: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windows) == .success,
          let windowArray = windows as? [AXUIElement],
          !windowArray.isEmpty else {
        printDebug("❌ No windows found for Books app")
        printDebug("Make sure you have a book open in Books.")
        exit(1)
    }
    
    printDebug("📚 Found \(windowArray.count) window(s)")
    printDebug("")
    
    // Process the first window (main book window)
    guard let mainWindow = windowArray.first else {
        printDebug("❌ No windows found")
        exit(1)
    }
    
    // If diagnostic mode, explore accessibility tree and exit
    if diagnosticMode {
        printDebug("🔍 DIAGNOSTIC MODE: Exploring accessibility attributes")
        printDebug(String(repeating: "=", count: 60))
        printDebug("\nWindow-level attributes:")
        exploreAccessibilityAttributes(mainWindow, maxDepth: 4)
        
        printDebug("\n\nSearching for content area...")
        if let contentArea = findBooksContentArea(mainWindow) {
            printDebug("\n✅ Found content area! Exploring its attributes:")
            printDebug(String(repeating: "-", count: 60))
            exploreAccessibilityAttributes(contentArea, maxDepth: 3)
        } else {
            printDebug("\n❌ Could not find specific content area")
        }
        
        printDebug("\n\nApplication-level attributes:")
        printDebug(String(repeating: "-", count: 60))
        exploreAccessibilityAttributes(appElement, maxDepth: 2)
        
        printDebug("\n🔍 Diagnostic exploration complete")
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
    for pageNumber in 1...pagesToExtract {
        printDebug("Extracting page \(pageNumber) of \(pagesToExtract)...")
        
        // Calculate elapsed time since start
        let elapsedTime = Int(Date().timeIntervalSince(startTime) * 1000)
        
        if let pageContent = extractPageContent(from: mainWindow, extractionTime: elapsedTime) {
            // Check for duplicate content
            if pageContent.content == previousPageContent {
                duplicateCount += 1
                printDebug("⚠️  Duplicate content detected (occurrence #\(duplicateCount))")
                
                // If we get duplicate content, it likely means we've reached the end of the book
                // or navigation isn't working
                if duplicateCount >= 2 {
                    printDebug("🛑 Stopping extraction: Multiple duplicate pages detected")
                    printDebug("   (Likely reached end of book or navigation failure)")
                    break
                }
                
                // Try one more time with a longer delay
                printDebug("   Retrying with longer delay...")
                Thread.sleep(forTimeInterval: pageTransitionDelay * 2)
                continue
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
                currentChapterTitle = pageContent.chapter_title
            }
            
            // Check if we've entered a new chapter
            if pageContent.chapter_title != nil && pageContent.chapter_title != currentChapterTitle {
                // Save the previous chapter if it has content
                if !currentChapterContent.isEmpty {
                    let chapterText = currentChapterContent.joined(separator: "\n\n")
                    let titleText = currentChapterTitle ?? ""
                    let combinedText = titleText + " " + chapterText
                    chapters.append(Chapter(
                        chapter_title: currentChapterTitle,
                        chapter_content: chapterText,
                        chars_count: charCount(combinedText),
                        word_count: wordCount(combinedText)
                    ))
                    currentChapterContent = []
                }
                currentChapterTitle = pageContent.chapter_title
                printDebug("📖 New chapter detected: \(currentChapterTitle ?? "Untitled")")
            }
            
            // Add page content to current chapter
            currentChapterContent.append(pageContent.content)
            
            // Accumulate stats
            totalWords += pageContent.words_count
            totalChars += pageContent.chars_count
            
            if debugMode {
                printDebug("✅ Extracted page \(pageNumber): \(pageContent.words_count) words")
                if let chapterTitle = pageContent.chapter_title {
                    printDebug("   Chapter: \(chapterTitle)")
                }
            }
            
            // Navigate to next page if not the last page
            if pageNumber < pagesToExtract {
                let navSuccess = navigateToNextPage(mainWindow)
                if !navSuccess {
                    printDebug("Warning: Navigation might have failed")
                }
                // Wait for page transition
                Thread.sleep(forTimeInterval: pageTransitionDelay)
            }
        } else {
            printDebug("❌ Failed to extract page \(pageNumber)")
            break
        }
    }
    
    // Don't forget to add the last chapter
    if !currentChapterContent.isEmpty {
        let chapterText = currentChapterContent.joined(separator: "\n\n")
        let titleText = currentChapterTitle ?? ""
        let combinedText = titleText + " " + chapterText
        chapters.append(Chapter(
            chapter_title: currentChapterTitle,
            chapter_content: chapterText,
            chars_count: charCount(combinedText),
            word_count: wordCount(combinedText)
        ))
    }
    
    // Check if we extracted any content
    if chapters.isEmpty {
        printDebug("\n❌ Could not extract any page content.")
        printDebug("Make sure:")
        printDebug("  1. You have a book open in Books")
        printDebug("  2. The book content is visible on screen")
        printDebug("  3. Terminal has Accessibility permissions")
        exit(1)
    }
    
    let totalElapsedTime = Int(Date().timeIntervalSince(startTime) * 1000)
    
    if debugMode {
        printDebug("\n✅ Successfully extracted \(chapters.count) chapter(s)!")
        printDebug(String(repeating: "-", count: 50))
        printDebug("Total words: \(totalWords)")
        printDebug("Total characters: \(totalChars)")
        printDebug("Language: \(detectedLanguage)")
        printDebug("Total processing time: \(totalElapsedTime) ms")
        printDebug(String(repeating: "-", count: 50))
    }
    
    // Create BookContent object
    let bookContent = BookContent(
        title: bookTitle,
        total_chars_count: totalChars,
        total_word_count: totalWords,
        extraction_time_ms: totalElapsedTime,
        language: detectedLanguage,
        content: chapters
    )
    
    // Output JSON using Codable
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    
    do {
        let jsonData = try encoder.encode(bookContent)
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            if let outputPath = outputFile {
                // Write to file
                let fileURL = URL(fileURLWithPath: outputPath)
                try jsonString.write(to: fileURL, atomically: true, encoding: .utf8)
                printDebug("✅ JSON saved to: \(outputPath)")
                print("Successfully saved to: \(outputPath)")
            } else {
                // Print to stdout
                print(jsonString)
            }
        }
    } catch {
        printDebug("Error encoding/saving JSON: \(error)")
        exit(1)
    }
    
    // Speak the content if requested
    if speakMode {
        let allContent = chapters.map { $0.chapter_content }.joined(separator: "\n\n")
        speakText(allContent, language: detectedLanguage, title: bookTitle)
    }
    
    exit(0)
}

// MARK: - Utilities

/// Print debug information to stderr
func printDebug(_ message: String) {
    if debugMode {
        fputs(message + "\n", stderr)
    }
}

/// Calculate word count for a text
func wordCount(_ text: String) -> Int {
    return text.split(separator: " ").count
}

/// Calculate character count for a text
func charCount(_ text: String) -> Int {
    return text.count
}

/// Escape string for JSON
func escapeJSON(_ string: String) -> String {
    return string
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
}

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
            printDebug("Found Siri voice: \(siriVoice.name) for language: \(language)")
            return siriVoice
        }
    } else {
        // For older macOS versions, just check for Siri in name
        if let siriVoice = languageVoices.first(where: { $0.name.contains("Siri") }) {
            printDebug("Found Siri voice: \(siriVoice.name) for language: \(language)")
            return siriVoice
        }
    }
    
    // Then try enhanced quality
    if let enhancedVoice = languageVoices.first(where: { $0.quality == .enhanced }) {
        printDebug("Found enhanced voice: \(enhancedVoice.name) for language: \(language)")
        return enhancedVoice
    }
    
    // Finally, use any available voice for the language
    if let defaultVoice = languageVoices.first {
        printDebug("Using default voice: \(defaultVoice.name) for language: \(language)")
        return defaultVoice
    }
    
    // Fallback to system default
    return AVSpeechSynthesisVoice(language: language)
}

/// Generate speech audio file using the 'say' command
func speakText(_ text: String, language: String, title: String? = nil) {
    // Create the full text to speak
    var fullText = ""
    if let title = title {
        fullText = "Title: \(title). "
    }
    fullText += text
    
    // Create output file path
    let outputPath = FileManager.default.currentDirectoryPath + "/books_audio.aiff"
    printDebug("Saving speech to: \(outputPath)")
    
    // Find the best voice for the language
    var voiceName: String? = nil
    if let voice = findBestVoice(for: language) {
        voiceName = voice.identifier
        // Extract just the voice name from the identifier (e.g., "com.apple.voice.compact.nl-NL.Ellen" -> "Ellen")
        if let lastComponent = voice.identifier.split(separator: ".").last {
            voiceName = String(lastComponent)
        }
    }
    
    // Save text to temporary file (to handle special characters and long text)
    let tempPath = FileManager.default.temporaryDirectory.appendingPathComponent("books_temp_text.txt")
    do {
        try fullText.write(to: tempPath, atomically: true, encoding: .utf8)
    } catch {
        printDebug("Failed to write temporary text file: \(error)")
        return
    }
    
    // Build the say command
    var command = "say -f '\(tempPath.path)' -o '\(outputPath)'"
    if let voiceName = voiceName {
        command += " -v '\(voiceName)'"
        printDebug("Using voice: \(voiceName)")
    }
    
    printDebug("Executing: \(command)")
    
    // Execute the command
    let task = Process()
    task.launchPath = "/bin/bash"
    task.arguments = ["-c", command]
    
    let pipe = Pipe()
    task.standardError = pipe
    
    task.launch()
    task.waitUntilExit()
    
    // Clean up temp file
    try? FileManager.default.removeItem(at: tempPath)
    
    if task.terminationStatus == 0 {
        printDebug("✅ Audio saved successfully to: \(outputPath)")
        
        // Get file size
        if let attributes = try? FileManager.default.attributesOfItem(atPath: outputPath),
           let fileSize = attributes[.size] as? Int64 {
            let sizeInMB = Double(fileSize) / (1024 * 1024)
            printDebug("Audio file size: \(String(format: "%.2f", sizeInMB)) MB")
        }
    } else {
        let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
        if let errorString = String(data: errorData, encoding: .utf8) {
            printDebug("❌ Failed to generate audio: \(errorString)")
        } else {
            printDebug("❌ Failed to generate audio")
        }
    }
}

// Run the main function
main()