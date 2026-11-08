#!/bin/bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
build="$root/ios/.preview-build"
app="$root/ios/.build/Payload/SpectralDarkroom.app"
references="$root/ios/Tools/reference-images"
output="$root/ios/SpectralDarkroom/StockPreviews"
sdk=$(xcrun --sdk macosx --show-sdk-path)

mkdir -p "$build/objects" "$output"
for source in "$root"/engine/src/core/*.cpp "$root"/engine/src/gpu/*.cpp "$root"/engine/src/pipeline/*.cpp; do
    [[ "$source" == */vulkan_gpu.cpp ]] && continue
    xcrun --sdk macosx clang++ -target arm64-apple-macos15.0 -isysroot "$sdk" \
        -std=c++20 -O2 -fPIC -I"$root/engine/include" -I"$root/engine/src" \
        -I"$root/engine/src/core" -I"$root/engine/third_party/metal-cpp" \
        -c "$source" -o "$build/objects/$(basename "$source" .cpp).o"
done
xcrun ar rcs "$build/libspektrafilm.a" "$build"/objects/*.o
xcrun --sdk macosx swiftc -target arm64-apple-macos15.0 -sdk "$sdk" \
    -module-cache-path "$build/ModuleCache" \
    -I"$root/engine/include" -import-objc-header "$root/ios/SpectralDarkroom/Bridge.h" \
    "$root/ios/Tools/render-stock-previews.swift" "$build/libspektrafilm.a" -lc++ \
    -framework Metal -framework Foundation -framework QuartzCore \
    -framework CoreText -framework CoreGraphics -framework Accelerate \
    -framework CoreImage -framework ImageIO \
    -o "$build/render-stock-previews"
"$build/render-stock-previews" "$app" "$references" "$output"
