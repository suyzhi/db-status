#!/bin/bash
# VolumeMonitor 构建 & 启动
cd "$(dirname "$0")"

echo "🔨 Building..."
swift build -c release 2>&1 | grep -E "error:|Build complete|Building"

echo "📦 Copying binary..."
cp .build/release/VolumeMonitor build/VolumeMonitor.app/Contents/MacOS/VolumeMonitor

echo "🔑 Re-signing..."
codesign --force --sign - build/VolumeMonitor.app 2>/dev/null

echo "🛑 Killing old instance..."
pkill -9 -f "VolumeMonitor" 2>/dev/null || true
sleep 0.3

echo "🚀 Launching..."
open build/VolumeMonitor.app

echo "✅ Done"
