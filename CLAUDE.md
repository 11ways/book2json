# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository contains tools for extracting content from Apple Books using macOS Accessibility APIs. The main component is book2json, a Swift-based tool that can read book content, detect chapters, and export to JSON or audio formats.

## Build Commands

```bash
# Quick build (current architecture only)
swiftc book2json.swift -o book2json

# Universal binary build (Intel + Apple Silicon)
./build_book2json.sh
```

## Common Usage

```bash
# Extract single page
./book2json

# Extract multiple pages
./book2json --pages 10

# Debug mode with diagnostics
./book2json debug

# Generate audio file
./book2json --speak

# Save to file
./book2json --output book_content.json
```

## Architecture

The codebase uses Apple's Accessibility APIs to interact with the Books app:

1. **Process Management**: Finds or launches Books app by bundle ID (`com.apple.iBooksX`)
2. **UI Traversal**: Uses `AXUIElement` APIs to navigate the app's accessibility hierarchy
3. **Content Extraction**: Recursively extracts text from `AXStaticText` elements, with special handling for headings
4. **Navigation**: Uses AppleScript to send keyboard events for page turning
5. **Language Detection**: Uses `NaturalLanguage` framework for automatic language detection
6. **Speech Synthesis**: Integrates with macOS `say` command for audio generation

## Key Implementation Details

- The extractor identifies chapter headings by looking for `AXHeading` role elements
- Duplicate page detection prevents infinite loops at book end
- Supports multi-page extraction with configurable delays between pages
- JSON output uses `Codable` for structured chapter-based content
- Audio generation automatically selects appropriate voice based on detected language

## Development Notes

- Requires Accessibility permissions for Terminal/iTerm
- Books app must be open with a book visible
- Some DRM-protected content may not be accessible
- PDF books may have different accessibility structures than EPUB books