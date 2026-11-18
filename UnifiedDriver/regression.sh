#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/unified-regression/Multitouch build/unified-regression/scratch
cp -R Multitouch/ build/unified-regression/Multitouch/
diff -qr Multitouch build/unified-regression/Multitouch
cd build/unified-regression
export TMPDIR="$PWD/scratch"
# Unchanged test script, isolated so its hardcoded build output stays in scope.
BT_LIVE_TESTS=0 bash Multitouch/test.sh > results.log 2>&1
rg 'checks,|— PASS' results.log
