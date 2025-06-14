# Apple Books Page Content Extractor

A Swift tool that uses macOS Accessibility APIs to extract page content from the Apple Books application.

## Requirements

- macOS 10.15 or later
- Apple Books app
- Terminal with Accessibility permissions

## Setup

### 1. Grant Accessibility Permissions

Before using this tool, you need to grant Terminal (or iTerm) accessibility permissions:

1. Open System Preferences → Security & Privacy → Privacy tab
2. Select "Accessibility" from the left sidebar
3. Click the lock icon and authenticate
4. Add Terminal (or your terminal app) to the list
5. Ensure the checkbox is checked

### 2. Build the Tool

```bash
# For quick testing (current architecture only)
swiftc books_page_extractor.swift -o books_page_extractor

# For universal binary (Intel + Apple Silicon)
./build_books_extractor.sh
```

## Usage

1. Open Apple Books and navigate to the page you want to extract
2. Make sure the book content is visible on screen
3. Run the extractor:

```bash
# Default mode - outputs JSON only
./books_page_extractor

# Debug mode - includes diagnostic information
./books_page_extractor debug

# Speak mode - reads the content aloud
./books_page_extractor --speak

# Combine modes
./books_page_extractor debug --speak
```

### Output Format

The tool outputs JSON with the following structure:
```json
{
  "title": "Book Title",
  "content": "The extracted page content...",
  "words_count": 342,
  "chars_count": 2012,
  "extraction_time_ms": 50,
  "language": "nl",
  "chapter-title": "Chapter Name"
}
```

- The `language` field contains the ISO 639-1 language code detected by Apple's NaturalLanguage framework
- The `chapter-title` field appears only when a chapter heading is detected on the page

### Debug Mode

When using the `debug` flag:
- Diagnostic information is printed to stderr
- Shows UI hierarchy traversal
- Displays extraction progress
- Reports processing time in milliseconds
- JSON output still goes to stdout

### Speech Mode

When using the `--speak` flag:
- The extracted content is converted to speech and saved as `books_audio.aiff`
- Automatically selects the best voice for the detected language
- Prioritizes Siri voices when available
- The title and content are both included in the audio
- Uses macOS's built-in `say` command for reliable audio generation
- The audio file is saved in the current directory

## How It Works

The tool uses Apple's Accessibility APIs to:
1. Find the Books app process by its bundle identifier (`com.apple.iBooksX`)
2. Access the app's window hierarchy
3. Search for the main content area containing book text
4. Recursively extract text from all text elements
5. Output the combined page content

## Troubleshooting

If the tool doesn't work:

1. **"Books app is not running"** - The tool will try to launch Books automatically
2. **"No windows found"** - Make sure you have a book open in Books
3. **"Could not extract page content"** - Ensure:
   - A book is open and visible
   - The page has loaded completely
   - Terminal has accessibility permissions
4. **Empty or partial content** - Books may render content in a way that's not fully accessible. Try:
   - Scrolling to ensure content is loaded
   - Switching to a different view mode in Books
   - Using a different book format (EPUB vs PDF)

## Files

- `books_page_extractor.swift` - Main Swift source code
- `build_books_extractor.sh` - Build script for universal binary
- `find_books_info.swift` - Helper script to find Books app information

## Notes

- The tool extracts text from the currently visible page only
- PDF books may have different accessibility structures than EPUB books
- Some DRM-protected content may not be accessible
- The tool respects system accessibility settings