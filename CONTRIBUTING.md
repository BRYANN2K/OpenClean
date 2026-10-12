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
(backups, archives, downloads), it is `review`.

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
`openclean-cli-X.Y.Z.zip` and `SHA256SUMS.txt` (`make release-assets`), pushes the `vX.Y.Z` tag and
publishes a GitHub release with notes grouped into breaking changes, features, fixes and other.

Check locally:

```sh
scripts/next-version.sh                 # next version, or nothing if no release is due
scripts/next-version.sh --notes         # the release notes
bash scripts/tests/test-next-version.sh
make release-assets VERSION=0.0.0-test  # native arch; add ARCH_FLAGS="--arch arm64 --arch x86_64" for universal
```
