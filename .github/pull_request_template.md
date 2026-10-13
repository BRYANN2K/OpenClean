## What this changes

<!-- One logical change per PR. Say what changes for users, if anything. -->

## Checklist

- [ ] The PR title / commit type follows Conventional Commits and is the right one: it decides the next version (`fix` → patch, `feat` → minor, `docs`/`chore` → no release).
- [ ] `swift test` and `make lint` pass (run `swift build` first if the CLI changed).
- [ ] If this removes files: a test shows what is **not** removed, and the safety invariants in AGENTS.md still hold.
- [ ] New user-facing text is localized (de, es, fr, ja, zh-Hans).
