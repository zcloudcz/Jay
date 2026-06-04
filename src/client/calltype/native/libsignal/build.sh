#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build.sh — Cross-compile calltype_signal for all target platforms
# ---------------------------------------------------------------------------
# This is a placeholder build script. Each target requires its own toolchain:
#
#   Android: cargo-ndk (installs NDK targets via rustup)
#   iOS:     cargo-lipo (builds universal arm64 + x86_64 static lib)
#   Web:     wasm-pack  (compiles to WASM + JS glue)
#
# Prerequisites:
#   rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
#   rustup target add aarch64-apple-ios x86_64-apple-ios
#   cargo install cargo-ndk cargo-lipo wasm-pack
# ---------------------------------------------------------------------------

set -euo pipefail

echo "=== Building calltype_signal ==="

# --- Android (requires Android NDK) ---
# cargo ndk -t armeabi-v7a -t arm64-v8a -t x86_64 -o ../android/app/src/main/jniLibs build --release
echo "[SKIP] Android build — uncomment when NDK is configured"

# --- iOS (requires Xcode) ---
# cargo lipo --release
# cp target/universal/release/libcalltype_signal.a ../../ios/Runner/
echo "[SKIP] iOS build — uncomment when Xcode toolchain is available"

# --- Web (WASM) ---
# wasm-pack build --target web --out-dir ../../web/pkg
echo "[SKIP] WASM build — uncomment when wasm-pack is installed"

echo "=== Done ==="
