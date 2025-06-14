# Swift AirTag Extractor

This directory contains a Swift-based tool that extracts AirTag location data directly from the Find My app using macOS Accessibility APIs. This approach is more reliable and efficient than screenshot-based OCR.

## Components

1. **airtag_extractor.swift** - Main Swift tool that uses Accessibility APIs to extract device locations
2. **find_my_ax.swift** - Debug tool for exploring Find My window structure
3. **debug_find_my.swift** - Diagnostic tool for troubleshooting

## Building

```bash
# Compile the main extractor
swiftc airtag_extractor.swift -o airtag_extractor

# Make it executable
chmod +x airtag_extractor
```

## Usage

### Direct Swift Usage

```bash
# Run the extractor (outputs JSON to stdout, status to stderr)
./airtag_extractor

# Get only JSON output
./airtag_extractor 2>/dev/null

# Pretty print with jq
./airtag_extractor 2>/dev/null | jq .
```

### Python Integration

Use the Python wrapper for database storage and scheduling:

```bash
# Single tracking run
python3 swift_tracker.py

# Run on schedule (every 5 minutes)
python3 swift_tracker.py --schedule 5

# View device summary
python3 swift_tracker.py --summary

# View location history
python3 swift_tracker.py --history

# Filter by device
python3 swift_tracker.py --history --device "Auto"
```

## Requirements

- macOS with Find My app installed
- Accessibility permissions for Terminal/iTerm
- Find My app should be open with the "Items" tab selected

## How It Works

1. Finds the Find My app process
2. Uses Accessibility APIs to traverse the window's UI elements
3. Identifies AirTag device information by pattern matching
4. Parses location, time, and distance data
5. Outputs structured JSON

## Output Format

```json
{
  "name": "Device Name",
  "location": "Location Description",
  "timeStatus": "2 min ago",
  "distance": "0.5 km",
  "rawText": "Original text from UI",
  "extractedAt": "2025-05-29T19:30:00Z"
}
```

## Troubleshooting

1. **No devices found**: Make sure Find My is open and the "Items" tab is selected
2. **Permission denied**: Grant accessibility permissions to Terminal in System Settings
3. **Compilation errors**: Ensure you have Xcode command line tools installed