#!/bin/bash
# Eyes on Glass - Swift Backend sudo runner
# Needed for accessing macOS powermetrics telemetry.

echo "Starting Swift Backend with root privileges..."

# Swift build should ideally be run as standard user, then binary run as sudo
swift build -c release
sudo .build/release/App
