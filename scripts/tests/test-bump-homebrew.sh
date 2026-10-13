#!/usr/bin/env bash
# Tests for scripts/bump-homebrew.sh. Each case bumps a copy of the real cask and formula.
#   bash scripts/tests/test-bump-homebrew.sh
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
script="$repo/scripts/bump-homebrew.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/bump-homebrew-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
dmg_sha="$(printf 'a%.0s' $(seq 64))"
cli_sha="$(printf 'b%.0s' $(seq 64))"

# fresh NAME: a copy of the tap files in $work/NAME.
fresh() {
    root="$work/$1"
    mkdir -p "$root/Casks" "$root/Formula"
    cp "$repo/Casks/openclean.rb" "$root/Casks/"
    cp "$repo/Formula/openclean.rb" "$root/Formula/"
}

check() {
    if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $*"; fi
}

# A normal bump rewrites version, url and both checksums and leaves the rest alone.
fresh ok
printf '%s  OpenClean-1.2.3.dmg\n%s  openclean-cli-1.2.3.zip\n' "$dmg_sha" "$cli_sha" > "$work/sums-ok"
bash "$script" 1.2.3 "$work/sums-ok" "$root" >/dev/null
check grep -qx '  version "1.2.3"' "$root/Casks/openclean.rb"
check grep -qx "  sha256 \"$dmg_sha\"" "$root/Casks/openclean.rb"
check grep -qx '  url "https://github.com/leoAnimesh/OpenClean/releases/download/v1.2.3/openclean-cli-1.2.3.zip"' \
    "$root/Formula/openclean.rb"
check grep -qx "  sha256 \"$cli_sha\"" "$root/Formula/openclean.rb"
check grep -q 'releases/download/v#{version}/OpenClean-#{version}.dmg' "$root/Casks/openclean.rb"
check grep -q 'url "https://github.com/leoAnimesh/OpenClean.git", branch: "main"' "$root/Formula/openclean.rb"
check test "$(diff "$repo/Formula/openclean.rb" "$root/Formula/openclean.rb" | grep -c '^>')" = 2
check test "$(diff "$repo/Casks/openclean.rb" "$root/Casks/openclean.rb" | grep -c '^>')" = 2
if command -v ruby >/dev/null; then
    check ruby -c "$root/Casks/openclean.rb" >/dev/null
    check ruby -c "$root/Formula/openclean.rb" >/dev/null
fi

# Bumping twice is idempotent.
cp "$root/Casks/openclean.rb" "$work/cask-once"
bash "$script" 1.2.3 "$work/sums-ok" "$root" >/dev/null
check cmp -s "$work/cask-once" "$root/Casks/openclean.rb"

# expect_failure NAME VERSION SUMS: the script fails and leaves the files untouched.
expect_failure() {
    fresh "$1"
    if bash "$script" "$2" "$3" "$root" >/dev/null 2>&1; then
        fail=$((fail + 1)); echo "FAIL: $1 should have failed"
    else
        pass=$((pass + 1))
    fi
    check cmp -s "$repo/Casks/openclean.rb" "$root/Casks/openclean.rb"
    check cmp -s "$repo/Formula/openclean.rb" "$root/Formula/openclean.rb"
}

expect_failure bad-version "v1.2" "$work/sums-ok"
expect_failure missing-sums 1.2.3 "$work/does-not-exist"
printf '%s  OpenClean-1.2.3.dmg\n' "$dmg_sha" > "$work/sums-no-cli"
expect_failure no-cli-sum 1.2.3 "$work/sums-no-cli"
printf '%s  OpenClean-1.2.4.dmg\n%s  openclean-cli-1.2.4.zip\n' "$dmg_sha" "$cli_sha" > "$work/sums-other"
expect_failure other-version 1.2.3 "$work/sums-other"
printf 'XYZ  OpenClean-1.2.3.dmg\n%s  openclean-cli-1.2.3.zip\n' "$cli_sha" > "$work/sums-bad"
expect_failure malformed-sum 1.2.3 "$work/sums-bad"
printf '%s  OpenClean-1.2.3.dmg\n%s  OpenClean-1.2.3.dmg\n%s  openclean-cli-1.2.3.zip\n' \
    "$dmg_sha" "$cli_sha" "$cli_sha" > "$work/sums-dup"
expect_failure duplicate-sum 1.2.3 "$work/sums-dup"

# A reshaped formula (no stable sha256 line) fails before the cask is touched.
fresh reshaped
grep -v '^  sha256 ' "$repo/Formula/openclean.rb" > "$root/Formula/openclean.rb"
if bash "$script" 1.2.3 "$work/sums-ok" "$root" >/dev/null 2>&1; then
    fail=$((fail + 1)); echo "FAIL: reshaped formula should have failed"
else
    pass=$((pass + 1))
fi
check cmp -s "$repo/Casks/openclean.rb" "$root/Casks/openclean.rb"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
