#!/bin/bash
set -euo pipefail

# Build Universal Binary for AirTag Extractor
# This script compiles the Swift code for both Intel and Apple Silicon

echo "Building Universal Binary for AirTag Extractor..."
echo "================================================"

# Navigate to the swift directory
cd "$(dirname "$0")"

# Check if source file exists
if [ ! -f "airtag_extractor.swift" ]; then
    echo "❌ Error: airtag_extractor.swift not found!"
    exit 1
fi

# Clean up any existing binaries
echo "🧹 Cleaning up old binaries..."
rm -f airtag_extractor
rm -f airtag_extractor_x86_64
rm -f airtag_extractor_arm64

# Build for x86_64 (Intel)
echo "🔨 Building for Intel (x86_64)..."
swiftc airtag_extractor.swift -o airtag_extractor_x86_64 -target x86_64-apple-macos10.15

if [ $? -ne 0 ]; then
    echo "❌ Failed to build for Intel architecture"
    exit 1
fi

# Build for arm64 (Apple Silicon)
echo "🔨 Building for Apple Silicon (arm64)..."
swiftc airtag_extractor.swift -o airtag_extractor_arm64 -target arm64-apple-macos11.0

if [ $? -ne 0 ]; then
    echo "❌ Failed to build for Apple Silicon architecture"
    exit 1
fi

# Create universal binary using lipo
echo "🔗 Creating universal binary..."
lipo -create -output airtag_extractor airtag_extractor_x86_64 airtag_extractor_arm64

if [ $? -ne 0 ]; then
    echo "❌ Failed to create universal binary"
    exit 1
fi

# Clean up architecture-specific binaries
echo "🧹 Cleaning up temporary files..."
rm -f airtag_extractor_x86_64
rm -f airtag_extractor_arm64

# Make the binary executable
chmod +x airtag_extractor

# Verify the universal binary
echo ""
echo "✅ Universal binary created successfully!"
echo ""
echo "📊 Binary information:"
file airtag_extractor
echo ""
echo "🏗️  Supported architectures:"
lipo -info airtag_extractor
echo ""

# Show file size
SIZE=$(ls -lh airtag_extractor | awk '{print $5}')
echo "📦 File size: $SIZE"
echo ""

echo "✨ The airtag_extractor binary now supports both Intel and Apple Silicon Macs!"
echo ""
echo "You can now commit this universal binary to your repository."