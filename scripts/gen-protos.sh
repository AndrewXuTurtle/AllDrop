#!/bin/bash
# Regenerates Swift code from the Google Quick Share .proto files.
# Requires: brew install swift-protobuf
set -euo pipefail
cd "$(dirname "$0")/.."
rm -f Sources/QuickShare/Generated/*.pb.swift
protoc --proto_path=Protos --swift_out=Sources/QuickShare/Generated Protos/*.proto
