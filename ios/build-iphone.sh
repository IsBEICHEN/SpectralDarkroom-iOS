#!/bin/bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
destination=${1:-"$root/ios/out"}
build="$root/ios/.build"
app="$build/Payload/SpectralDarkroom.app"
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
target=arm64-apple-ios18.0

mkdir -p "$build/objects" "$build/ModuleCache" "$destination"
if [[ ! -f "$root/engine/resources/spektrafilm_constants.bin" ]]; then
    echo "Missing tracked engine/resources; finish the repository checkout first." >&2
    exit 1
fi

for source in "$root"/engine/src/core/*.cpp "$root"/engine/src/gpu/*.cpp "$root"/engine/src/pipeline/*.cpp; do
    [[ "$source" == */vulkan_gpu.cpp ]] && continue
    xcrun --sdk iphoneos clang++ -target "$target" -isysroot "$sdk" \
        -std=c++20 -O2 -fPIC -I"$root/engine/include" -I"$root/engine/src" \
        -I"$root/engine/src/core" -I"$root/engine/third_party/metal-cpp" \
        -c "$source" -o "$build/objects/$(basename "$source" .cpp).o"
done
xcrun ar rcs "$build/libspektrafilm.a" "$build"/objects/*.o

rm -rf "$build/Payload"
mkdir -p "$app/engine/shaders" "$app/Licenses"
cp "$root/ios/SpectralDarkroom/Info.plist" "$app/Info.plist"
mkdir -p "$app/zh-Hans.lproj"
cp "$root/ios/SpectralDarkroom/zh-Hans.lproj/InfoPlist.strings" "$app/zh-Hans.lproj/"
xcrun actool --compile "$app" --platform iphoneos \
    --minimum-deployment-target 18.0 --target-device iphone \
    --app-icon AppIcon \
    --output-partial-info-plist "$build/app-icon-info.plist" \
    "$root/ios/SpectralDarkroom/Assets.xcassets" >/dev/null
/usr/libexec/PlistBuddy -c "Merge '$build/app-icon-info.plist'" "$app/Info.plist"
cp -R "$root/engine/resources/." "$app/engine/"
cp "$root/engine/src/shaders/"*.metal "$root/engine/src/shaders/spk_common.h" "$app/engine/shaders/"
if [[ -d "$root/engine/resources_product/profiles" ]]; then
    cp "$root/engine/resources_product/profiles/"*.json "$app/engine/profiles/"
    python3 "$root/ios/Tools/merge-product-filters.py" \
        "$root/engine/resources/neutral_print_filters.json" \
        "$root/engine/resources_product/neutral_print_filters.json" \
        "$app/engine/neutral_print_filters.json"
    cp "$root/engine/resources_product/paper_grades.json" "$app/paper_grades.json"
    cp "$root/engine/resources_product/NOTICE.md" "$app/Licenses/PRODUCT_PROFILES_NOTICE.md"
fi
python3 "$root/ios/Tools/make-stock-catalog.py" "$app/engine" "$app/stock-catalog.json"
cp "$root/LICENSE.txt" "$app/Licenses/GPL-3.0.txt"
cp "$root/engine/third_party/metal-cpp/LICENSE.txt" "$app/Licenses/Apache-2.0.txt"
cp "$root/ios/SpectralDarkroom/NOTICE.md" "$app/Licenses/NOTICE.md"
cp "$root/ios/Tools/reference-images/NOTICE.md" "$app/Licenses/StockPreviews-NOTICE.md"
if [[ -d "$root/ios/SpectralDarkroom/StockPreviews" ]]; then
    mkdir -p "$app/StockPreviews"
    cp -R "$root/ios/SpectralDarkroom/StockPreviews/." "$app/StockPreviews/"
fi

xcrun --sdk iphoneos swiftc -disable-sandbox -parse-as-library \
    -target "$target" -sdk "$sdk" \
    -I"$root/engine/include" \
    -module-cache-path "$build/ModuleCache" \
    -import-objc-header "$root/ios/SpectralDarkroom/Bridge.h" \
    "$root/ios/SpectralDarkroom/SpectralDarkroom.swift" \
    "$build/libspektrafilm.a" -lc++ \
    -framework Metal -framework Foundation -framework QuartzCore \
    -framework CoreText -framework CoreGraphics -framework Accelerate \
    -framework CoreImage -framework ImageIO -framework Photos -framework PhotosUI -framework UIKit \
    -o "$app/SpectralDarkroom"

# An ad-hoc signature makes the bundle inspectable. For installation, the
# user's Apple development profile must replace this signature.
codesign --force --sign - "$app"
(cd "$build" && /usr/bin/zip -qry "$destination/SpectralDarkroom-unsigned.ipa" Payload)
echo "$destination/SpectralDarkroom-unsigned.ipa"
