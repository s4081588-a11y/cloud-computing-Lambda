#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKEND_DIR="$PROJECT_ROOT/backend"
BUILD_DIR="$SCRIPT_DIR/.build_lambda"
OUTPUT_ZIP="$SCRIPT_DIR/lambda_package.zip"

INCLUDE_DEPENDENCIES="${INCLUDE_DEPENDENCIES:-false}"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

cp "$BACKEND_DIR/lambda_function.py" "$BUILD_DIR/"

if [[ "$INCLUDE_DEPENDENCIES" == "true" ]]; then
	PYTHON_BIN="${PYTHON_BIN:-python3}"
	"$PYTHON_BIN" -m pip install --upgrade pip
	"$PYTHON_BIN" -m pip install -r "$BACKEND_DIR/requirements.txt" -t "$BUILD_DIR"
fi

rm -f "$OUTPUT_ZIP"
(cd "$BUILD_DIR" && zip -qr "$OUTPUT_ZIP" .)

rm -rf "$BUILD_DIR"

echo "Created $OUTPUT_ZIP"
