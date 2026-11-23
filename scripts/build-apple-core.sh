#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
out="$root/build"
gen="$root/Apple/Generated"
mkdir -p "$out" "$gen" "$out/headers"
cd core
export PATH="$(dirname "$(rustup which --toolchain stable rustc)"):$PATH"
export LIBOPUS_NO_PKG=1 LIBOPUS_STATIC=1 CMAKE_POLICY_VERSION_MINIMUM=3.5
export MACOSX_DEPLOYMENT_TARGET=14.0 IPHONEOS_DEPLOYMENT_TARGET=17.0
rustup run stable cargo build --locked --features bindgen --bin bindgen
rustup run stable cargo build --locked --lib
target/debug/bindgen generate --library target/debug/libopents_core.dylib --language swift --out-dir "$gen"
cp "$gen/opents_coreFFI.h" "$out/headers/"
cp "$gen/opents_coreFFI.modulemap" "$out/headers/module.modulemap"
args=()
for platform in aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim; do
  rustup run stable cargo build --locked --lib --target "$platform"
  args+=(-library "$PWD/target/$platform/debug/libopents_core.a" -headers "$out/headers")
done
staging="$(mktemp -d "$out/xcframework.XXXXXX")"
xcodebuild -create-xcframework "${args[@]}" -output "$staging/OpenTSCore.xcframework"
rm -rf "$out/OpenTSCore.xcframework"
mv "$staging/OpenTSCore.xcframework" "$out/"
rmdir "$staging"
cd "$root"
xcodegen generate
