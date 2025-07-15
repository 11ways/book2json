#!/bin/bash
set -euo pipefail

# Build Universal Binary for book2json
# This script compiles the Swift code for both Intel and Apple Silicon

echo "Building Universal Binary for book2json..."
echo "======================================="

# Navigate to the script directory
cd "$(dirname "$0")"

# Check if source file exists
if [ ! -f "book2json.swift" ]; then
    echo "❌ Error: book2json.swift not found!"
    exit 1
fi

# Clean up any existing binaries
echo "🧹 Cleaning up old binaries..."
rm -f book2json
rm -f book2json_x86_64
rm -f book2json_arm64

# Build for x86_64 (Intel)
echo "🔨 Building for Intel (x86_64)..."
swiftc book2json.swift -o book2json_x86_64 -target x86_64-apple-macos10.15

if [ $? -ne 0 ]; then
    echo "❌ Failed to build for Intel architecture"
    exit 1
fi

# Build for arm64 (Apple Silicon)
echo "🔨 Building for Apple Silicon (arm64)..."
swiftc book2json.swift -o book2json_arm64 -target arm64-apple-macos11.0

if [ $? -ne 0 ]; then
    echo "❌ Failed to build for Apple Silicon architecture"
    exit 1
fi

# Create universal binary using lipo
echo "🔗 Creating universal binary..."
lipo -create -output book2json book2json_x86_64 book2json_arm64

if [ $? -ne 0 ]; then
    echo "❌ Failed to create universal binary"
    exit 1
fi

# Clean up architecture-specific binaries
echo "🧹 Cleaning up temporary files..."
rm -f book2json_x86_64
rm -f book2json_arm64

# Make the binary executable
chmod +x book2json

# Verify the universal binary
echo ""
echo "✅ Universal binary created successfully!"
echo ""
echo "📊 Binary information:"
file book2json
echo ""
echo "🏗️  Supported architectures:"
lipo -info book2json
echo ""

# Show file size
SIZE=$(ls -lh book2json | awk '{print $5}')
echo "📦 File size: $SIZE"
echo ""

echo "✨ The book2json binary now supports both Intel and Apple Silicon Macs!"
echo ""
echo "📚 Usage:"
echo "   ./book2json"
echo ""
echo "Make sure:"
echo "  - You have a book open in Apple Books"
echo "  - Terminal has Accessibility permissions"
echo "  - The book page is visible on screen"