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

/// Represents extracted page content from Books
struct PageContent: Codable {
    let title: String
    let content: String
    let words_count: Int
    let chars_count: Int
    let extraction_time_ms: Int
    let language: String
    let chapter_title: String?
    
    // Define encoding order
    private enum CodingKeys: String, CodingKey {
        case title
        case content
        case words_count
        case chars_count
        case extraction_time_ms
        case language
        case chapter_title = "chapter-title"
    }
}

// MARK: - Global variables

var debugMode = false
var speakMode = false
var startTime = Date()

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

// MARK: - Main Execution

func main() {
    // Start timing
    startTime = Date()
    
    // Check for command line flags
    let args = CommandLine.arguments
    debugMode = args.contains("debug")
    speakMode = args.contains("--speak")
    
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
    
    // Process each window
    for (index, window) in windowArray.enumerated() {
        printDebug("Processing window \(index + 1)...")
        
        // Calculate elapsed time since start
        let elapsedTime = Int(Date().timeIntervalSince(startTime) * 1000)
        
        if let pageContent = extractPageContent(from: window, extractionTime: elapsedTime) {
            if debugMode {
                printDebug("\n✅ Successfully extracted page content!")
                printDebug(String(repeating: "-", count: 50))
                printDebug("\nExtracted \(pageContent.words_count) words from: \(pageContent.title)")
                if let chapterTitle = pageContent.chapter_title {
                    printDebug("Chapter title: \(chapterTitle)")
                }
                printDebug("Detected language: \(pageContent.language)")
                printDebug("Processing time: \(pageContent.extraction_time_ms) ms")
                printDebug(String(repeating: "-", count: 50))
            }
            
            // Output JSON to stdout with consistent ordering
            // Build JSON manually to ensure consistent property order
            var json = """
            {
              "title" : "\(escapeJSON(pageContent.title))",
              "content" : "\(escapeJSON(pageContent.content))",
              "words_count" : \(pageContent.words_count),
              "chars_count" : \(pageContent.chars_count),
              "extraction_time_ms" : \(pageContent.extraction_time_ms),
              "language" : "\(escapeJSON(pageContent.language))"
            """
            
            // Add chapter-title if present
            if let chapterTitle = pageContent.chapter_title {
                json += ",\n  \"chapter-title\" : \"\(escapeJSON(chapterTitle))\""
            }
            
            json += "\n}"
            print(json)
            
            // Speak the content if requested
            if speakMode {
                speakText(pageContent.content, language: pageContent.language, title: pageContent.title)
            }
            
            // Exit after first successful extraction
            exit(0)
        }
    }
    
    printDebug("\n❌ Could not extract page content from any window.")
    printDebug("Make sure:")
    printDebug("  1. You have a book open in Books")
    printDebug("  2. The book content is visible on screen")
    printDebug("  3. Terminal has Accessibility permissions")
    exit(1)
}

// MARK: - Utilities

/// Print debug information to stderr
func printDebug(_ message: String) {
    if debugMode {
        fputs(message + "\n", stderr)
    }
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
    if let siriVoice = languageVoices.first(where: { $0.quality == .premium || $0.name.contains("Siri") }) {
        printDebug("Found Siri voice: \(siriVoice.name) for language: \(language)")
        return siriVoice
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