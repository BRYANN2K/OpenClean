#!/usr/bin/env bash
# Point the Homebrew cask (Casks/openclean.rb) and formula (Formula/openclean.rb) at a release.
#
#   scripts/bump-homebrew.sh VERSION SHA256SUMS.txt [ROOT]
#
# Reads the SHA-256 of OpenClean-VERSION.dmg and openclean-cli-VERSION.zip from the release's
# SHA256SUMS.txt (as written by `make checksums`) and rewrites the cask's `version`/`sha256` and the
# formula's stable `url`/`sha256`. ROOT defaults to the repository root (the tests pass a temp copy).
# The release workflow runs this after publishing and opens a pull request with the result, because
# main is protected and CI can't push to it.
set -euo pipefail

[ $# -ge 2 ] || { echo "usage: $0 VERSION SHA256SUMS.txt [ROOT]" >&2; exit 64; }
version="$1"
sums="$2"
root="${3:-$(git rev-parse --show-toplevel)}"
cask="$root/Casks/openclean.rb"
formula="$root/Formula/openclean.rb"

fail() { echo "bump-homebrew: $*" >&2; exit 1; }

printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "version must look like 1.2.3, got '$version'"
[ -f "$sums" ] || fail "no such file: $sums"
[ -f "$cask" ] || fail "no such file: $cask"
[ -f "$formula" ] || fail "no such file: $formula"

# sha_of NAME: the hash `shasum -a 256` recorded for NAME (exactly one line, 64 lower-case hex digits).
sha_of() {
    local hashes
    hashes="$(awk -v name="$1" '$2 == name || $2 == "*" name { print $1 }' "$sums")"
    [ "$(printf '%s\n' "$hashes" | grep -c .)" = 1 ] || fail "expected one checksum for $1 in $sums"
    printf '%s' "$hashes" | grep -Eqx '[0-9a-f]{64}' || fail "malformed checksum for $1 in $sums"
    printf '%s' "$hashes"
}

dmg_sha="$(sha_of "OpenClean-$version.dmg")"
cli_sha="$(sha_of "openclean-cli-$version.zip")"

cask_version='^  version "[^"]*"$'
any_sha='^  sha256 "[0-9a-f]*"$'
formula_url='^  url "https://github\.com/leoAnimesh/OpenClean/releases/download/'

# Each pattern must match exactly one line, so a reshaped file fails loudly. Everything is checked
# before anything is written, so a failure never leaves the files half-bumped.
expect_one() {
    [ "$(grep -Ec "$2" "$1")" = 1 ] || fail "expected one line matching /$2/ in $1"
}
expect_one "$cask" "$cask_version"
expect_one "$cask" "$any_sha"
expect_one "$formula" "$formula_url"
expect_one "$formula" "$any_sha"

replace_line() {
    local file="$1" pattern="$2" replacement="$3"
    local tmp
    tmp="$(mktemp "$file.XXXXXX")"
    awk -v pattern="$pattern" -v replacement="$replacement" \
        '$0 ~ pattern { print replacement; next } { print }' "$file" > "$tmp"
    mv "$tmp" "$file"
}

replace_line "$cask" "$cask_version" "  version \"$version\""
replace_line "$cask" "$any_sha" "  sha256 \"$dmg_sha\""
replace_line "$formula" "$formula_url" \
    "  url \"https://github.com/leoAnimesh/OpenClean/releases/download/v$version/openclean-cli-$version.zip\""
replace_line "$formula" "$any_sha" "  sha256 \"$cli_sha\""

echo "Casks/openclean.rb    -> $version ($dmg_sha)"
echo "Formula/openclean.rb  -> $version ($cli_sha)"
