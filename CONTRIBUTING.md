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
unchanged for 30 days (including its enclosing git repository).

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
