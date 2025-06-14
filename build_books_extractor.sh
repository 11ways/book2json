#!/bin/bash
set -euo pipefail

# Build Universal Binary for Books Page Extractor
# This script compiles the Swift code for both Intel and Apple Silicon

echo "Building Universal Binary for Books Page Extractor..."
echo "===================================================="

# Navigate to the script directory
cd "$(dirname "$0")"

# Check if source file exists
if [ ! -f "books_page_extractor.swift" ]; then
    echo "❌ Error: books_page_extractor.swift not found!"
    exit 1
fi

# Clean up any existing binaries
echo "🧹 Cleaning up old binaries..."
rm -f books_page_extractor
rm -f books_page_extractor_x86_64
rm -f books_page_extractor_arm64

# Build for x86_64 (Intel)
echo "🔨 Building for Intel (x86_64)..."
swiftc books_page_extractor.swift -o books_page_extractor_x86_64 -target x86_64-apple-macos10.15

if [ $? -ne 0 ]; then
    echo "❌ Failed to build for Intel architecture"
    exit 1
fi

# Build for arm64 (Apple Silicon)
echo "🔨 Building for Apple Silicon (arm64)..."
swiftc books_page_extractor.swift -o books_page_extractor_arm64 -target arm64-apple-macos11.0

if [ $? -ne 0 ]; then
    echo "❌ Failed to build for Apple Silicon architecture"
    exit 1
fi

# Create universal binary using lipo
echo "🔗 Creating universal binary..."
lipo -create -output books_page_extractor books_page_extractor_x86_64 books_page_extractor_arm64

if [ $? -ne 0 ]; then
    echo "❌ Failed to create universal binary"
    exit 1
fi

# Clean up architecture-specific binaries
echo "🧹 Cleaning up temporary files..."
rm -f books_page_extractor_x86_64
rm -f books_page_extractor_arm64

# Make the binary executable
chmod +x books_page_extractor

# Verify the universal binary
echo ""
echo "✅ Universal binary created successfully!"
echo ""
echo "📊 Binary information:"
file books_page_extractor
echo ""
echo "🏗️  Supported architectures:"
lipo -info books_page_extractor
echo ""

# Show file size
SIZE=$(ls -lh books_page_extractor | awk '{print $5}')
echo "📦 File size: $SIZE"
echo ""

echo "✨ The books_page_extractor binary now supports both Intel and Apple Silicon Macs!"
echo ""
echo "📚 Usage:"
echo "   ./books_page_extractor"
echo ""
echo "Make sure:"
echo "  - You have a book open in Apple Books"
echo "  - Terminal has Accessibility permissions"
echo "  - The book page is visible on screen"