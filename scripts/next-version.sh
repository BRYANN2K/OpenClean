#!/usr/bin/env bash
# Compute OpenClean's next release version from Conventional Commits.
#
#   scripts/next-version.sh                    print the next version (no "v"), or nothing if no release is due
#   scripts/next-version.sh --notes            print Markdown release notes for the next version
#   scripts/next-version.sh --notes --version X.Y.Z   same, but label the notes with X.Y.Z
#   scripts/next-version.sh --previous         print the version the bump is computed from
#
# Baseline: the newest tag reachable from HEAD matching v[0-9]* (git describe). With no tag, the
# CFBundleShortVersionString in Apps/OpenClean/Info.plist is treated as the previous version and every
# commit in HEAD's history counts.
#
# Bump rules, over every commit since the baseline (subjects AND bodies, so squash-merge bodies and merge
# commits whose body carries a PR title are seen too):
#   "type!:" / "type(scope)!:" or a "BREAKING CHANGE:" / "BREAKING-CHANGE:" footer  -> major
#     ...except while major is 0, where a breaking change bumps minor (0.x convention)
#   feat                                                                              -> minor
#   fix, perf                                                                         -> patch
#   anything else (docs, chore, ci, test, style, refactor, build, non-conventional)  -> no release
#
# Only bash and git are required.
set -euo pipefail

mode=version
forced_version=""
while [ $# -gt 0 ]; do
    case "$1" in
        --notes) mode=notes ;;
        --previous) mode=previous ;;
        --version)
            [ $# -ge 2 ] || { echo "next-version: --version needs a value" >&2; exit 64; }
            forced_version="$2"
            shift
            ;;
        -h | --help)
            sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "next-version: unknown argument: $1" >&2; exit 64 ;;
    esac
    shift
done

root="$(git rev-parse --show-toplevel)"
plist="${OPENCLEAN_INFO_PLIST:-$root/Apps/OpenClean/Info.plist}"

plist_version() {
    # Print the <string> that follows the CFBundleShortVersionString key. Pure bash: no PlistBuddy, so
    # this also runs on Linux.
    local line found=0
    [ -f "$plist" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$found" = 1 ] && [[ "$line" =~ \<string\>([^<]*)\</string\> ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return 0
        fi
        case "$line" in *"<key>CFBundleShortVersionString</key>"*) found=1 ;; esac
    done <"$plist"
}

last_tag="$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null || true)"
if [ -n "$last_tag" ]; then
    previous="${last_tag#v}"
    range="$last_tag..HEAD"
else
    previous="$(plist_version)"
    range="HEAD"
fi
[ -n "$previous" ] || previous="0.0.0"

if [[ ! "$previous" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    echo "next-version: cannot parse previous version '$previous'" >&2
    exit 65
fi
major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"

if [ "$mode" = previous ]; then
    printf '%s\n' "$major.$minor.$patch"
    exit 0
fi

# A conventional header, optionally as a "* " / "- " bullet (GitHub squash-merge bodies list the branch's
# commits that way). Groups: 1 type, 2 "(scope)", 3 scope, 4 "!", 5 description.
header_re='^[*-]?[[:space:]]*([a-zA-Z]+)(\(([^)]*)\))?(!)?:[[:space:]]+(.+)$'
breaking_re='^BREAKING[ -]CHANGE:[[:space:]]*(.*)$'

bump=0 # 0 none, 1 patch, 2 minor, 3 major
breaking_notes=""
feature_notes=""
fix_notes=""
other_notes=""
seen=$'\n'

add_note() { # bucket "text (sha)"
    # De-duplicate on the text without the SHA: a merge commit's body often repeats its branch's commits.
    local entry="$1|${2% (*)}"
    case "$seen" in *$'\n'"$entry"$'\n'*) return 0 ;; esac
    seen="$seen$entry"$'\n'
    case "$1" in
        breaking) breaking_notes="$breaking_notes- $2"$'\n' ;;
        feat) feature_notes="$feature_notes- $2"$'\n' ;;
        fix) fix_notes="$fix_notes- $2"$'\n' ;;
        *) other_notes="$other_notes- $2"$'\n' ;;
    esac
}

# Records: short sha \x1f full message \x1e
while IFS= read -r -d $'\x1e' record; do
    record="${record#$'\n'}"
    [ -n "$record" ] || continue
    sha="${record%%$'\x1f'*}"
    message="${record#*$'\x1f'}"
    subject="${message%%$'\n'*}"
    commit_breaking=0
    first_header=1
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        if [[ "$line" =~ $breaking_re ]]; then
            commit_breaking=1
            add_note breaking "${BASH_REMATCH[1]:-$subject} ($sha)"
            continue
        fi
        [[ "$line" =~ $header_re ]] || continue
        type="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
        scope="${BASH_REMATCH[3]}"
        bang="${BASH_REMATCH[4]}"
        desc="${BASH_REMATCH[5]}"
        # Only lines that look like real commit headers count; ignore prose such as "Note: ..." by
        # requiring a known type.
        case "$type" in
            feat | fix | perf | docs | chore | ci | test | tests | style | refactor | build | revert) ;;
            *) continue ;;
        esac
        text="$desc"
        [ -n "$scope" ] && text="**$scope:** $desc"
        text="$text ($sha)"
        if [ -n "$bang" ]; then
            commit_breaking=1
            add_note breaking "$text"
        fi
        case "$type" in
            feat)
                [ "$bump" -ge 2 ] || bump=2
                add_note feat "$text"
                ;;
            fix | perf)
                [ "$bump" -ge 1 ] || bump=1
                add_note fix "$text"
                ;;
            *)
                # Merge commits repeat their branch's commits; keep "Other" to subjects only.
                [ "$first_header" = 1 ] && [ "$line" = "$subject" ] && add_note other "$text"
                ;;
        esac
        first_header=0
    done <<<"$message"
    [ "$commit_breaking" = 1 ] && bump=3
done < <(git log --format='%h%x1f%B%x1e' "$range")

case "$bump" in
    3)
        if [ "$major" = 0 ]; then
            next="0.$((minor + 1)).0"
        else
            next="$((major + 1)).0.0"
        fi
        ;;
    2) next="$major.$((minor + 1)).0" ;;
    1) next="$major.$minor.$((patch + 1))" ;;
    *) next="" ;;
esac

if [ "$mode" = version ]; then
    [ -n "$next" ] && printf '%s\n' "$next"
    exit 0
fi

# --notes
version="${forced_version:-$next}"
version="${version#v}"
[ -n "$version" ] || version="$major.$minor.$patch"

section() { # title body
    [ -n "$2" ] || return 0
    printf '## %s\n\n%s\n' "$1" "$2"
}

if [ -n "$last_tag" ]; then
    printf 'Changes since %s.\n\n' "$last_tag"
else
    printf 'First tagged release (baseline %s from Info.plist).\n\n' "$major.$minor.$patch"
fi
section "Breaking changes" "$breaking_notes"
section "Features" "$feature_notes"
section "Fixes" "$fix_notes"
section "Other" "$other_notes"

cat <<EOF
## Install

**App:** download \`OpenClean-$version.dmg\`, open it and drag **OpenClean** onto **Applications**.
The DMG is a universal build (Apple silicon and Intel), macOS 14 or later.

OpenClean is not signed with an Apple Developer ID or notarized, so Gatekeeper blocks the first launch:

- macOS 14: right-click (or Control-click) OpenClean in Applications → **Open** → **Open**.
- macOS 15 and later: open it once, dismiss the warning, then go to System Settings → Privacy & Security
  and click **Open Anyway** next to the OpenClean message.
- Or, from Terminal: \`xattr -dr com.apple.quarantine /Applications/OpenClean.app\`

**Updating:** quit OpenClean and replace the app in Applications. Each build has a new ad-hoc
signature, so macOS forgets the old Full Disk Access grant: in System Settings → Privacy & Security →
Full Disk Access, remove OpenClean with **−** and add it again. The app tells you when this is needed.

**CLI:** download \`openclean-cli-$version.zip\`, unzip it and run \`openclean-cli/bin/openclean\`, or
install it:

\`\`\`sh
unzip openclean-cli-$version.zip
xattr -dr com.apple.quarantine openclean-cli
sudo mkdir -p /usr/local/bin /usr/local/share/openclean
sudo cp openclean-cli/bin/openclean /usr/local/bin/
sudo cp -R openclean-cli/share/openclean/rules /usr/local/share/openclean/
\`\`\`

**Verify downloads:** \`shasum -a 256 -c SHA256SUMS.txt\` in the folder holding the assets.
EOF
