#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CACHE_DIR="$PROJECT_DIR/build/SwiftScriptCache"

mkdir -p "$CACHE_DIR"

env CLANG_MODULE_CACHE_PATH="$CACHE_DIR" swift -module-cache-path "$CACHE_DIR" "$PROJECT_DIR/test-audio.swift" "$@"
