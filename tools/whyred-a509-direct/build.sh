#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p out
xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=16.0 -O2 -Wall -Wextra a509_direct_test.c -framework CoreFoundation -framework IOKit -o out/a509_direct_test
codesign --force --sign - out/a509_direct_test
