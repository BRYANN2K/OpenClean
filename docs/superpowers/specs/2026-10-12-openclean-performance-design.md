# OpenClean — Sub-project 4: Performance + menu bar monitor

- **Date:** 2026-10-12
- **Status:** Approved scope (user decided all four parts), implementation on `feat/performance`
- **Depends on:** sub-project 1 (core, Quarantine, Privilege, ProcessKit), the app redesign (`Theme.swift`, design skill)

## 1. Goals

Performance gives a factual, low-overhead view of what the Mac is doing and a few safe, reversible levers:

1. **Menu bar monitor**: CPU, memory, disk free and network rates in a `MenuBarExtra` popover.
2. **Login items & agents**: see what starts with the Mac, who owns it, and disable/enable/remove *user* launch agents reversibly.
3. **Maintenance tasks**: a short, honest list of one-click macOS maintenance commands.
4. **Heavy consumers**: live list of the apps and processes using the most CPU and memory, with Quit / Force Quit for apps.

### Non-goals (v1)

- No "speed up" scores, health numbers, RAM "boosters". `purge` is deliberately not offered: freeing inactive memory makes the Mac slower, not faster.
- No management of other apps' `SMAppService` / Background Task Management login items (Apple offers no API); we link to System Settings instead.
- No changes to system launch agents/daemons (`/Library/LaunchAgents`, `/Library/LaunchDaemons`): listed read-only.
- No persistent background helper; nothing runs when OpenClean isn't running.
- No sampling of other users' (root, `_windowserver`) processes: `proc_pidinfo` only reports the current user's processes without privileges.

## 2. Architecture

Two new library targets plus small additive files in existing modules. Neither new target imports SwiftUI or AppKit.

```
SystemMonitor (new)  ── libproc / mach / sysctl sampling, pure delta math, process grouping, Force Quit policy
Maintenance   (new)  ── launch agent parsing, launchctl parsing + commands, owner resolution, maintenance tasks
   ├─ ProcessKit       CommandRunner (launchctl, lsregister) with timeouts
   ├─ Privilege        + Maintenance*.swift: typed allow-listed admin command enum, executor protocol
   ├─ Quarantine       + LaunchAgent*.swift: move a user launch agent plist into a quarantine session
   └─ RuleKit          canonical path helpers
OpenCleanKit         + Coordinator+Performance.swift: factories wired to the coordinator's home/quarantine
OpenCleanAppModel    PerformanceModel: sampling loop with demand counting, actions, persisted state
OpenCleanApp         PerformanceView (4 sections), MenuBar* (MenuBarExtra label + popover)
```

### 2.1 SystemMonitor

- `SystemSampler` protocol returns raw counters: `CPUTicks` (user/system/idle/nice from `host_statistics(HOST_CPU_LOAD_INFO)`), `MemorySnapshot` (`host_statistics64(HOST_VM_INFO64)` pages × page size, physical memory, `kern.memorystatus_vm_pressure_level`), `NetworkCounters` (sum of `if_data64` bytes over non-loopback interfaces from `sysctl NET_RT_IFLIST2`), `DiskSnapshot` (volume capacity for important usage), and `[ProcessSample]` (`proc_listallpids` + `proc_pidinfo(PROC_PIDTASKINFO)` + `proc_pidpath`; CPU time converted with `mach_timebase_info`).
- `MetricsCalculator` (pure): CPU % from two tick samples (handles counter wrap by treating a negative delta as zero), network bytes/s from two counter samples and the interval (interface resets yield 0, never negative), memory "used" = app memory (internal − purgeable) + wired + compressed, matching Activity Monitor.
- `ProcessUsageCalculator` (pure): per-process CPU % from CPU-time deltas, grouping by the **outermost** `.app` bundle found in the executable path (so `Google Chrome Helper (Renderer)` inside `Google Chrome.app` counts as Chrome). Top-N by CPU and by memory.
- `ForceQuitPolicy`: refuses pid ≤ 1, OpenClean's own pid, processes owned by another user, executables under `/System/`, `/usr/`, `/sbin/`, `/bin/`, `/Library/Apple/`, and a name denylist (`kernel_task`, `launchd`, `WindowServer`, `loginwindow`, `Dock`, `Finder`, `SystemUIServer`, `ControlCenter`, `NotificationCenter`, `coreaudiod`, `mds`, `mds_stores`, `cfprefsd`, `opendirectoryd`, `securityd`, `trustd`, `distnoted`, `UserEventAgent`, `OpenClean`). Quit is only offered for groups that have an app bundle; the app layer additionally requires an `NSRunningApplication` for the pid and uses only `terminate()` / `forceTerminate()`. Force Quit always asks for confirmation.

### 2.2 Maintenance: login items & agents

- **Inventory roots:** `<home>/Library/LaunchAgents` (scope `user`, actionable), `/Library/LaunchAgents` (`systemAgent`, read-only), `/Library/LaunchDaemons` (`systemDaemon`, read-only). Roots are injectable for tests; `home` comes from the coordinator (honours `OPENCLEAN_HOME`).
- **Parsing:** `PropertyListSerialization`. `Label` required (otherwise the file is listed as unreadable with the reason). `Program` wins over `ProgramArguments[0]`. `RunAtLoad` bool; `KeepAlive` bool or dictionary (dictionary = "conditionally"); `Disabled` bool. Malformed plists never throw out of the inventory: they become `unreadable` entries.
- **State:** one `launchctl list` (gui domain of the current user: covers user agents and `/Library/LaunchAgents`) and one `launchctl print-disabled gui/<uid>` per refresh, parsed defensively (unknown lines ignored; both `=> disabled|enabled` and `=> true|false` forms). Daemons: `launchctl print system/<label>` per label, exit 0 = loaded. All via `CommandRunner` with a 10 s timeout. If launchctl fails, state is "unknown", not "not loaded".
- **Owner resolution:** program path inside a `.app` → that app's name and bundle id; otherwise label equals or starts with an installed app's bundle id (case-insensitive, longest wins); otherwise the same vendor prefix (first two reverse-DNS components) → "likely" owner; otherwise unknown. Installed apps come from `/Applications` and `<home>/Applications` (top level), injectable.
- **Actions (user scope only; anything else throws `readOnly`):** labels must be non-empty, ≤ 255 bytes, and contain no `/`, NUL or control characters; the plist must be a regular, non-symlink file canonically within the user LaunchAgents directory.
  - *Disable:* `launchctl bootout gui/<uid>/<label>` (a "not loaded" failure is fine) then `launchctl disable gui/<uid>/<label>`; success requires `disable` to exit 0.
  - *Enable:* `launchctl enable gui/<uid>/<label>` then `launchctl bootstrap gui/<uid> <plist>`; success requires `enable` to exit 0; a bootstrap failure is reported as "enabled, starts at next login".
  - *Remove:* bootout (non-fatal), then `LaunchAgentQuarantine` moves the plist into a new quarantine session (manifest intent written first, same-volume `moveItem` only, never Trash, never delete). History → Restore puts it back; it loads again at next login. Retention follows the user's quarantine setting.
- **Modern login items:** listed read-only as "Background items inside apps": apps in the application folders whose bundle contains `Contents/Library/LoginItems/*.app` or `Contents/Library/LaunchAgents|LaunchDaemons/*.plist`. A button opens `x-apple.systempreferences:com.apple.LoginItems-Settings.extension`.

### 2.3 Maintenance tasks

| Task | Command (absolute paths, fixed args) | Privilege |
|---|---|---|
| Flush DNS cache | `/usr/bin/dscacheutil -flushcache` && `/usr/bin/killall -HUP mDNSResponder` | admin |
| Reindex Spotlight | `/usr/bin/mdutil -E /` | admin |
| Rebuild Launch Services database | `…/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user` | user |
| Run maintenance scripts | `/usr/sbin/periodic daily weekly monthly` (task hidden when the binary is missing, e.g. macOS 26) | admin |
| Thin Time Machine local snapshots | `/usr/bin/tmutil thinlocalsnapshots / 999999999999 4` | admin |

- Admin tasks go through `MaintenanceAdminCommand`, a `CaseIterable` enum in `Privilege` with **no associated values**: every case renders a fixed list of argv steps; each step's executable must be in a fixed allow-list of absolute paths; every argument is single-quoted with `AdminCommandBuilder.shellQuote` and steps are joined with ` && `. There is no initialiser from arbitrary strings except `init?(rawValue:)` over the fixed case names. `MaintenanceAdminExecutor.runAsAdmin(_:)` accepts only this type; `OsascriptAdminExecutor` implements it with one osascript prompt per run, no timeout.
- Outcomes: `succeeded` only when the exit status is 0; `cancelled` on osascript `-128`; otherwise `failed(message)`. User tasks use `ProcessCommandRunner(timeout: 300)`.
- Last run (date + succeeded flag) persists in `<support>/maintenance.json` (atomic write).

## 3. App

- `PerformanceModel` keeps a set of demand tokens. Each visible client (Overview, Heavy consumers, popover, menu bar label metric) registers what it needs (`metrics`, `processes`); a single `Task` samples every 2 s while any token is registered and stops when none is. History is a 60-point ring buffer for sparklines. Sampling runs off the main actor.
- `PerformanceView`: segmented control (Overview · Heavy consumers · Login items · Maintenance) under the screen headline. Overview: four glass cards with Swift Charts sparklines (`.monospacedDigit()` numbers), plus the menu bar setting (show/hide, label metric). Heavy consumers: grouped list with app icons, CPU and memory, Quit and Force Quit… (confirmation sheet). Login items: sections User agents (actions), System (read-only `SafetyTag`-style label + explanation), Background items inside apps, Open Login Items Settings. Maintenance: rows with explanation, "Needs admin" label, last run, Run… (confirmation for admin), and a full-screen progress view while a task runs, with a way back.
- Menu bar: `MenuBarExtra(isInserted:)` with `.window` style; label is the `LogoGlyph` rendered as a template image plus one metric (default CPU; None/CPU/Memory/Network selectable). Popover: CPU, memory, disk, network bars, top 3 heavy apps, Open OpenClean and Smart Scan buttons. Shown by default; hidden via `@AppStorage("menuBarMonitorEnabled")`.
- Colors only from `Theme`; accent for normal, gold for elevated memory pressure, coral for critical; the word is always shown next to the color.

## 4. Testing

Swift Testing, no real home/LaunchAgents/launchctl/admin prompt:
- SystemMonitor: CPU/memory/network math from fake samples, wrap/reset handling, process grouping and top-N, Force Quit denylist.
- Maintenance: plist parsing (Program vs ProgramArguments, KeepAlive forms, missing keys, malformed), owner resolution, `launchctl list` / `print-disabled` parsing with `FakeCommandRunner`, disable/enable argv, read-only refusal for system scope, remove-to-quarantine + restore on a temp home, periodic hidden when binary missing, last-run persistence.
- Privilege: every `MaintenanceAdminCommand` renders exactly the expected text; executables are absolute and allow-listed; unknown identifiers are rejected; `FakeMaintenanceAdminExecutor` records commands and never prompts.

## 5. Risks and limitations

- `launchctl` output is not a stable API; parsing is defensive and failures degrade to "unknown".
- Disabling with `launchctl disable` persists across reboots in launchd's override database; enabling reverses it.
- CPU per process is only available for the current user's processes without root.
- The menu bar "Smart Scan" button opens the main window and starts a scan; the window shows it if Smart Scan is the selected screen.
