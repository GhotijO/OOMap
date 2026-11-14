#!/bin/sh
set -e
cd "$(dirname "$0")"
mkdir -p bin
if [ ! -f lib/libz3.dll ] && [ ! -f lib/libz3.so ] && [ ! -f lib/libz3.dylib ]; then
    echo "[build] warning: Z3 runtime not found; run scripts/fetch_z3.ps1 (Windows) or install Z3"
fi
odin build src -out:bin/OOMap
cp -f lib/*.dll bin/ 2>/dev/null || true
cp -f lib/*.so bin/ 2>/dev/null || true
cp -f lib/*.dylib bin/ 2>/dev/null || true
echo "[build] 完成：bin/OOMap"
