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
make dist VERSION=x.y.z ARCH_FLAGS="--arch arm64 --arch x86_64"   # release zips (what CI's release job runs)
swift run openclean scan         # CLI against your real home — read-only; `clean` is NOT
```

- CLI integration tests (`Apps/openclean-cli/Tests`) execute the built binary at `.build/debug/openclean`, so run `swift build` before `swift test` after changing CLI code, or they test a stale binary.
- Golden JSON files (`Apps/openclean-cli/Tests/OpenCleanCLITests/Golden/`) are the `--json` contract. Re-record with `OPENCLEAN_RECORD_GOLDEN=1 swift test --filter JSONReportTests`, then review the diff by hand.
- Dev overrides honoured by `OpenCleanCoordinator`: `OPENCLEAN_HOME` (pretend home; also moves the quarantine/settings dir) and `OPENCLEAN_RULES_DIR` (bundled rule packs). Use them to run the CLI against a temp home.
- CI (`.github/workflows/ci.yml`, macos-15) runs build, test, `make lint`, `make app`. Pushing a `v*` tag runs the release workflow and publishes zips.

## Architecture

One SwiftPM package at the repo root. All logic lives in library targets under `Packages/OpenCleanKit/Sources/`; these must never import SwiftUI or AppKit. Front ends are thin:

```
RuleKit ─┬─ ScanEngine ─┬─ Probes
         │              └─ Quarantine ── Privilege ── ProcessKit
         └──────────────── OpenCleanKit (OpenCleanCoordinator facade) ── Permissions
                              ├─ Apps/openclean-cli  (OpenCleanCLI lib + `openclean` exe)
                              └─ Apps/OpenClean      (OpenCleanAppModel lib + OpenCleanApp SwiftUI exe)
```

Pipeline: `RuleCatalog` loads + lints YAML packs (`Rules/` and `~/Library/Application Support/OpenClean/rules/`; a pack with any lint issue is skipped whole) → `ScanEngine` runs every rule concurrently (path rules via `PathRuleScanner`/`ItemBuilder`, logic-heavy targets via `Probe`s) and removes cross-rule overlaps → `CleanupPlan` (selection; report-only items can never be in it) → `Remover` → session manifest in `Quarantine/<session-id>/`. `RestoreService` and `Purger` work from those manifests. `OpenCleanCoordinator` wires this together and is the only thing the CLI and `AppModel` call.

Rule semantics: `safety: regenerable` = selected by default and deleted immediately; `review` = user opts in, quarantined (restorable, retention 1–90 days, default 7); `caution` = hidden unless Advanced and, in the CLI, must also be named with `--rule`. `requires: admin` is only legal on regenerable/immediate rules. See CONTRIBUTING.md for the pack format.

## Safety invariants (do not weaken)

This tool deletes users' files; most of the code exists to make that fail closed. When changing anything on the deletion path, preserve these:

- **Only `Quarantine` and `Privilege` may remove files.** `RemovalGuardTests` scans every other module and all of `Apps/` for `removeItem(`, `trashItem(`, `unlink(`, `unlinkat(`, `rmdir(`, `removefile(`, `recycle(`, `/bin/rm`. Don't add exceptions.
- **Path comparisons are byte-level and canonical.** Never use `String.hasPrefix` / `split(separator: "/")` for path containment — grapheme clusters let `/` + combining mark slip through. Use RuleKit `pathIsWithin`, `canonicalPathKey`, `canonicalAncestorKeys`, `hasNonCanonicalComponent` (case-folded + NFD UTF-8 bytes, `/` = 0x2F).
- **Scan items carry `realpath`'d paths**, and every safety check uses the resolved home (`OpenCleanCoordinator.resolvedHome`, `ScanContext.home`). Mixing resolved and unresolved forms silently disables `DenyList` protections.
- **`DenyList`** (System, home, Documents, Desktop, Keychains, Mail, Mobile Documents, `.ssh`, `.gnupg`, OpenClean's own support dir, `/private/etc`, `/private/var/db`, app bundles, Photos libraries, and any ancestor of these) is enforced by the linter, at scan time, and again in `PreDeleteChecker` just before removal.
- **Pre-delete checks skip, never fail open:** changed inode/mtime/owner, open files (`lsof -F0n`; if `lsof` fails, everything is skipped), app running, deny-listed.
- **Root deletion** goes only through a typed `RemovalCommand` built by `AdminCommandBuilder` (canonical absolute paths, single-quoted after `--`), one osascript admin prompt per session, and only when every ancestor folder is root-protected (`Remover.systemParentIsProtected`). The CLI drops admin items when stdin isn't a TTY unless `--allow-admin`.
- **Manifests are untrusted input.** Session ids must equal their folder name and be a single safe component; restore/purge only act on paths contained in that session's `items/` (or a Trash). `Remover` writes intent to the manifest before acting.
- **`ProcessCommandRunner`** must not use the global dispatch queues (starvation hangs were observed); it uses a dedicated `Thread` + private serial queue and a 60 s default timeout. The osascript executor uses no timeout (a human types the password).
- **CLI contract:** JSON carries `"schema": 1` and omits nil keys; exit codes are 0 success, 1 error/aborted, 2 finished with skipped items; `clean` refuses without `--yes` on a non-TTY and refuses `--json` without `--yes`/`--dry-run`.
- **App:** `AppModel` only cleans from `.results`; changing exclusions/Advanced bumps `settingsGeneration`, which discards in-flight or stale results (exclusions are honoured at scan time only).

## Tests

Swift Testing (`import Testing`, `#expect`). Tests must never touch the real home, Trash, LaunchAgents or an admin prompt:

- Filesystem tests use `TestSupport.TempDirectory`; inject fakes from `TestSupport` (`FakeProcessChecker`, `FakeCommandRunner`, `FakeAdminExecutor`, `FakeOpenFiles`, `FixtureRules`).
- CLI integration tests use `CLIFixtures.withHome { home, env in … }`; `CLIBinary.run` refuses to start unless `OPENCLEAN_HOME` is inside the temp directory, and it also overrides `HOME`.
- Some tests run real `lsof`, `/bin/sh`, and `osascript -e 'return …'` (never with administrator privileges).

## Project conventions

- Design docs live in `docs/superpowers/specs/`, implementation plans in `docs/superpowers/plans/`. v1 is four sub-projects; #1 (core + cleanup + Smart Scan) is done. Next: #2 Uninstaller + leftovers, #3 Space Lens + large/old/duplicates, #4 Performance + menu bar. The sidebar already shows these as "Coming soon".
- Clean-room: the feature set was informed by CleanMyMac metadata and UI strings only. Never decompile, copy, or reference MacPaw code, binaries, rule data or assets.
- Commits use Conventional Commits (`feat(scan): …`, `fix(quarantine): …`). The repo has a local git identity (`leoAnimesh`) and a repo-local credential helper for pushing as `leoAnimesh`; don't change them.
