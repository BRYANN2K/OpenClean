# AGENTS.md

Guidance for coding agents working in OpenClean: an open-source, transparent macOS cleaner (Swift 6, SwiftPM, macOS 14+, GPL-3.0). This file is the single source of agent instructions; `CLAUDE.md` imports it.

## Commands

```sh
swift build                      # debug build of everything (CLI, app, libraries)
swift test                       # full suite (Swift Testing)
swift test --filter RuleKitTests                 # one test target
swift test --filter DenyListTests                # one suite
swift test --filter "PreDeleteCheckerTests/skipsMissingItem"   # one test
make lint                        # swift format lint --strict + `openclean rules lint Rules/*.yaml`
swift format --in-place --recursive Package.swift Packages Apps   # fix formatting (config: .swift-format)
make app                         # build/OpenClean.app (release, ad-hoc signed); `open build/OpenClean.app`
make release-assets VERSION=x.y.z ARCH_FLAGS="--arch arm64 --arch x86_64"   # DMG + CLI zip + SHA256SUMS (what CI's release job runs)
bash scripts/tests/test-next-version.sh   # tests for the auto-versioning script
swift run openclean scan         # CLI against your real home — read-only; `clean` is NOT
```

- CLI integration tests (`Apps/openclean-cli/Tests`) execute the built binary at `.build/debug/openclean`, so run `swift build` before `swift test` after changing CLI code, or they test a stale binary.
- Golden JSON files (`Apps/openclean-cli/Tests/OpenCleanCLITests/Golden/`) are the `--json` contract. Re-record with `OPENCLEAN_RECORD_GOLDEN=1 swift test --filter JSONReportTests`, then review the diff by hand.
- Dev overrides honoured by `OpenCleanCoordinator`: `OPENCLEAN_HOME` (pretend home; also moves the quarantine/settings/Updates dir), `OPENCLEAN_RULES_DIR` (bundled rule packs) and `OPENCLEAN_UPDATE_FEED` (a URL or absolute path to a JSON file shaped like GitHub's `releases/latest` response; enables `file://` for the feed and its asset links, while https still must be on the GitHub allowlist). Use them to run the CLI against a temp home, or to test Software Update locally: build a fake newer DMG (`make dmg VERSION=9.9.9` — rebuilds `build/OpenClean.app`, so check nothing is running it), write `SHA256SUMS.txt` with `shasum -a 256`, point a feed's `browser_download_url`s at them with `file://`, and launch a copy of the app outside the repo (a `build/` app counts as a development build and is never replaced in place).
- CI (`.github/workflows/ci.yml`, macos-15) runs build, test, `make lint`, `make app` and the versioning-script tests. Every push to `main` runs `.github/workflows/release.yml`: `scripts/next-version.sh` derives the next version from Conventional Commits since the last `vX.Y.Z` tag (fix/perf → patch, feat → minor, breaking → major; minor while 0.x; docs/chore-only → no release), then it builds the universal DMG + CLI zip, tags, and publishes a GitHub release. Commit types therefore decide versions — pick them carefully. `make release-assets` stamps `Version.swift` (CLI) and the bundle's Info.plist with the version.

## Architecture

One SwiftPM package at the repo root. All logic lives in library targets under `Packages/OpenCleanKit/Sources/`; these must never import SwiftUI or AppKit. Front ends are thin:

```
RuleKit ─┬─ ScanEngine ─┬─ Probes
         │              └─ Quarantine ── Privilege ── ProcessKit
         ├──────────────── Updater (release feed, download + SHA-256, DMG staging; never deletes) ── ProcessKit
         └──────────────── OpenCleanKit (OpenCleanCoordinator facade) ── Permissions
                              ├─ Apps/openclean-cli  (OpenCleanCLI lib + `openclean` exe)
                              └─ Apps/OpenClean      (OpenCleanAppModel lib + OpenCleanApp SwiftUI exe)
```

Pipeline: `RuleCatalog` loads + lints YAML packs (`Rules/` and `~/Library/Application Support/OpenClean/rules/`; a pack with any lint issue is skipped whole) → `ScanEngine` runs every rule concurrently (path rules via `PathRuleScanner`/`ItemBuilder`, logic-heavy targets via `Probe`s) and removes cross-rule overlaps → `CleanupPlan` (selection; report-only items can never be in it) → `Remover` → session manifest in `Quarantine/<session-id>/`. `RestoreService` and `Purger` work from those manifests. `OpenCleanCoordinator` wires this together and is the only thing the CLI and `AppModel` call.

Software Update (`Coordinator+Updates.swift`, `UpdateModel`): `ReleaseFeed` reads `api.github.com/repos/leoAnimesh/OpenClean/releases/latest` → `UpdateDownloader` fetches `OpenClean-X.Y.Z.dmg` into `<support>/Updates/X.Y.Z/` and checks it against the release's `SHA256SUMS.txt` → `UpdateInstaller` mounts it read-only, `ditto`s OpenClean.app into a `staged-*` folder and checks bundle id, version and `codesign --verify --deep --strict` → Quarantine's `SelfUpdateReplacer` moves the running app into a quarantine session (`update.previous-version`) and the staged app into its place → the app relaunches via a detached `/bin/sh` helper. Update preferences (auto-check, on by default; last check; skipped version) live in `UserDefaults` via `UpdateSettingsStore`, not `settings.json`, because the CLI never updates itself.

Rule semantics: `safety: regenerable` = selected by default and deleted immediately; `review` = user opts in, quarantined (restorable, retention 1–90 days, default 7); `caution` = hidden unless Advanced and, in the CLI, must also be named with `--rule`. `requires: admin` is only legal on regenerable/immediate rules. See CONTRIBUTING.md for the pack format.

## Safety invariants (do not weaken)

This tool deletes users' files; most of the code exists to make that fail closed. When changing anything on the deletion path, preserve these:

- **Only `Quarantine` and `Privilege` may remove files.** `RemovalGuardTests` scans every other module and all of `Apps/` for `removeItem(`, `trashItem(`, `unlink(`, `unlinkat(`, `rmdir(`, `removefile(`, `recycle(`, `/bin/rm`. Don't add exceptions. Software Update follows this too: `Updater` never deletes; stale downloads and staging folders are removed only by Quarantine's `UpdateStagingCleaner` (direct children of the resolved `<support>/Updates/`, never through a symlink).
- **Self-update** moves the running app only through Quarantine's `SelfUpdateReplacer`: the current app must be an absolute, canonical, symlink-free `.app` with OpenClean's bundle id, not under `/AppTranslocation/`, not a development build (`.build/` or `<repo>/build/`), on a writable volume, writable by the user and on the same volume as the quarantine store; the staged app must be inside `<support>/Updates/` with the same bundle id. Intent is written to the manifest first; a failed install move puts the old app back. Updater network access is limited to HTTPS `api.github.com`, `github.com`, `objects.githubusercontent.com`, `release-assets.githubusercontent.com` (checked on every request and redirect; `file://` only with `OPENCLEAN_UPDATE_FEED`). `SHA256SUMS.txt` comes from the same release, so it proves integrity, not authorship.
- **Path comparisons are byte-level and canonical.** Never use `String.hasPrefix` / `split(separator: "/")` for path containment — grapheme clusters let `/` + combining mark slip through. Use RuleKit `pathIsWithin`, `canonicalPathKey`, `canonicalAncestorKeys`, `hasNonCanonicalComponent` (case-folded + NFD UTF-8 bytes, `/` = 0x2F).
- **Scan items carry `realpath`'d paths**, and every safety check uses the resolved home (`OpenCleanCoordinator.resolvedHome`, `ScanContext.home`). Mixing resolved and unresolved forms silently disables `DenyList` protections.
- **`DenyList`** (System, home, Documents, Desktop, Keychains, Mail, Mobile Documents, `.ssh`, `.gnupg`, OpenClean's own support dir, `/private/etc`, `/private/var/db`, app bundles, Photos libraries, and any ancestor of these) is enforced by the linter, at scan time, and again in `PreDeleteChecker` just before removal.
- **Pre-delete checks skip, never fail open:** changed inode/mtime/owner, open files (`lsof -F0n`; if `lsof` fails, everything is skipped), app running, deny-listed.
- **Root deletion** goes only through a typed `RemovalCommand` built by `AdminCommandBuilder` (canonical absolute paths, single-quoted after `--`), one osascript admin prompt per session, and only when every ancestor folder is root-protected (`Remover.systemParentIsProtected`). The CLI drops admin items when stdin isn't a TTY unless `--allow-admin`.
- **Root app moves (Uninstaller)** go only through Privilege's typed `AppBundleAdminMove`, run by an `AppBundleAdminExecutor` (one osascript prompt per uninstalled app). Root never touches the quarantine destination (it is in a folder the user can write). The script (every value single-quoted, no user text) is exactly: `mkdir -m 700` a fresh `<T>` = `/private/var/tmp/openclean-uninstall.<uuid>` (fails if the name exists) → `mv -n` the bundle to `<T>/<name>` (on failure `rmdir <T>`) → check `stat -f %d:%i` equals the device:inode validated at construction → `find <T>/<name> ( -type d -o ( -type f -o -type l ) -links 1 ) -exec chown -h -- <uid>:<gid> {} +` → `chown -h` `<T>` to the user. Then `finishAsUser()` (as the user, no root) checks the staged bundle is the same device:inode and user-owned, `renamex_np(RENAME_EXCL)`s it to `<session>/items/<n>/<same name>` (fails if anything is there) and `rmdir`s `<T>`; if that fails, the bundle is left in `<T>` (user-owned) and the failure says where. Limits, by design: files with more than one hard link stay root-owned (they could be links to files elsewhere); source, `/private/var/tmp` and the session must be on one volume (else construction throws `differentVolume`, so `mv` never copies); the executor refuses to prompt unless the bundle is sealed (`sealProblem`: no folder in it is owned or writable by the user, so it can't change while root chowns). Construction throws unless the source is canonical, has no symlink in any component, is a `.app` directory directly inside an allowed Applications folder, is not under `/System`, is not OpenClean (bundle id or protected path) and its on-disk `CFBundleIdentifier` equals the listed one and isn't `com.apple.*`; the destination must be `<session>/items/<n>/<same name>`, not exist yet, with the items folder and the parent canonical and symlink-free; the uid is the current non-root user. It can't delete anything but its own empty staging folder, never writes outside that folder and the session's `items/`, and never touches `/Library` leftovers or privileged helpers (still report-only). It is used only for request 0 of an uninstall whose app is `.needsAdministrator`: `UninstallService` runs every usual check first (the exemption drops only "not root-owned / writable by you"), `Remover` writes intent before the prompt, decides the outcome from disk afterwards (the original bundle — same device:inode — as a real directory at the destination = `quarantined`, else `failed`; a cancelled prompt is `failed` with `adminCancelled`), and moves leftovers only after the bundle reached quarantine (otherwise `skipped`, `appNotMoved`). The quarantined copy is user-owned, so restore and purge run without root; a restored app comes back owned by the user, not root (restoring into `/Applications` needs a user in the admin group). `OpenCleanCoordinator.bundleAdmin` defaults to `admin` when it conforms, so tests that inject `FakeAdminExecutor` can never reach a real prompt.
- **Manifests are untrusted input.** Session ids must equal their folder name and be a single safe component; restore/purge only act on paths contained in that session's `items/` (or a Trash). `Remover` writes intent to the manifest before acting.
- **`ProcessCommandRunner`** must not use the global dispatch queues (starvation hangs were observed); it uses a dedicated `Thread` + private serial queue and a 60 s default timeout. The osascript executor uses no timeout (a human types the password).
- **CLI contract:** JSON carries `"schema": 1` and omits nil keys; exit codes are 0 success, 1 error/aborted, 2 finished with skipped items; `clean` refuses without `--yes` on a non-TTY and refuses `--json` without `--yes`/`--dry-run`.
- **App:** `AppModel` only cleans from `.results`; changing exclusions/Advanced bumps `settingsGeneration`, which discards in-flight or stale results (exclusions are honoured at scan time only).

## Tests

Swift Testing (`import Testing`, `#expect`). Tests must never touch the real home, Trash, LaunchAgents or an admin prompt:

- Filesystem tests use `TestSupport.TempDirectory`; inject fakes from `TestSupport` (`FakeProcessChecker`, `FakeCommandRunner`, `FakeAdminExecutor`, `FakeOpenFiles`, `FixtureRules`, `FakeHTTPClient`, `TempDirectory.fakeApp`).
- Update tests never use the network, real `hdiutil` or the running app: use `FakeHTTPClient` (canned responses by URL), fake app bundles in temp dirs, and a fake `UpdateInstalling` in `UpdateModelTests`.
- CLI integration tests use `CLIFixtures.withHome { home, env in … }`; `CLIBinary.run` refuses to start unless `OPENCLEAN_HOME` is inside the temp directory, and it also overrides `HOME`.
- Some tests run real `lsof`, `/bin/sh`, and `osascript -e 'return …'` (never with administrator privileges).

## Project conventions

- Design docs live in `docs/superpowers/specs/`, implementation plans in `docs/superpowers/plans/`. v1 is four sub-projects; #1 (core + cleanup + Smart Scan) is done. Next: #2 Uninstaller + leftovers, #3 Space Lens + large/old/duplicates, #4 Performance + menu bar. The sidebar already shows these as "Coming soon".
- UI work follows the design system in `.claude/skills/openclean-design/SKILL.md` (tokens and components in `Apps/OpenClean/Sources/OpenCleanApp/Theme.swift`; `make icon` regenerates the app icon). No XP, levels, streaks or milestones: the app shows facts only.
- Clean-room: the feature set was informed by CleanMyMac metadata and UI strings only. Never decompile, copy, or reference MacPaw code, binaries, rule data or assets.
- Commits use Conventional Commits (`feat(scan): …`, `fix(quarantine): …`). The repo has a local git identity (`leoAnimesh`) and a repo-local credential helper for pushing as `leoAnimesh`; don't change them.
