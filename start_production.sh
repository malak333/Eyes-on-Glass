#!/usr/bin/env bash
set -e

echo "==========================================="
echo "   Eyes on Glass - Swift Vapor Backend"
echo "        Production Launch Script"
echo "==========================================="

cd swift-backend

echo "[Phase 1] Building Vapor Binary for Release (Apple Silicon Optimized)..."
swift build -c release

echo "[Phase 2] Launching Backend as standard user (SystemMonitor manages sudo internally)..."
.build/release/App
