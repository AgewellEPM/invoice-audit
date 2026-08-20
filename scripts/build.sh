#!/bin/zsh
set -e
cd "$(dirname "$0")/.."
swiftc -O src/vision_ocr.swift -o bin/vision-ocr
echo "built bin/vision-ocr"
