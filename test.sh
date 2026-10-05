#!/bin/bash
# Run the self-contained test suite.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLS="$HERE/../.tools"
JDKDIR="$(ls -d "$TOOLS"/jdk-21* 2>/dev/null | head -1)"
export JAVA_HOME="$JDKDIR"
export PATH="$JDKDIR/bin:$PATH"
"$HERE/build.sh" >/dev/null
java -cp "$HERE/out/twinpay.jar:$HERE/out/test" twinpay.TwinpayTest
