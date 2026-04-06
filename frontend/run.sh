#!/usr/bin/env bash

# Changes working directory to where this script is located
cd "$(dirname "$0")"

echo "---------------------------------------------------------"
echo "Starting Eyes-on-Glass Vite Frontend Dashboard..."
echo "---------------------------------------------------------"

# We execute npm run dev to start the React UI
npm run dev
