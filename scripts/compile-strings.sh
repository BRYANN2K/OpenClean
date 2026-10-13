#!/usr/bin/env bash
# Compile the app's String Catalogs into the .lproj folders SwiftPM ships as resources.
#
#   scripts/compile-strings.sh
#
# Localizable.xcstrings is the file to edit (Xcode or by hand). SwiftPM's native build system (the one
# `swift build` / `swift test` use with Xcode 16) copies an .xcstrings file without compiling it, so the
# targets ship the compiled <lang>.lproj/Localizable.strings(dict) instead, generated here with Xcode's
# xcstringstool. Run this after every catalog change and commit the result;
# LocalizationCatalogTests fails when the .lproj folders are out of date.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
for target in OpenCleanApp OpenCleanAppModel; do
    resources="$root/Apps/OpenClean/Sources/$target/Resources"
    rm -rf "$resources"/*.lproj
    xcrun xcstringstool compile "$resources/Localizable.xcstrings" --output-directory "$resources" \
        --serialization-format text
    echo "$target: $(cd "$resources" && ls -d *.lproj | tr '\n' ' ')"
done
