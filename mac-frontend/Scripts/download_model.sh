#!/bin/bash
set -e

ROOT=$(dirname "$0")/..

if [[ -z "${HF_TOKEN:-}" ]]; then
  echo "Error: HF_TOKEN environment variable not set."
  echo "Please set it using: export HF_TOKEN=\"your_huggingface_read_token\""
  exit 1
fi

echo "HF_TOKEN detected! Synchronizing Gemma 4 E4B model payloads into Source structure natively..."

if ! python3 -c "import huggingface_hub" &> /dev/null; then
    echo "Installing huggingface_hub locally..."
    pip3 install huggingface_hub --break-system-packages 2>/dev/null || pip3 install huggingface_hub
fi

python3 -c "from huggingface_hub import snapshot_download; snapshot_download(repo_id='mlx-community/gemma-4-e4b-it-4bit', local_dir='$ROOT/Sources/EyesOnGlass/GemmaModel', token='${HF_TOKEN}', ignore_patterns=['*.md', '*.txt', '*.jpg', '*.png'])"

echo "Gemma model natively securely downloaded and injected into the frontend build!"
