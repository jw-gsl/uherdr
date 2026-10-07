#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_BUILD="$PWD/.build/git-status-tests"
mkdir -p "$TEST_BUILD"
swiftc -emit-library -emit-module -module-name HerdrCore Sources/HerdrCore/*.swift \
    -emit-module-path "$TEST_BUILD/HerdrCore.swiftmodule" -o "$TEST_BUILD/libHerdrCore.dylib"
swiftc -parse-as-library -I "$TEST_BUILD" -L "$TEST_BUILD" -lHerdrCore \
    -Xlinker -rpath -Xlinker "$TEST_BUILD" \
    Sources/HerdrMac/SessionStore.swift Tests/HerdrMacTests/GitStatusPollingTests.swift \
    -o "$TEST_BUILD/GitStatusPollingTests"
"$TEST_BUILD/GitStatusPollingTests"
