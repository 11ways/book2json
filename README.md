# Apple Books Page Content Extractor

A Swift tool that uses macOS Accessibility APIs to extract page content from the Apple Books application. It can extract single or multiple pages, detect chapters, and export content to JSON or audio formats.

## Requirements

- macOS 10.15 or later (for Intel builds) / macOS 11.0 or later (for Apple Silicon)
- Apple Books app
- Terminal with Accessibility permissions
- Swift compiler (comes with Xcode or Command Line Tools)

## Setup

### 1. Grant Accessibility Permissions

Before using this tool, you need to grant Terminal (or iTerm) accessibility permissions:

1. Open System Preferences → Security & Privacy → Privacy tab
2. Select "Accessibility" from the left sidebar
3. Click the lock icon and authenticate
4. Add Terminal (or your terminal app) to the list
5. Ensure the checkbox is checked

### 2. Build the Tool

#### Quick Build (Current Architecture)
```bash
swiftc books_page_extractor.swift -o books_page_extractor
```

#### Universal Binary Build (Intel + Apple Silicon)
```bash
./build_books_extractor.sh
```

The `build_books_extractor.sh` script performs the following steps:
1. **Validates Environment**: Checks that the source file exists
2. **Cleans Previous Builds**: Removes any existing binaries
3. **Compiles for Intel (x86_64)**: Targets macOS 10.15+ for Intel Macs
4. **Compiles for Apple Silicon (arm64)**: Targets macOS 11.0+ for M1/M2/M3 Macs
5. **Creates Universal Binary**: Uses `lipo` to combine both architectures
6. **Verifies Output**: Shows binary info and supported architectures
7. **Sets Permissions**: Makes the binary executable

## Usage

### Basic Usage

```bash
# Extract single page (default)
./books_page_extractor

# Extract content and save to file
./books_page_extractor --output book.json
```

### Command Line Options

| Option | Description | Example |
|--------|-------------|---------|
| `--pages N` | Extract N pages from the book | `./books_page_extractor --pages 10` |
| `--delay MS` | Set delay between page turns in milliseconds (default: 300) | `./books_page_extractor --pages 5 --delay 500` |
| `--output FILE` | Save JSON output to file instead of stdout | `./books_page_extractor --output chapter1.json` |
| `--speak` | Generate audio file from extracted content | `./books_page_extractor --speak` |
| `debug` | Enable debug mode with diagnostic output | `./books_page_extractor debug` |
| `--diagnostic` | Deep diagnostic mode for troubleshooting | `./books_page_extractor --diagnostic` |

### Advanced Examples

```bash
# Extract entire chapter (10 pages) with custom delay
./books_page_extractor --pages 10 --delay 500 --output chapter.json

# Extract and generate audio with debug info
./books_page_extractor debug --pages 5 --speak

# Diagnostic mode to inspect UI hierarchy
./books_page_extractor --diagnostic
```

### Multi-Page Extraction

When extracting multiple pages:
- The tool automatically navigates through pages using keyboard shortcuts
- Chapter headings are detected and content is organized by chapters
- Duplicate detection prevents infinite loops at book end
- Content from all pages is combined into a structured JSON output

### Output Format

#### Single Page Output
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

#### Multi-Page Output
```json
{
  "title": "Book Title",
  "total_chars_count": 15234,
  "total_word_count": 2341,
  "extraction_time_ms": 3500,
  "language": "en",
  "content": [
    {
      "chapter-title": "Chapter 1",
      "chapter-content": "Chapter content...",
      "chars_count": 5234,
      "word_count": 823
    },
    {
      "chapter-title": "Chapter 2",
      "chapter-content": "Chapter content...",
      "chars_count": 10000,
      "word_count": 1518
    }
  ]
}
```

### Debug Mode

When using the `debug` flag:
- Diagnostic information is printed to stderr
- Shows UI hierarchy traversal
- Displays extraction progress
- Reports processing time in milliseconds
- JSON output still goes to stdout
- Helps troubleshoot extraction issues

### Diagnostic Mode

The `--diagnostic` flag provides deep inspection:
- Explores the complete accessibility tree
- Shows all available UI element attributes
- Helps identify content location in complex layouts
- Useful for debugging extraction failures

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