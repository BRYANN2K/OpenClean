# How OpenClean works

## What it can clean

- **Smart Scan:** System Junk, user caches and logs, browser caches, Trash, Mail attachments and old iOS backups.
- **Developer tools:** Xcode DerivedData, archives, device support and simulators; package caches for
  npm/npx, Yarn, pnpm, Bun, Deno, Corepack, pip, uv, Poetry, conda, Cargo, Go, Gradle, Maven, Coursier, Ivy,
  SwiftPM, CocoaPods, pub, Bundler, Composer, Terraform and Homebrew; Playwright, Puppeteer, Cypress and
  Electron downloads; JetBrains indexes and VS Code / Cursor caches; Docker disk image reporting.
- **Old projects:** `node_modules`, Python virtual environments, Rust `target` folders and build output in
  projects you have not touched for 30 days. They go to quarantine. Projects in Documents or Desktop are
  searched only if you add their folder under Settings → Project folders.
- **AI models:** Ollama, LM Studio, Hugging Face, PyTorch Hub, Whisper, Keras, TensorFlow Datasets and Kaggle downloads.
- **Space Lens:** a disk space map plus large, old and duplicate file finders. Removals go to the macOS
  Trash and nothing is pre-selected.
- **Performance and menu bar:** live CPU, memory, disk and network, heavy apps, login items and launch
  agents, and maintenance tasks (flush DNS, reindex Spotlight, rebuild Launch Services, thin Time Machine snapshots).
- **Scan reminder (optional, off by default):** weekly or monthly, a read-only Smart Scan runs in the
  background while OpenClean or its menu bar item is running and tells you how much can be cleaned. It never cleans by itself.

## How it stays safe

- A built-in deny-list (System, your Documents/Desktop, Keychains, Mail, iCloud Drive, app bundles,
  Photos libraries) can never be removed, whatever a rule says. The one exception is opt-in: folders such
  as `node_modules` that the old-project search finds inside a project folder you chose in Settings may
  go to quarantine even under Documents or Desktop; nothing else there is touched. Deny-list checks are
  byte-level and aware of Unicode normalization and letter case, so look-alike spellings of a protected path do not slip through.
- Symlinks are never followed; a match that resolves outside its rule's folder is dropped.
- Right before removal, items that changed since the scan, are open in another app, or belong to an app
  that is now running are skipped and logged.
- Each rule has a safety level. `regenerable` items are deleted; `review` and `caution` items go to
  quarantine first, where History and Restore can bring them back for 1–90 days (7 by default).
- Administrator deletions only run where every parent folder is root-protected.
- Only two modules in the codebase can remove files, and a test enforces it.

## Updates and privacy

OpenClean checks api.github.com once a day for a new release (you can turn this off in Settings → Updates
or on the last onboarding step); **OpenClean → Check for Updates…** always works. The check sends only
`User-Agent: OpenClean/<version>`; nothing about you or your files is sent. Updates are downloaded only
from GitHub, checked against the release's `SHA256SUMS.txt` and the app's code signature, and installed in
place; your previous version is kept in History, so you can restore it. An update must be signed by the
same Apple developer team as the app you have. Apart from this, OpenClean makes no network requests.

## Installation details

- The release has `OpenClean-X.Y.Z.dmg` (universal: Apple silicon and Intel), `openclean-cli-X.Y.Z.zip`
  (the CLI plus its rule packs) and `SHA256SUMS.txt` (`shasum -a 256 -c SHA256SUMS.txt`). Releases are
  signed with a Developer ID and notarized by Apple.
- Homebrew (this repository is the tap):

  ```sh
  brew install --cask leoanimesh/openclean/openclean   # the app (same signed, notarized DMG)
  brew install leoanimesh/openclean/openclean          # the openclean CLI (release build)
  brew install --HEAD leoanimesh/openclean/openclean   # the CLI built from the latest main (needs Xcode 16+)
  ```

  The app keeps itself up to date (Settings → Updates), so `brew upgrade` leaves the cask alone unless you
  pass `--greedy`; `brew upgrade openclean` updates the CLI. `brew uninstall --zap --cask openclean`
  removes the app's preferences and caches but keeps `~/Library/Application Support/OpenClean`, which holds
  your quarantine (files you can still restore).
- Build from source (macOS 14+, Xcode 16+):

  ```sh
  git clone https://github.com/leoAnimesh/OpenClean.git
  cd OpenClean
  make install          # app → /Applications, CLI → /usr/local/bin (may need sudo)
  ```
- **Full Disk Access:** Trash, Mail, Safari and iOS backups live in protected folders. Grant access in
  System Settings → Privacy & Security → Full Disk Access. The grant survives updates of the released app.
  A build from source is signed ad hoc, so each rebuild gets a new signature: remove OpenClean from that
  list and add it again; the app tells you when.

## Languages

The app follows your macOS language: English, Deutsch, Español, Français, 日本語 and 简体中文. To use
a different language for OpenClean only, pick it under System Settings → General → Language & Region →
Applications.

The translations are machine-assisted and have not yet been reviewed by native speakers. If something
reads oddly, or a safety message could be misread, please open an issue or a pull request; see
[CONTRIBUTING.md](../CONTRIBUTING.md#translations). Rule names and explanations come from the YAML rule
packs and stay in English.

## Clean-room statement

OpenClean's feature set was informed by inspecting CleanMyMac's App Store bundle metadata and
user-facing strings. No MacPaw code, binaries, rule data or assets were decompiled, copied or used.
OpenClean is an independent project, not affiliated with MacPaw. CleanMyMac is a trademark of MacPaw.
