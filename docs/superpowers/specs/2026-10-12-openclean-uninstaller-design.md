# OpenClean — Sub-project 2: Uninstaller + app leftovers

- **Date:** 2026-10-12
- **Status:** Draft for review
- **Builds on:** `2026-10-12-openclean-core-cleanup-design.md` (rules, scan items, quarantine, deny-list)

## 1. Goals

- List installed apps with the facts a user needs to decide: name, version, size on disk, location, owner, whether it is running, and (when Spotlight knows) when it was last used.
- For one chosen app, show what it left in the user's Library, grouped by kind, each with its size and the reason it matched.
- Uninstall = move the app bundle and the ticked leftovers into OpenClean's **quarantine** as one session. History → Restore puts everything back; the normal retention purge deletes it later.
- Fail closed: anything we cannot prove is the chosen, user-owned, non-Apple app is skipped, never "best effort" removed.

## 2. Non-goals (this version)

- Removing `/Library/…` system-level leftovers or privileged helpers (report-only). Root-owned or non-writable app bundles (many App Store / pkg apps) *can* be uninstalled since the follow-up below: one administrator prompt moves the bundle into quarantine via the typed `AppBundleAdminMove` (see AGENTS.md, "Root app moves").
- Uninstalling apps in `/Applications/Utilities`, Apple apps, apps without a bundle identifier, or OpenClean itself.
- Fuzzy or substring matching of leftovers, "orphaned leftovers of apps that are already gone", running vendor uninstallers, unloading LaunchAgents (a moved agent stops at next login).
- A CLI command (the coordinator API is CLI-ready; the command is a follow-up).

## 3. Architecture

```
AppInventory (new; RuleKit, ScanEngine, ProcessKit) ── inventory + leftover finder, read-only
Quarantine/Uninstall*.swift                         ── bundle exemption + UninstallService (moves files)
OpenCleanKit/Coordinator+Uninstaller.swift           ── installedApps / leftovers / uninstall
OpenCleanAppModel/UninstallerModel.swift             ── phases, selection, search
OpenCleanApp/UninstallerView.swift (+ Uninstaller*.swift)
```

`AppInventory` never removes anything (enforced by `RemovalGuardTests`). Quarantine does not depend on `AppInventory`: the coordinator converts inventory records into `ScanItem`s.

## 4. Data model

- `ApplicationFolder { path, allowsUninstall }`. Standard set: `/Applications` (uninstall allowed), `/Applications/Utilities` (listing only), `<home>/Applications` (allowed). When the coordinator runs with a pretend home (`OPENCLEAN_HOME`, or a `home` that isn't the real one, as in tests) only `<home>/Applications` is used, so dev runs and tests never act on the real `/Applications`.
- `InstalledApp`: canonical `path`, `name`, `bundleID?`, `version?`, allocated `size` (ScanEngine `FileSizer`), `lstat` snapshot (device, inode, mtime, owner), `isRunning`, `isWritable`, `lastUsed?` and a `status`: `removable`, `appleApp`, `openClean`, `needsAdministrator`, `listOnly`, `noBundleID`.
- `Leftover`: canonical `path`, `kind` (`LeftoverKind`), `match` (`bundleID` | `name`), `scope` (`user` | `system`; system = report-only), size and snapshot.
- `UninstallOutcome`: `.refused(UninstallRefusal)` (nothing moved, no session) or `.finished(RemovalReport)`.

Inventory: one level of `*.app` entries per folder (symlinked entries are skipped, never followed), `Contents/Info.plist` read with `PropertyListSerialization`, sizes measured concurrently with progress. Running state comes from one process-table snapshot (`RunningProcessChecker.runningBundleIDs()`, or the injected `ProcessChecker`). Last-used dates come from a single batched `mdls -raw -name kMDItemLastUsedDate …` through ProcessKit with a 10 s timeout; any failure just leaves the dates empty.

## 5. Leftover matching rules

Every candidate is a direct entry of one of these folders, found by listing the folder and comparing names with canonical (case-folded, NFD) byte keys:

| Kind | `~/Library/…` | Match |
|---|---|---|
| Application Support | `Application Support/<id>` or `/<Name>` | id or exact name |
| Caches | `Caches/<id>` or `/<Name>` | id or exact name |
| Logs | `Logs/<id>` or `/<Name>` | id or exact name |
| Preferences | `Preferences/<id>.plist`, `Preferences/ByHost/<id>.<anything>.plist` | id |
| Containers | `Containers/<id>` | id |
| Group Containers | `Group Containers/<group>` where `<group>` minus a `group.` or 10-char team-id prefix equals `<id>` or starts with `<id>.` | id |
| Saved state | `Saved Application State/<id>.savedState` | id |
| HTTP storage | `HTTPStorages/<id>` (and `<id>.binarycookies`) | id |
| WebKit | `WebKit/<id>` | id |
| Application Scripts | `Application Scripts/<id>` | id |
| Launch agents | `LaunchAgents/<id>.plist`, `LaunchAgents/<id>.<anything>.plist` | id |
| Cookies | `Cookies/<id>.binarycookies` | id |

- `<Name>` is the bundle's file name without `.app` or its `CFBundleName`; at least 3 characters. Name matches are shown with "Matches name" and are **not** ticked by default; bundle-id matches are ticked.
- Never substring/fuzzy: `com.foo.app` does not match `com.foo.application` or `com.foo`.
- The same folders under `/Library` (plus `LaunchDaemons`, `PrivilegedHelperTools`) are scanned for **report-only** system leftovers.
- Each candidate must: not be a symlink; have a parent that `realpath`s to itself (no symlinked folders); be strictly within the (resolved) Library root by `pathIsWithin`; contain no `.`/`..` component; and pass `DenyList`. Bundle ids and names must be a single safe path component.

## 6. Uninstall safety

App bundles are deny-listed. `UninstallBundleExemption.authorize` builds a one-request exemption only when **all** hold, otherwise the request is refused with a reason:

1. The bundle id is a safe component, not `com.apple.*`, not OpenClean's (`com.openclean`); the path is not OpenClean's own bundle and not under `/System`.
2. The path is absolute, has no `.`/`..`, equals its own `realpath` (no symlink anywhere), is a real directory whose last component ends in `.app`, and its parent's canonical key equals one of the allowed (uninstall-enabled, resolved) application folders — i.e. a `.app` directly inside it.
3. Not root-owned; the bundle and its parent folder are writable by the user. **Exception:** for a `.needsAdministrator` app (`UninstallRequest.requiresAdministrator`) this check is dropped and the bundle is moved by `AppBundleAdminMove` (root moves it into a fresh root-only folder in `/private/var/tmp`, checks it is the same inode, chowns its folders and single-link files to the user and hands the folder over; the user then moves it into `items/0/<name>` without replacing anything — see AGENTS.md) after one password prompt; everything else in this list still applies. A cancelled or failed prompt moves nothing (entry 0 `failed`, leftovers `skipped`); leftovers move only after the bundle reached quarantine. Restored apps come back owned by the user.
4. `DenyList.denialReason` for the path is either nil or exactly `application bundle <path>`; any other denial stays in force.

The exemption is passed to that request's `PreDeleteChecker` only and `permits(path, reason)` matches the exact canonical key **and** the exact reason recorded at authorization. Paths inside the bundle, other bundles and every other deny-list entry remain protected. All the normal pre-delete checks still run on the bundle and every leftover: unchanged inode/device/mtime/owner since inventory, not open (`lsof`; failure skips), app not running (rule condition `app_not_running: <id>`).

`UninstallService` first runs the checker on the bundle alone; if it would be skipped (running, changed, in use, open files unknown) the whole request is refused and nothing moves, so leftovers are never removed for an app that stays installed. Leftovers must be strictly inside `<home>/Library`; system-scope leftovers are never accepted. Then one `Remover` session moves the bundle (entry 0, rule `uninstall.app`) and the leftovers (rule `uninstall.leftover`) into `Quarantine/<session>/items/` (or the Trash across volumes), recording intent first, so `RestoreService` and `Purger` work unchanged.

## 7. UI

Follows `.claude/skills/openclean-design`: plum `Backdrop.uninstaller`, glass panels, one round action.

- **Loading:** full screen orb inside a progress ring, "Measuring apps…", count; Stop (`.cancelAction`) returns to an empty state with "Load Apps".
- **List:** header (title, one sentence with retention days, `StatPill` with app count, search field, Refresh). Left: glass list of apps (system icon via `NSWorkspace`, name, version, size, state text: Running / Apple app / Needs administrator / Utilities). Right: detail for the selected app — facts, then leftovers grouped by kind with checkboxes (bundle row always included), match labels, sizes; report-only system leftovers below with "Needs administrator — not supported yet"; non-removable apps show the reason instead of checkboxes. Bottom bar: selected total + round glass "Uninstall" (opens confirmation).
- **Confirm sheet:** what moves to quarantine (app + N leftovers, sizes) and "restorable from History for N days" (`settings.clampedRetentionDays`). Cancel / Move to Quarantine.
- **Working:** own full screen, orb + spinning ring, never a spinner on the button.
- **Done:** checkmark orb, "<App> was moved to quarantine", sizes, skipped items with reasons, or the refusal reason; Done returns to the refreshed list.

## 8. Tests (Swift Testing, temp home only)

- Inventory on a temp home with fake bundles (`Contents/Info.plist`): fields, status (Apple, root-less writable, no bundle id, list-only folder, OpenClean), symlinked `.app` skipped, running via `FakeProcessChecker`, last-used parsing via `FakeCommandRunner`.
- Leftovers: exact id, exact name (case-insensitive), no substring/prefix matches, ByHost/LaunchAgents/Group Containers patterns, deny-list respected, symlinks not followed (entry and parent), `/Library` (injected) report-only.
- Exemption: only the requested bundle; inner paths, sibling bundles and other deny-list entries stay denied; refusals for Apple/self/outside folder/nested/symlinked/not writable.
- Uninstall moves bundle + leftovers to quarantine and `RestoreService` puts them back; running, changed and in-use apps are refused with nothing moved.
