# Contributing to OpenClean

## Setup

```sh
swift build
swift test
make lint     # swift format + rule pack lint
make app     # build/OpenClean.app
```

Tests never touch your real home folder: every filesystem test runs in a temporary directory, and the
admin prompt, Trash, lsof and process list are injected. Keep it that way.

## Layout

- `Packages/OpenCleanKit/Sources/` — all logic. No SwiftUI or AppKit here.
- `Apps/openclean-cli` — the `openclean` command.
- `Apps/OpenClean` — the SwiftUI app.
- `Rules/` — bundled rule packs.

Only `Quarantine` and `Privilege` may remove files. `RemovalGuardTests` fails the build otherwise.

## Add a rule in 5 minutes

1. Find the folder. Check that the app rebuilds it: quit the app, move the folder aside, reopen the app
   and use it. Note what, if anything, was lost.
2. Copy the commented template and edit it:
   ```sh
   cp Rules/TEMPLATE.yaml.example Rules/my-tool.yaml
   ```
   Or add the rule to the existing pack it fits (`Rules/dev-tools.yaml`, `Rules/ai.yaml`, ...).
3. Pick the safety level (see "Choosing a level" below). When in doubt, `review`: it is quarantined and
   can be restored.
4. Lint it and see what it finds (all read-only):
   ```sh
   swift run openclean rules lint Rules/my-tool.yaml
   swift run openclean rules explain my-tool.cache
   swift run openclean scan --category developer --json   # find "id" : "my-tool.cache" and its items
   ```
5. Run `make lint`, then open a pull request with a `feat(rules): …` commit. Mention how you checked that
   the app rebuilds the folder, and link its docs if there are any.

Not ready to write YAML? Open a
[rule suggestion](https://github.com/leoAnimesh/OpenClean/issues/new?template=rule-suggestion.yml)
instead. To keep a rule just for yourself, put the pack in `~/Library/Application Support/OpenClean/rules/`.

## Writing a rule

```yaml
pack: my-tools
version: 1
rules:
  - id: jetbrains.caches
    name: JetBrains IDE caches
    category: developer
    explain: Indexes and caches JetBrains IDEs rebuild when a project is opened.
    paths:
      - "~/Library/Caches/JetBrains/*"
    safety: regenerable
    conditions:
      app_not_running: [com.jetbrains.intellij, com.jetbrains.pycharm]
```

| Field | Notes |
|---|---|
| `id` | Lowercase, dotted, unique: `tool.thing`. |
| `explain` | Required. Say **why** removing it is safe and what the user loses, if anything. |
| `category` | `system`, `user`, `browsers`, `developer`, `ai`, `mail`, `trash`, `ios`. |
| `paths` | Absolute or `~/` globs. `*` matches one level, `**` any depth (not at the end). |
| `safety` | `regenerable` (rebuilt automatically, selected by default, deleted), `review` (user decides, quarantined), `caution` (hidden unless Advanced, quarantined). |
| `conditions` | `app_not_running`, `min_age_days`, `min_size` (e.g. `100MB`). |
| `exclude` | Globs to leave out. |
| `requires` | `full_disk_access`, or `admin` (only for `regenerable` rules). |
| `make_writable` | `true` for a tool that makes its cache read-only (Go's `~/go/pkg/mod`): before deleting, OpenClean adds `u+w` to the folders you own inside the item, never following a symlink. Only for rules that delete immediately and don't need `admin`. |

Choosing a level: if the app silently rebuilds it and nothing the user made is lost, it is
`regenerable`. If it costs a long re-download (AI models, device symbols) or holds user data
(backups, archives, downloads), it is `review`. Anything inside a user's project, a virtual environment, or a cache a
project loads directly (Yarn Plug'n'Play, pub, Maven's local repository, which also holds `mvn install`
output) is `review` too, so it is quarantined and can be restored.

A rule whose `paths` sit in `~/Library/Caches` should also be added to the `exclude` list of
`user.app-caches` (`Rules/user-caches.yaml`), so the generic App caches rule never picks the folder up
when your rule is skipped (for example because its app is running).

Targets that a glob can't express are `Probe`s in `Packages/OpenCleanKit/Sources/Probes/`. The project
probes (`node.project-modules`, `python.project-venvs`, `rust.project-targets`,
`dev.project-build-outputs`) share one walk of the home folder (`ProjectArtifactFinder`): it never follows
symlinks, stays on the home volume, skips hidden folders, `~/Library`, Documents, Desktop, Downloads, the
media folders, deny-listed places and your exclusions, and only reports a folder next to the file that
proves which tool made it (`package.json`, `Cargo.toml`, `pyvenv.cfg`, `Package.swift`, ...) in a project
unchanged for 30 days (including its enclosing git repository). Folders the user adds under Settings →
Project folders (`projectFolders` in `settings.json`) are walked too, even in Documents or Desktop; only
the artifacts found there can get past the deny-list (`ProjectFolderExemption`, see AGENTS.md). The walk
checks for cancellation before listing each folder, so stopping a scan stops it promptly.

Check your pack with `openclean rules lint path/to/pack.yaml`, then try it with
`openclean scan --json` before opening a pull request.

## Pull requests

- One logical change per PR, with tests.
- `swift test` and `make lint` must pass.
- New behaviour that removes files needs a test showing what is **not** removed.
- Commit messages use Conventional Commits (`feat(scan): …`, `fix(quarantine): …`). They decide the
  next version, so pick the type carefully (see below).

## Releases & versioning

Every merge to `main` runs `.github/workflows/release.yml`. It looks at the commits since the last
`vX.Y.Z` tag (subjects and bodies, so squash-merge bodies count) and picks the bump:

| Commits since the last tag | Bump | Example |
|---|---|---|
| `type!:` / `type(scope)!:`, or a `BREAKING CHANGE:` footer | major | 1.4.2 → 2.0.0 |
| any `feat` | minor | 1.4.2 → 1.5.0 |
| any `fix` or `perf` | patch | 1.4.2 → 1.4.3 |
| only `docs`, `chore`, `ci`, `test`, `style`, `refactor`, `build` | no release | |

While the major version is 0, a breaking change bumps the minor version instead (0.4.2 → 0.5.0), the
usual 0.x convention. Leaving 0.x is a deliberate step: run the workflow by hand with a `version` input
of `1.0.0`. The same input forces a release at any version (`workflow_dispatch`, Actions tab).

With no tags yet, the `CFBundleShortVersionString` in `Apps/OpenClean/Info.plist` is the previous
version. You don't need to bump it: the build stamps the release version and a build number (the commit
count) into the app bundle.

When a release is due, the workflow builds, tests and lints, makes a universal `OpenClean-X.Y.Z.dmg`,
`openclean-cli-X.Y.Z.zip` and `SHA256SUMS.txt` (`make release-assets`), signs and notarizes them (below),
checks them (`scripts/check-release-assets.sh`), pushes the `vX.Y.Z` tag and publishes a GitHub release.
Every pull request runs the same build and checks without signing (the `release-dry-run` CI job), and its
run summary shows the version merging would release and the notes.

**Release notes:** by default they list the commits since the last tag, grouped into breaking changes,
features, fixes and other. For a release worth a summary, add `docs/release-notes/X.Y.Z.md` in the pull
request that releases X.Y.Z: it becomes the top of the notes and the commit list moves into a collapsed
"All changes" section. Install instructions are appended either way.

### Signing and notarization

Releases are signed with a Developer ID Application certificate (hardened runtime, secure timestamp, no
entitlements: OpenClean needs no hardened-runtime exceptions; it only runs `osascript` as a child
process), notarized with `notarytool`, and the DMG gets the ticket stapled. The release job stops before
building anything unless all six repository secrets are set:

| Secret | What it is |
|---|---|
| `APPLE_TEAM_ID` | The ten-character Apple Team ID |
| `DEVELOPER_ID_P12` | The Developer ID Application certificate and its private key, exported as `.p12`, base64-encoded (`base64 -i cert.p12 \| pbcopy`) |
| `DEVELOPER_ID_P12_PASSWORD` | The password the `.p12` was exported with |
| `APPLE_API_KEY_P8` | The contents of the App Store Connect API key file `AuthKey_<id>.p8` (notarization) |
| `APPLE_API_KEY_ID` | That key's ID |
| `APPLE_API_ISSUER_ID` | The issuer ID shown on the App Store Connect API keys page |

The updater accepts an update only if it is signed by the same team as the running app (`PublisherCheck`),
so a release must never be signed with a different team. Local builds, forks and pull requests are signed
ad hoc (`SIGN_IDENTITY` defaults to `-`); to sign locally, pass
`SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"` to `make app` / `make release-assets`.

Check locally:

```sh
scripts/next-version.sh                 # next version, or nothing if no release is due
scripts/next-version.sh --notes         # the release notes
bash scripts/tests/test-next-version.sh
make release-assets VERSION=0.0.0-test  # native arch; add ARCH_FLAGS="--arch arm64 --arch x86_64" for universal
```

### Homebrew

This repository is a Homebrew tap: `Casks/openclean.rb` installs the release DMG (the app) and
`Formula/openclean.rb` installs the CLI from the release's `openclean-cli-X.Y.Z.zip` (or builds `main`
with `--HEAD`). Both pin the SHA-256 from the release's `SHA256SUMS.txt`.

`main` is protected, so the release workflow can't commit the bump there. Its `homebrew` job runs after a
release is published: it runs `scripts/bump-homebrew.sh X.Y.Z SHA256SUMS.txt`, pushes the result to a
`homebrew/vX.Y.Z` branch and opens a `chore(homebrew): …` pull request (a `chore`, so merging it doesn't
release again). Merge it to move the tap. Notes:

- The repository setting Settings → Actions → General → **Allow GitHub Actions to create and approve pull
  requests** must be on, or `gh pr create` fails (the release itself is already published by then).
- GitHub doesn't run workflows for pull requests opened with `GITHUB_TOKEN`, so CI doesn't run on the bump
  PR. Close and reopen it to run CI. The script is covered by `bash scripts/tests/test-bump-homebrew.sh`,
  and the PR dry run (`release-dry-run`) shows the bump it would make.
- If the job fails, bump by hand: download `SHA256SUMS.txt` from the release, run
  `scripts/bump-homebrew.sh X.Y.Z path/to/SHA256SUMS.txt`, check with `brew style Casks Formula`, and open
  the pull request yourself.
