#!/usr/bin/env bash

# Changes working directory to where this script is located
cd "$(dirname "$0")"

echo "---------------------------------------------------------"
echo "Starting Eyes-on-Glass backend with sudo privileges..."
echo "This enables powermetrics for M1 True GPU tracking."
echo "---------------------------------------------------------"

# We execute python explicitly from the local virtual environment 
# while passing the PYTHONPATH environment variable through sudo.
sudo PYTHONPATH="$(pwd)" .venv/bin/python app/main.py
