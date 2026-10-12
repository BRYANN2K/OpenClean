# OpenClean — Sub-project 1: Core + Cleanup + Smart Scan

- **Date:** 2026-10-12
- **Status:** Draft for review
- **License:** GPL-3.0
- **Repo:** github.com/leoAnimesh/OpenClean

## 1. Context and goals

OpenClean is an open-source macOS cleaner intended as a serious, community-maintained alternative to CleanMyMac. The feature set was derived from a clean-room inspection of CleanMyMac 5.7.1 (Mac App Store build) using REA: bundle metadata, entitlements and user-facing strings only. No MacPaw code, binaries, or assets were decompiled, copied, or reused.

### What "better than CleanMyMac" means here

| CleanMyMac (observed) | OpenClean |
|---|---|
| Sandboxed MAS build; needs per-folder grants | Non-sandboxed build-from-source; Full Disk Access + admin prompt |
| Most removals permanent | Staged quarantine with restore and history |
| Opaque cleaning logic | Declarative YAML rules, each with an explanation, visible in UI |
| Fixed rule set, updated by vendor | Community rule packs, linted in CI; user packs supported |
| Analytics, upsell, account flows | No telemetry, no network access, no upsell |
| GUI only (CLI app group present but not public) | GUI + scriptable CLI sharing one core |
| Generic junk focus | First-class developer and AI-tool cache cleanup |

### v1 roadmap (each sub-project has its own spec → plan → build)

1. **Core + Cleanup + Smart Scan** — this document.
2. Uninstaller + app leftovers.
3. Space Lens + large/old files + duplicates.
4. Performance tasks + menu bar monitor.

### Non-goals for this sub-project

- Malware scanning, privacy cleanup, cloud/email cleanup (CleanMyMac features deliberately out of v1).
- Uninstaller, Space Lens, duplicates, performance tasks, menu bar (later sub-projects; sidebar shows "Coming soon").
- Code signing, notarization, privileged helper (distribution is unsigned/build-from-source).
- Localization beyond English (strings are localizable-ready via String Catalogs).

## 2. Constraints

- macOS 14 (Sonoma) minimum; Apple Silicon and Intel.
- Swift 6 language mode, SwiftUI + Observation.
- Unsigned / ad-hoc signed builds. Consequences:
  - No `SMAppService` privileged helper. Root-owned paths use a one-shot admin prompt.
  - Full Disk Access (TCC) grants are tied to the code signature and reset after each rebuild; the app must detect and explain this.
- No network access in v1.

## 3. Architecture

Single Swift package for the core; GUI and CLI are thin front ends over it.

```
OpenClean/
├─ Packages/OpenCleanKit/          SwiftPM library, no UI imports
│  ├─ RuleKit        load + validate YAML rule packs → typed Rule models
│  ├─ ScanEngine     concurrent filesystem walk, apply rules → ScanResult
│  ├─ Probes         Swift plugins for logic-heavy targets
│  ├─ Quarantine     the ONLY module allowed to remove files
│  ├─ Privilege      admin-prompt runner for root-owned regenerable paths
│  └─ Permissions    Full Disk Access detection and guidance
├─ Rules/                          bundled community YAML packs
├─ Apps/OpenClean/                 SwiftUI app
├─ Apps/openclean-cli/             CLI (swift-argument-parser)
└─ docs/
```

### Data flow

1. **Load:** RuleKit loads bundled packs and user packs from `~/Library/Application Support/OpenClean/rules/`. Invalid packs are rejected with a reported reason; valid packs still load.
2. **Scan:** ScanEngine evaluates path rules; Probes evaluate probe rules. Output is `ScanResult`: category → rule → items. Each item carries resolved path, allocated size, rule id, and the rule's `explain`.
3. **Select:** user (GUI) or flags (CLI) choose items. Defaults come from rule safety level.
4. **Review:** a summary of what will be removed, by delete mode, including items needing admin rights. Mandatory in GUI; mandatory in CLI unless `--yes`.
5. **Remove:** Quarantine performs pre-delete checks, then deletes immediately or quarantines, and writes a session manifest.

### Module boundaries

- Only `Quarantine` and `Privilege` may call file-removal APIs (`removeItem`, `trashItem`, `unlink`, `/bin/rm`), and `Privilege` is invoked only by `Quarantine`. Enforced by a guard test that scans sources of every other module.
- Probes return items; they cannot remove.
- No module in `OpenCleanKit` imports SwiftUI or AppKit UI types.

## 4. Rule format

```yaml
pack: dev-tools
version: 1
rules:
  - id: xcode.derived-data
    name: Xcode DerivedData
    category: developer
    explain: Build intermediates Xcode regenerates on next build.
    paths:
      - ~/Library/Developer/Xcode/DerivedData/*
    safety: regenerable
    conditions:
      app_not_running: com.apple.dt.Xcode
    delete_mode: immediate
```

### Fields

| Field | Required | Notes |
|---|---|---|
| `pack`, `version` | yes | `version` is the schema version; v1 only. |
| `id` | yes | Globally unique, dotted. Duplicate ids fail lint. |
| `name`, `explain` | yes | Shown in UI/CLI. `explain` must state why removal is safe. |
| `category` | yes | `system`, `user`, `browsers`, `developer`, `ai`, `mail`, `trash`, `ios`. |
| `paths` XOR `probe` | yes | Globs (`~` expanded; `*`, `**`, `?`), or a registered probe id. |
| `safety` | yes | `regenerable`, `review`, `caution`. |
| `delete_mode` | no | `immediate` or `quarantine`; default from safety (see below). |
| `conditions` | no | See below. |
| `exclude` | no | Globs removed from matches. |
| `requires` | no | `full_disk_access`, `admin`. |

### Conditions

- `app_not_running: <bundle id>` (one or a list): rule is skipped (reported) while the app runs.
- `min_age_days: N`: item's modification date must be older than N days.
- `min_size: <bytes or "10MB">`: item must be at least this size.

### Safety levels

| Level | Default selected | Default delete mode | Visibility |
|---|---|---|---|
| `regenerable` | yes | immediate | always |
| `review` | no | quarantine | always |
| `caution` | no | quarantine | only with Settings → Advanced |

Rules with `requires: admin` must be `regenerable` (no root-owned data is ever quarantined); lint enforces this.

### Hard deny-list (in Swift, not overridable by rules)

A matched path is rejected if it is, or is inside, any of:
`/System`, `/bin`, `/sbin`, `/usr` (except `/usr/local`), `/Applications/*.app` and `~/Applications/*.app` bundles, `~/Documents`, `~/Desktop`, `~/Pictures/*.photoslibrary`, `~/Library/Keychains`, `/Library/Keychains`, `~/Library/Mobile Documents` (root itself), `~/Library/Mail` (except `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads`), the user home directory itself, and `/`.

A path is also denied when it contains a protected location (for example `~/Library`, `/Library`, `/Users`), and `~/Library/Mobile Documents` is protected as a whole subtree. Rules whose glob literal prefix falls in the deny-list fail lint. At scan time, every resolved match is re-checked.

### Path resolution

- Symlinks are never followed during traversal. Each match is resolved to its real path and must remain under the glob's literal prefix; otherwise it is dropped and reported.
- Sizes use allocated blocks (`st_blocks`), so sparse files do not inflate freed-space numbers. Hard-linked files are counted once per scan (deduplicated by device + inode). APFS clones are counted at full allocation: macOS has no public API for shared-block accounting, so freed space may be overstated for cloned files.

### Probes

```swift
public protocol Probe: Sendable {
    static var id: String { get }
    func scan(_ context: ScanContext) async throws -> [ScanItem]
}
```

v1 probes: `xcode.simulators` (unavailable simulator devices via `xcrun simctl list --json`), `docker.disk-image` (report only: Docker Desktop disk image size, with a hint to run `docker system prune`; never deletes Docker data), `homebrew.cache` (`brew --cache`), `timemachine.local-snapshots` (report only in this sub-project). Probe output passes the same deny-list and resolution checks as path rules.

`ScanItem` has a `reportOnly` flag. Report-only items are shown with their size and hint but are never selectable or removable, in GUI or CLI.

### Bundled v1 packs

`system` (system caches/logs, root-owned → `requires: admin`), `user-caches`, `browsers` (Safari, Chrome, Firefox, Arc caches only — never history, cookies, or profiles), `dev-tools` (Xcode DerivedData/Archives (review)/DeviceSupport, simulators, npm, yarn, pnpm, pip, Cargo registry cache, Gradle caches, CocoaPods cache, Homebrew, Docker probe), `ai` (Ollama models, LM Studio models, Hugging Face hub cache — all `review`), `mail` (Mail Downloads), `trash` (user Trash), `ios` (iOS device backups — `review`, `min_age_days: 90`).

## 5. Scan engine

- One task per rule inside a `TaskGroup`; filesystem enumeration with `FileManager.enumerator` using prefetched resource keys (`fileAllocatedSize`, `totalFileAllocatedSize`, `contentModificationDate`, `isSymbolicLink`, `fileResourceIdentifier`).
- Progress reported per rule as an `AsyncStream<ScanProgress>`.
- Cancellable at any time; cancellation returns partial results marked incomplete.
- Permission errors are collected per rule (not fatal); rules with `requires: full_disk_access` and no FDA are reported as `needsFullDiskAccess` without scanning.
- Results are immutable value types snapshotting path, inode, size, and modification date for the pre-delete checks.

## 6. Quarantine, removal, and history

### Storage

- Root: `~/Library/Application Support/OpenClean/Quarantine/<session-id>/`.
- Same-volume items are moved by rename into the session folder, preserving permissions, xattrs, and timestamps.
- Items on other volumes go to that volume's Trash via `FileManager.trashItem`; the manifest records the trash location.
- `manifest.json` per session: session id, timestamp, entries `{originalPath, storedPath, size, ruleId, mode, outcome, skipReason?}`.

### Pre-delete checks (per item, at removal time)

Skip and record the reason if:
1. The item no longer exists, or its inode or modification date differs from the scan snapshot.
2. The item is open by any process (`lsof` batched per rule; failure of `lsof` itself is treated as "unknown" and the item is skipped).
3. A rule's `app_not_running` target has started since the scan.
4. The resolved path now fails the deny-list check.

### Removal modes

- `immediate`: delete (user-owned) or batched admin delete (root-owned).
- `quarantine`: move as above.

### Root-owned paths (Privilege module)

- Only for `regenerable` rules with `requires: admin`.
- One admin prompt per cleanup session via `osascript` `do shell script … with administrator privileges`, invoking `/bin/rm -f --` / `/bin/rm -rf --` on an explicit list of already-validated absolute paths, each passed as a single-quoted argument with quotes escaped. Never a glob, never a top-level directory listed in the deny-list, never string-assembled from unvalidated input.
- Prompt cancelled → those items are recorded as skipped; the rest of the session completes.

### Restore

- Restore a whole session or individual items to their original paths.
- If the original path is occupied: ask (GUI) or `--on-conflict skip|keep-both|replace` (CLI, default `skip`).
- Missing parent directories are recreated.

### Purge

- Sessions older than retention (default 7 days, Settings-configurable 1–90) are purged at every app or CLI launch.
- Optional daily purge via `openclean schedule purge --daily`, which installs a user LaunchAgent plist in `~/Library/LaunchAgents/`; `--off` removes it. Off by default.

## 7. Permissions

- Full Disk Access detection: attempt to read a TCC-protected location (e.g. `~/Library/Safari/Bookmarks.plist` metadata, falling back to `~/Library/Containers/com.apple.stocks`); success → granted. Never assumed.
- Missing FDA: affected rules show a "Needs Full Disk Access" badge and a button that opens `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
- Rebuild detection: store the app's current code-directory hash; if it changed and FDA was previously granted but now fails, show the "build changed — re-grant access" explanation.

## 8. App UI

- Sidebar: Smart Scan, Cleanup, History, Settings; Uninstaller, Space Lens, Performance shown disabled as "Coming soon".
- **Smart Scan:** scan button → category summary cards (size, item count) → "Clean selected" → review sheet.
- **Cleanup:** three panes — categories → rules → items. Rule detail shows `explain` and safety badge; items support Reveal in Finder and Quick Look; tri-state checkboxes at every level; live total split into "freed now" and "quarantined".
- **Review sheet:** counts and sizes by delete mode, list of admin-required items, explicit Confirm. No removal path bypasses it.
- **History:** sessions with freed size, item counts, skip reasons; Restore session / Restore item.
- **Settings:** retention days, user rule pack folder (Reveal), Advanced toggle (shows `caution`), user excluded paths, FDA status.
- Keyboard navigable, VoiceOver labels on all controls, light and dark mode.
- No network access, telemetry, accounts, or upsell.

## 9. CLI

```
openclean scan [--category <c>]... [--json]
openclean clean [--category <c>]... [--rule <id>]... [--include-review] [--dry-run] [--yes]
openclean history [--json]
openclean restore <session-id> [--item <path>]... [--on-conflict skip|keep-both|replace]
openclean rules list [--json] | lint <pack.yaml>... | explain <rule-id>
openclean schedule purge --daily | --off
```

- `clean` without `--yes` prints the review summary and prompts on a TTY; with no TTY and no `--yes` it exits 1 without removing.
- `--include-review` is required to remove `review` items; `caution` items additionally need `--rule` naming them explicitly.
- JSON output carries `"schema": 1`; changes to it are versioned.
- Exit codes: `0` success, `1` error or aborted, `2` completed with skipped items.

## 10. Error handling

- Invalid rule pack: pack skipped, error reported (GUI banner, CLI stderr); other packs load.
- Per-item failures never abort a session; each is recorded in the manifest with a reason.
- Manifest written incrementally (write-then-rename) so a crash mid-session leaves a restorable record.
- Quarantine folder unreadable/corrupt manifest: session shown as "damaged" in History with Reveal in Finder; never auto-purged without the manifest's date (falls back to folder creation date).

## 11. Testing

Framework: Swift Testing. All filesystem tests run in per-test temporary directories built from fixtures; tests never touch the real home directory (the home path is injected via `ScanContext`).

- **RuleKit:** schema validation, unknown fields rejected, duplicate ids, deny-list lint, `requires: admin` must be `regenerable`, glob scoping.
- **Resolution:** symlink escaping to a fixture "Documents" is dropped; hard links counted once; APFS clone sizes via allocated size.
- **ScanEngine:** conditions (`min_age_days`, `min_size`, `exclude`, `app_not_running` via injected process checker), cancellation returns partial results, FDA-required rules reported not scanned.
- **Quarantine:** round-trip restore preserves bytes, POSIX permissions, and xattrs; restore conflicts per policy; purge honors retention; cross-volume path uses trash (via injected volume resolver); pre-delete checks skip changed/open items.
- **Privilege:** argument quoting/escaping of hostile file names (quotes, newlines, `$()`, leading `-`); executor injected so no real admin prompt runs in tests.
- **Guard test:** fails if any module other than Quarantine/Privilege references file-removal APIs.
- **CLI:** golden-file tests for `--json` outputs and exit codes.
- **Rule packs:** every bundled pack lints clean in CI.
- **Manual QA checklist** (`docs/qa-checklist.md`): admin prompt flow, FDA grant/re-grant after rebuild, VoiceOver pass.

## 12. Repository and CI

- GitHub Actions on `macos-15`: build, `swift test`, `openclean rules lint Rules/*.yaml`, SwiftFormat check — on push and pull request.
- Tag `v*` → release workflow builds the app (ad-hoc signed) and CLI, attaches a `.zip` of each.
- Install paths: `make install` (builds and copies app to `/Applications`, CLI to `/usr/local/bin`), Homebrew tap formula with `--HEAD`.
- Docs: README (features, CleanMyMac comparison, install, FDA explanation), CONTRIBUTING (including "Writing a rule"), SECURITY.md, issue templates (bug, new cleanup rule), clean-room statement.
- Commits authored as `leoAnimesh <mondalarup808@gmail.com>`.

## 13. Open questions

None blocking. Later sub-projects will extend `ScanResult` categories and reuse Quarantine for uninstall and duplicate removal.
