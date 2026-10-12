#!/usr/bin/env bash
# Tests for scripts/next-version.sh. Each case builds a throwaway git repo with a crafted history.
#   bash scripts/tests/test-next-version.sh
set -euo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/next-version.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/next-version-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
repo=""

git_() { git -C "$repo" -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }

# new_repo NAME [PLIST_VERSION]: fresh repo with an Info.plist and one non-releasing commit.
new_repo() {
    repo="$work/$1"
    mkdir -p "$repo/Apps/OpenClean"
    git init -q -b main "$repo" 2>/dev/null || { git init -q "$repo" && git_ checkout -q -b main; }
    git_ config user.name "Test"
    git_ config user.email "test@example.invalid"
    cat >"$repo/Apps/OpenClean/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>OpenClean</string>
    <key>CFBundleShortVersionString</key>
    <string>${2:-0.1.0}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
EOF
    git_ add -A
    git_ commit -q -m "chore: initial commit"
}

# commit MESSAGE: empty commit with the given (possibly multi-line) message.
commit() { git_ commit -q --allow-empty -m "$1"; }
tag() { git_ tag "$1"; }

run_script() { (cd "$repo" && "$script" "$@"); }

check() { # name expected actual
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
        printf 'ok   %s\n' "$1"
    else
        fail=$((fail + 1))
        printf 'FAIL %s\n     expected: [%s]\n     actual:   [%s]\n' "$1" "$2" "$3"
    fi
}

check_contains() { # name needle haystack
    case "$3" in
        *"$2"*) pass=$((pass + 1)); printf 'ok   %s\n' "$1" ;;
        *) fail=$((fail + 1)); printf 'FAIL %s\n     missing: [%s]\n' "$1" "$2" ;;
    esac
}

check_absent() { # name needle haystack
    case "$3" in
        *"$2"*) fail=$((fail + 1)); printf 'FAIL %s\n     unexpected: [%s]\n' "$1" "$2" ;;
        *) pass=$((pass + 1)); printf 'ok   %s\n' "$1" ;;
    esac
}

# --- baseline -------------------------------------------------------------------------------------

new_repo no-tag-fix
commit "fix: handle empty caches"
check "no tag: baseline from Info.plist, fix -> patch" "0.1.1" "$(run_script)"
check "no tag: --previous reads Info.plist" "0.1.0" "$(run_script --previous)"

new_repo no-tag-feat 0.4.2
commit "feat: add space lens"
check "no tag: custom Info.plist baseline, feat -> minor" "0.5.0" "$(run_script)"

new_repo no-tag-docs
commit "docs: tweak readme"
check "no tag: only chore/docs -> no release" "" "$(run_script)"

# --- bump levels after a tag ----------------------------------------------------------------------

new_repo patch
tag v0.3.0
commit "fix: off-by-one in sizes"
commit "perf: faster scan"
check "fix + perf -> patch" "0.3.1" "$(run_script)"

new_repo perf-only
tag v1.2.3
commit "perf: cache directory sizes"
check "perf alone -> patch" "1.2.4" "$(run_script)"

new_repo minor
tag v0.3.0
commit "fix: something"
commit "feat: new module"
commit "docs: describe it"
check "feat beats fix -> minor" "0.4.0" "$(run_script)"

new_repo docs-only
tag v0.3.0
commit "docs: readme"
commit "chore: bump deps"
commit "ci: cache builds"
commit "test: more cases"
commit "style: format"
commit "refactor: split file"
commit "build: tweak Makefile"
check "docs/chore/ci/test/style/refactor/build only -> empty" "" "$(run_script)"

new_repo no-commits
tag v2.0.0
check "nothing since tag -> empty" "" "$(run_script)"

new_repo non-conventional
tag v0.3.0
commit "Update README.md"
commit "WIP"
check "non-conventional subjects -> empty" "" "$(run_script)"

# --- breaking changes -----------------------------------------------------------------------------

new_repo bang-zero
tag v0.3.4
commit "feat!: new rule pack format"
check "feat! while 0.x -> minor" "0.4.0" "$(run_script)"

new_repo footer-zero
tag v0.3.4
commit "fix: rename option

BREAKING CHANGE: --old-flag is now --new-flag"
check "BREAKING CHANGE footer while 0.x -> minor" "0.4.0" "$(run_script)"

new_repo bang-one
tag v1.4.2
commit "feat!: new rule pack format"
check "feat! at >=1.0 -> major" "2.0.0" "$(run_script)"

new_repo footer-one
tag v1.4.2
commit "refactor: rework settings storage

BREAKING-CHANGE: settings from 1.x are not migrated"
check "BREAKING-CHANGE footer on refactor at >=1.0 -> major" "2.0.0" "$(run_script)"

new_repo scoped-bang
tag v3.1.0
commit "fix(cli)!: change exit code for skipped items"
check "scoped fix(cli)! at >=1.0 -> major" "4.0.0" "$(run_script)"

new_repo chore-bang-zero
tag v0.9.9
commit "chore!: drop macOS 13"
check "chore! while 0.x -> minor" "0.10.0" "$(run_script)"

# --- scopes, case, merges, squashes ---------------------------------------------------------------

new_repo scoped
tag v0.3.0
commit "feat(app): uninstaller screen"
check "scoped feat(app) -> minor" "0.4.0" "$(run_script)"

new_repo scoped-fix
tag v0.3.0
commit "fix(quarantine,privilege): contain paths"
check "scoped fix with comma scope -> patch" "0.3.1" "$(run_script)"

new_repo squash
tag v0.3.0
commit "Uninstaller (#12)

* feat(uninstaller): find app leftovers
* fix(uninstaller): skip running apps
* docs: mention uninstaller"
check "squash body with bullet feat -> minor" "0.4.0" "$(run_script)"

new_repo squash-conventional-title
tag v1.0.0
commit "docs: polish readme (#13)

* docs: polish readme
* fix: broken link checker
* feat!: drop legacy flag"
check "squash body breaking bullet at >=1.0 -> major" "2.0.0" "$(run_script)"

new_repo merge
tag v0.3.0
git_ checkout -q -b topic
commit "fix(scan): ignore sockets"
git_ checkout -q main
commit "docs: changelog"
git_ merge -q --no-ff topic -m "Merge pull request #7 from someone/topic

fix(scan): ignore sockets"
check "merge commit with fix branch -> patch" "0.3.1" "$(run_script)"

new_repo merge-feature
tag v0.3.0
git_ checkout -q -b topic
commit "chore: prep"
git_ checkout -q main
git_ merge -q --no-ff topic -m "Merge pull request #8 from someone/topic

feat: space lens"
check "merge commit body carrying a feat PR title -> minor" "0.4.0" "$(run_script)"

new_repo older-tags
tag v0.1.0
commit "feat: a"
tag v0.2.0
commit "fix: b"
check "uses newest tag only" "0.2.1" "$(run_script)"

new_repo ignore-non-version-tags
tag v0.5.0
commit "fix: b"
tag nightly
check "ignores tags not matching v[0-9]*" "0.5.1" "$(run_script)"

new_repo prose-colon
tag v0.3.0
commit "docs: explain behaviour

Note: this is not a feature.
Example: feat words in prose"
check "prose lines with colons are not headers" "" "$(run_script)"

# --- notes ----------------------------------------------------------------------------------------

new_repo notes
tag v0.3.0
commit "feat(app): uninstaller screen"
commit "fix: crash on empty trash"
commit "feat!: new pack format"
commit "docs: readme"
commit "Squash (#9)

* feat(app): uninstaller screen"
notes="$(run_script --notes)"
check_contains "notes: breaking section" "## Breaking changes" "$notes"
check_contains "notes: breaking entry" "- new pack format (" "$notes"
check_contains "notes: features section" "## Features" "$notes"
check_contains "notes: scoped entry" "- **app:** uninstaller screen (" "$notes"
check_contains "notes: fixes section" "- crash on empty trash (" "$notes"
check_contains "notes: other section" "- readme (" "$notes"
check_contains "notes: since tag" "Changes since v0.3.0." "$notes"
check_contains "notes: DMG name uses computed version" "OpenClean-0.4.0.dmg" "$notes"
check_contains "notes: CLI zip name" "openclean-cli-0.4.0.zip" "$notes"
check_contains "notes: signed and notarized" "notarized by Apple" "$notes"
check_absent "notes: no Gatekeeper workaround" "com.apple.quarantine" "$notes"
check_absent "notes: no summary file, no collapsed section" "<details>" "$notes"
check_contains "notes: checksum instructions" "SHA256SUMS.txt" "$notes"
dupes="$(printf '%s\n' "$notes" | grep -c 'uninstaller screen' || true)"
check "notes: squash repeat is de-duplicated" "1" "$dupes"
sha="$(git_ log -1 --format=%h HEAD~1)"
check_contains "notes: short sha present" "($sha)" "$notes"
notes_forced="$(run_script --notes --version 9.9.9)"
check_contains "notes: --version overrides label" "OpenClean-9.9.9.dmg" "$notes_forced"
check_absent "notes: forced version replaces computed" "OpenClean-0.4.0.dmg" "$notes_forced"

mkdir -p "$repo/docs/release-notes"
printf 'Hand-written summary.\n' >"$repo/docs/release-notes/0.4.0.md"
notes_summary="$(run_script --notes)"
check "notes: summary file comes first" "Hand-written summary." "$(printf '%s\n' "$notes_summary" | head -n 1)"
check_contains "notes: commit list collapsed under summary" "<summary>All changes</summary>" "$notes_summary"
check_contains "notes: commit list still present" "- crash on empty trash (" "$notes_summary"
check_contains "notes: install section after summary" "OpenClean-0.4.0.dmg" "$notes_summary"
check_absent "notes: summary is per version" "Hand-written summary." "$(run_script --notes --version 9.9.9)"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
