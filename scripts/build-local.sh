#!/bin/sh
# Build and run `ps` with plain swiftc, for machines with only the Command Line Tools
# (their SwiftPM refuses to build without XCTest). With Xcode, use `swift run ps`.
set -e
cd "$(dirname "$0")/.."
B=${BUILD_DIR:-.build/local}
mkdir -p "$B"
swiftc -O -parse-as-library -emit-library -static -module-name ProofKit \
  -emit-module-path "$B/ProofKit.swiftmodule" -o "$B/libProofKit.a" Sources/ProofKit/*.swift
swiftc -O -parse-as-library -emit-library -static -module-name ProofChecks -I "$B" \
  -emit-module-path "$B/ProofChecks.swiftmodule" -o "$B/libProofChecks.a" Sources/ProofChecks/*.swift
swiftc -O -I "$B" -L "$B" -lProofKit -lProofChecks -o "$B/ps" Sources/ps/main.swift
[ "$1" = "--build-only" ] && exit 0
exec "$B/ps" "$@"
