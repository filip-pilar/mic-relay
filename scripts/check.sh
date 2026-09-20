#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/checks build/ModuleCache
sources=(MicRelay/Audio/*.swift MicRelay/App/AudioFileSupport.swift)
binary=build/checks/mic-relay-checks
case "${1:-}" in
    "") sources+=(Tests/Checks.swift Tests/AudioChecks.swift) ;;
    --audio)
        binary=build/checks/mic-relay-hardware-checks
        sources+=(MicRelay/App/AppState.swift MicRelay/App/LibraryState.swift
            MicRelay/App/SoundboardState.swift MicRelay/App/LibraryDownloader.swift
            Tests/HardwareChecks.swift)
        ;;
    *) echo "Usage: $0 [--audio]" >&2; exit 1 ;;
esac
swiftc -O -swift-version 6 -module-cache-path build/ModuleCache \
    "${sources[@]}" -o "$binary"
"$binary"
