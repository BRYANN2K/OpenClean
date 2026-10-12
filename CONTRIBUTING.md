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
- Commit messages use Conventional Commits (`feat(scan): …`, `fix(quarantine): …`).
