#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Ahmad Parr
# twinpay-kotlin build. Zero dependencies beyond the JDK + kotlinc in ../.tools.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLS="$HERE/../.tools"
JDKDIR="$(ls -d "$TOOLS"/jdk-21* 2>/dev/null | head -1)"
export JAVA_HOME="$JDKDIR"
export PATH="$JDKDIR/bin:$TOOLS/kotlinc/bin:$PATH"

OUT="$HERE/out"
mkdir -p "$OUT/test"

echo "== compiling main (fat jar, stdlib included) =="
kotlinc "$HERE"/src/main/kotlin -include-runtime -d "$OUT/twinpay.jar"

echo "== compiling tests =="
kotlinc -cp "$OUT/twinpay.jar" "$HERE"/src/test/kotlin -d "$OUT/test"

echo "== build ok =="
