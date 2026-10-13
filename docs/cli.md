# Command line

The `openclean` command-line tool does the same work as the app, for scripts and Terminal users.
Install it with `brew install leoanimesh/openclean/openclean`, or take `openclean-cli-X.Y.Z.zip` from the
[latest release](https://github.com/leoAnimesh/OpenClean/releases/latest).

```sh
openclean scan                          # what can be removed, nothing is touched
openclean scan --category developer --json
openclean clean --dry-run               # show the plan
openclean clean --yes                   # remove regenerable items
openclean clean --yes --include-review  # also quarantine review items
openclean history
openclean restore <session-id>
openclean rules list | explain xcode.derived-data | lint my-pack.yaml
openclean schedule purge --daily        # optional daily purge of expired quarantine

openclean apps list [--json]            # installed apps, their leftovers and sizes (read-only)
openclean apps uninstall com.example.app --dry-run
openclean apps uninstall com.example.app --yes   # app + bundle-id leftovers to quarantine
openclean space large --min-size 500MB --older-than 180 [--json]   # read-only
openclean space duplicates [--json]     # identical files in Downloads, Desktop, Documents, Pictures, Movies, Music
openclean performance [--json]          # CPU/memory snapshot and the heaviest apps (read-only)
```

Exit codes: `0` success, `1` error or aborted, `2` finished but some items were skipped.

`openclean clean --json` requires `--yes` or `--dry-run`, so scripted runs never clean by accident.
When `openclean clean` is not run from a terminal, system items that need the administrator password are
skipped (with a note on stderr) unless you pass `--allow-admin`.

`openclean apps uninstall` follows the same rules: it asks before moving anything (or needs `--yes`; it
refuses on a non-terminal without it), `--json` needs `--yes` or `--dry-run`, and an app owned by the system
(which needs your administrator password) is refused when not run from a terminal unless you pass
`--allow-admin`. Leftovers named after the bundle identifier are moved with the app; ones matched only by
the app's name stay unless you add `--include-name-matches`, and items in `/Library` always stay. The
whole uninstall is one quarantine session, so `openclean restore <session-id>` brings it back. If several
apps share a bundle identifier, pick one with `--path`. `space` and `performance` never remove or quit
anything; use the app to move files to the Trash or quit processes.

The CLI is English-only on purpose: its text output and `--json` are a stable contract for scripts.
