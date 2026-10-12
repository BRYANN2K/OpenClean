# OpenClean — Sub-project 3: Space Lens + large/old files + duplicates

- **Date:** 2026-10-12
- **Status:** Draft for review
- **License:** GPL-3.0
- **Depends on:** sub-project 1 (core, `DenyList`, `Quarantine`, `OpenFiles`), the v1 module wiring (`SpaceLensModel`, `SpaceLensView`, `Backdrop.spaceLens`).

## 1. Goals

Help people see where their disk space went and remove what they no longer need, by hand, with the same fail-closed checks as Cleanup.

1. **Space map:** an interactive sunburst of a folder (default: home; any folder can be picked), with drill-in, breadcrumbs and a list of the largest children.
2. **Large & old files:** files above a size threshold, optionally not opened for N days, grouped by kind.
3. **Duplicates:** byte-identical files in the user's content folders, with a suggested copy to keep.
4. **Move to Trash:** every removal in Space Lens goes to the macOS Trash (recoverable with Finder's Put Back), never to OpenClean's quarantine, and always after an explicit confirmation.

### Non-goals

- Similar-image detection, fuzzy/near duplicates, music-tag duplicates.
- Deleting permanently, emptying the Trash, or any removal without a confirmation sheet.
- Automatic selection. **Nothing in Space Lens is ever pre-selected**, including "all but one" in duplicate groups; there is no bulk "select all".
- Cleaning inside `~/Library`, app bundles or system locations (Cleanup and Uninstaller cover those with rules).
- A CLI front end (can be added later on top of the same coordinator API).
- Watching the file system for live updates; results are a snapshot and the Trash action re-verifies each item.

## 2. Architecture

```
RuleKit ── ScanEngine (HardLinkLedger, FileSizer)
   │            │
   └── Quarantine ── TrashPolicy, TrashMover        (only module that moves files)
          │
       SpaceKit ── SpaceScanner, LargeFileFinder, DuplicateFinder, FileKind   (no SwiftUI/AppKit)
          │
   OpenCleanKit ── Coordinator+SpaceLens.swift (extension on OpenCleanCoordinator)
          │
   OpenCleanAppModel ── SpaceLensModel ── OpenCleanApp ── SpaceLensView + SpaceLens*.swift
```

- **SpaceKit** (new target) reads the file system only. It depends on Quarantine solely to reuse `TrashPolicy` for scan-time filtering (the same policy is enforced again at Trash time), mirroring how `DenyList` is applied both at scan and at pre-delete time.
- **Quarantine** gains `TrashPolicy.swift` and `TrashMover.swift`. The actual move reuses `Remover.systemTrash` (`FileManager.trashItem`) through the injectable `TrashOperation`, so tests never touch the real Trash. `RemovalGuardTests` is unchanged.
- **Coordinator+SpaceLens.swift** exposes `scanSpace`, `findLargeFiles`, `findDuplicates`, `moveToTrash`, `trashPolicy` and `defaultDuplicateRoots`. All of them use the coordinator's resolved home and its injected `OpenFilesProvider` and `TrashOperation`.

## 3. Space map scanner

### Size semantics (same as `FileSizer`)

- Size = allocated bytes (`st_blocks * 512`) via `lstat`/`fstatat(AT_SYMLINK_NOFOLLOW)`. Sparse regions are not counted. A folder's size includes its own directory entry.
- Hard links: a file with `st_nlink > 1` is counted once per scan through a shared `HardLinkLedger` (device + inode). Directories are never deduplicated.
- Symlinks are never followed; a symlink is a leaf with its own (usually zero) allocated size.
- Volumes: the scan records the root's `st_dev` and never descends into a directory on another device (mount points, other disks, `/System/Volumes/*` when scanning `/`). Picking a volume's root as the scan root is how you scan that volume. Skipped mount points are listed in the result.
- APFS clones share blocks but each clone reports its full allocation; sizes can add up to more than the used space. This is documented in the UI footnote, not corrected.

### Concurrency and cancellation

- Directories at depth < `parallelDepth` (2) are listed inline and their subdirectories become child tasks in a `TaskGroup`. At depth `parallelDepth` each subtree is walked synchronously inside one task, after acquiring a permit from a `ConcurrencyGate` (actor semaphore, default `min(8, cores)` permits). Intermediate levels never hold a permit, so the gate cannot deadlock.
- `Task.isCancelled` is checked per directory; a cancelled scan returns the partial tree marked `isComplete = false`.
- Progress is an `AsyncStream<SpaceScanProgress>` (entries seen, bytes counted, unreadable folders). Counters are flushed per directory and yielded at most every 1,000 entries, plus a final value.
- Unreadable folders (`opendir` fails, typically `EACCES`/`EPERM` without Full Disk Access) are kept as leaves marked `isUnreadable`, counted, and the first 200 paths recorded.

### Memory bounds

The tree is built bottom-up; each folder keeps only some children and folds the rest into one "Other" aggregate node (size and entry count preserved, so totals stay exact):

| depth of the folder | children kept |
|---|---|
| 0–1 | top 50 by size |
| 2–3 | top 20, each ≥ 4 MB |
| 4–6 | top 10, each ≥ 4 MB |
| ≥ 7 (`maxDepth`) | none: the folder is a summarized leaf (`isTruncated`) |

When only one child would be folded it is kept as itself (an "Other" of one saves nothing), so a folder keeps at most limit + 1 children. From depth 2 down every kept node (other than that single extra) is at least 4 MB and nodes at one depth are disjoint, so the retained node count at each of those levels is at most `scanned bytes / 4 MB` and also at most the product of the per-level limits. A 1 TB home therefore retains well under a million nodes in the worst case and typically a few thousand. The UI offers **Scan this folder** on a truncated node, which re-roots the scan there.

## 4. Large & old files

- Walks the chosen roots (default: home) with `LargeFileFinder`. Only regular files are candidates, plus a few "measured packages" that are really single large items: `.sparsebundle`, `.pvm`, `.utm`, `.vmwarevm` (size via `FileSizer`; listed as disk images).
- **Size threshold:** allocated size ≥ 50 MB / **100 MB (default)** / 500 MB / 1 GB. The finder collects everything ≥ 50 MB once; changing the threshold or age filter re-filters without rescanning.
- **Age:** "not opened for" Any time (default) / 3 months / 6 months / 1 year. *Last opened* = the later of `URLResourceValues.contentAccessDate` and `contentModificationDate`. APFS updates access times lazily and Spotlight/backup tools can bump them, so a file may look more recently used than it is; this errs toward showing fewer files as old. When both filters are set, a file must match both (size threshold always applies; listing every small old file was not useful).
- **Exclusions** (the finder does not descend; decided by `TrashPolicy.subtreeVerdict`, see §6):
  - everything under `~/Library` and `/Library` — app internals; reading other apps' containers would also trigger macOS's "access data from other apps" prompts. **The exception list for "Downloads-like" folders inside `~/Library` is deliberately empty in v1**: the user-facing download locations (`~/Downloads`, `~/Desktop`, `~/Movies`, …) live outside `~/Library` and are scanned normally;
  - insides of bundles and packages (`.app`, `.framework`, `.bundle`, `.plugin`, `.kext`, `.appex`, `.xpc`, `.photoslibrary`, `.musiclibrary`, `.tvlibrary`, `.imovielibrary`, `.fcpbundle`, `.aplibrary`, `.xcarchive`, `.logicx`, and the measured packages above);
  - Trash folders (`.Trash`, `.Trashes`), system folders, `~/.ssh`, `~/.gnupg`, OpenClean's support folder, and every other `DenyList` subtree;
  - `~/Documents` and `~/Desktop` (deny-listed for automatic cleanup) **unless** the user turns on "Include Documents and Desktop" (off by default). Files found there are marked and follow the per-file rule in §6.
  - other volumes (same `st_dev` rule as the space map).
- **Kinds** by file extension (`FileKind`, library layer): video (`mp4 mov m4v mkv avi wmv flv webm mpg mpeg mts m2ts 3gp`), archives (`zip tar gz tgz bz2 tbz xz txz 7z rar zst lz4 cpio`), disk images (`iso img sparseimage sparsebundle vmdk vdi vhd vhdx qcow2 toast pvm utm vmwarevm`), installers (`dmg pkg mpkg xip`), other. Sorted by size, largest first, grouped by kind in that order.

## 5. Duplicate finder

- **Roots:** `~/Downloads`, `~/Desktop`, `~/Documents`, `~/Pictures`, `~/Movies`, `~/Music` (those that exist); the user can add or remove folders. Overlapping roots are merged so no file is seen twice.
- Same exclusions as §4 (Photos and Music library packages are skipped as packages), but Documents and Desktop are always walked here: they are shown, and their files can only be moved by the per-file rule in §6.
- **Algorithm:**
  1. Walk, keep regular files with logical size ≥ 1 MB (configurable). Symlinks are ignored.
  2. Group by logical size (`st_size`); drop singleton groups.
  3. Within a size group, collapse hard links: entries with the same (device, inode) are one file, not duplicates.
  4. Partial hash: SHA-256 of the first 64 KB + last 64 KB (whole file if ≤ 128 KB); regroup.
  5. Full SHA-256 (CryptoKit), streamed in 1 MB chunks; regroup. Only groups of ≥ 2 identical files are reported.
  - Hashing runs in a bounded task group (4 files at a time), checks cancellation between chunks and reports progress (files hashed / to hash). Unreadable files are skipped and counted.
- **APFS clones** are not detected specially: two clones are byte-identical files and are reported as duplicates. Trashing one frees less than its allocated size because blocks are shared; the spec and UI footnote say so.
- **Suggested keep** (never selected, only labelled): the copy in the most canonical folder (Documents < Pictures/Movies/Music < Desktop < other < Downloads), then the oldest (earliest birth time), then the shortest path.
- **Reclaimable** per group = allocated size × (copies − 1).
- **Keep at least one copy:** the model refuses to tick the last unticked copy of a group, so a group can never be fully trashed from the Duplicates tab.

## 6. Safety: TrashPolicy and TrashMover (Quarantine)

Space Lens moves items the *user* picked, one by one. That is different from Cleanup, where rules pick items. The `DenyList` stays exactly as it is for the rule/cleanup pipeline (linter, scan, `PreDeleteChecker`); Space Lens adds a stricter policy on top for its own action and relaxes nothing for Cleanup.

### `TrashPolicy.verdict(for:isDirectory:)` — lexical, canonical, byte-level

Evaluated in this order; the first match wins:

1. Not absolute, or has a `.`/`..` component → **refused** (fail closed).
2. **Critical locations — always refused:** inside or equal to `/System`, `/Library`, `/Applications`, `/usr`, `/bin`, `/sbin`, `/opt`, `/cores`, `/dev`, `/etc`, `/var`, `/tmp`, `~/Library`, `~/Applications`; anything in `/private` except items strictly inside the per-user scratch areas `/private/tmp` and `/private/var/folders` (`$TMPDIR`); equal to `/`, `/Users`, `/Volumes`; any path component ending in `.app` (bundle or its insides); any component `.Trash`/`.Trashes` (already in the Trash); anything inside a package (§4 list).
3. `DenyList(home:)` says nothing → **allowed**.
4. `DenyList` denies and the path is strictly inside `~/Documents` or `~/Desktop`:
   - a regular file → **allowedUserContent** (explicit per-file user action only);
   - a folder → **refused** ("only individual files can be moved to the Trash from Documents and Desktop").
5. Any other `DenyList` denial (home itself, `~/Documents`/`~/Desktop` themselves, Keychains, Mail, Mobile Documents, `.ssh`, `.gnupg`, OpenClean's support folder, Photos libraries, `/private/etc`, `/private/var/db`, app bundles, ancestors of any of these) → **refused** with the DenyList reason.

Which DenyList entries still block a user-initiated Trash move: **all of them except files strictly inside `~/Documents` and `~/Desktop`.** (No other DenyList subtree is nested inside Documents or Desktop, so for such a path the Documents/Desktop subtree is the only possible denial; a test covers the critical cases.)

"Explicit per-file user action" is guaranteed by construction: Space Lens has no bulk selection, every file has its own checkbox, nothing is pre-ticked, and the confirmation sheet lists each item from Documents/Desktop with a "From Documents"/"From Desktop" label.

`subtreeVerdict(of:)` asks the same question for a hypothetical child of a folder; walkers use it to decide whether to descend (refused → skip; allowedUserContent → descend only when user content is included).

### `TrashMover.check` / `move` — per item, just before moving

Each `TrashRequest` carries the scanned canonical path, the scan root, and the snapshot (device, inode, modification date, is-directory, bytes). Skip and record the reason if:

1. the policy refuses it (`protected`);
2. it is not strictly inside the canonical scan root (`outsideScanRoot`), or it *is* the scan root;
3. it no longer exists (`missing`);
4. `realpath` no longer equals the scanned path (a parent was swapped for a symlink) → `pathChanged`;
5. device/inode/modification date/type differ from the snapshot (`changedSinceScan`);
6. it is a mount point (device differs from its parent's) → `protected`;
7. it, or anything inside it, is open in another process per one `lsof -F0n` call (`inUse`); if `lsof` fails, every item is skipped (`openFilesUnknown`);
8. it passed every check but another requested folder that also passed contains it (`coveredBySelection`: the folder's move covers it).

Then `TrashOperation` (default `Remover.systemTrash`, i.e. `FileManager.trashItem`) moves it; errors are recorded as `failed`. A `TrashReport` lists every item's outcome; nothing aborts the batch.

## 7. UI (SpaceLensView)

Built with the design system (`Theme`, `glassPanel`, `GlassCircleButtonStyle`, `CapsuleButtonStyle`, `Orb`, `ProgressRing`, `CheckboxButton`) on `Backdrop.spaceLens`. The space-map category palette lives in `SpaceLensTheme.swift` as an extension of `Theme` (Theme.swift is shared with other in-flight modules; fold it in when merging).

- Native segmented control at the top: **Space map · Large & old files · Duplicates**. Each tab keeps its own state.
- **Home (per tab):** orb with an SF Symbol, headline, one sentence, the round glass **Scan** button, and options as pills (map: folder picker; large: size threshold; duplicates: folder list).
- **Scanning:** full screen, orb inside a spinning ring, live counters (items, bytes; files hashed for duplicates), **Stop** (Esc).
- **Space map results:** "Start over" (Esc) and a breadcrumb; a `Canvas` sunburst (three rings, click a folder to drill in, click the center to go up, hover shows name + size in the center); a glass list of the focus folder's largest children with checkbox, icon, size, drill-in chevron, Reveal in Finder, Quick Look. Truncated folders offer **Scan this folder**. Protected items show a disabled checkbox with the reason as help text.
- **Large & old files:** threshold, age and "Include Documents and Desktop" controls; glass panels per kind with rows (checkbox, icon, name, folder, size, last opened, Reveal, Quick Look). Summary: total size of matching files.
- **Duplicates:** total reclaimable; one glass panel per group with a "Suggested to keep" label on one copy; per-file checkboxes; the last unticked copy cannot be ticked.
- **Bottom bar:** selected count and size, round glass **Trash…** button (disabled until something is selected), Scan Again.
- **Confirmation sheet:** every item with size and folder, user-content items labelled, "Items go to the Trash. You can put them back from the Trash in Finder." Cancel / Move to Trash.
- **After moving:** a glass banner with moved count/size and each skipped item's reason; results update in place (sizes in the map are subtracted up the tree).
- **Empty and permission states:** "No files over 100 MB" etc.; when folders were unreadable, a footnote with "N folders couldn't be read. Full Disk Access lets OpenClean include them." and Open Settings.
- Every screen has a way back (Start over / Stop / Cancel).

## 8. Tests (Swift Testing, temp directories only)

- **SpaceKitTests:** tree sizes on temp dirs; hard links counted once; symlinks not followed (a symlink to a big folder adds nothing); unreadable folder recorded (`chmod 000`, restored after); child limits fold into "Other" with exact totals; cancellation returns `isComplete == false`; removing nodes subtracts sizes up the tree. Large/old: threshold and age filters, `~/Library` and bundles excluded, Documents excluded unless opted in, kind mapping. Duplicates: same content + different names = duplicates; same size + different content ≠ duplicates; hard links are not duplicates; small files ignored; suggested keep.
- **QuarantineTests/TrashMoverTests:** policy refuses critical paths (System, `~/Library`, Keychains, `.ssh`, OpenClean support, app bundles and insides, Photos library, home, Documents itself, folders in Documents), allows files in Documents/Desktop as user content; mover skips changed, replaced, missing, outside-root, open and lsof-unknown items, and calls the injected fake trash only for allowed items.
- **OpenCleanKitTests/OpenCleanAppModelTests:** coordinator wiring and `SpaceLensModel` flows (nothing pre-selected; keep-one rule; trash updates results) with an injected home, fake open files and a fake trash closure. Tests never touch the real home or Trash.

## 9. Limitations

- Results are a snapshot; folders that change after the scan are re-verified only at their own inode/mtime, not recursively (the `lsof` check is the backstop, as in Cleanup).
- Access times are approximate (§4).
- Clone-aware reclaimable sizes are not computed.
- Folders inside Documents/Desktop can't be trashed from Space Lens (only files); use Finder for those.
