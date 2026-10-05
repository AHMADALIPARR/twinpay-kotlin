#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Ahmad Parr
# Run the self-contained test suite.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLS="$HERE/../.tools"
JDKDIR="$(ls -d "$TOOLS"/jdk-21* 2>/dev/null | head -1)"
export JAVA_HOME="$JDKDIR"
export PATH="$JDKDIR/bin:$PATH"
"$HERE/build.sh" >/dev/null
java -cp "$HERE/out/twinpay.jar:$HERE/out/test" twinpay.TwinpayTest
