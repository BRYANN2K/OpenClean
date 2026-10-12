# Manual QA checklist

Run before each release, on a test user account.

## Full Disk Access
- [ ] Fresh install without access: banner says "Full Disk Access is off"; Trash rule shows "Needs access".
- [ ] Grant access, click Check Again: banner disappears; rescanning lists Trash items.
- [ ] Rebuild with `make app`, relaunch: banner says access must be granted again; re-adding OpenClean fixes it.

## Administrator prompt
- [ ] Select System caches, Clean: exactly one administrator prompt appears.
- [ ] Cancel the prompt: those items are listed as skipped in History; everything else was cleaned.
- [ ] Approve the prompt: items are gone and logged as deleted.

## Quarantine and History
- [ ] Clean a review item: it disappears from its folder and appears under History.
- [ ] Restore it: it is back with the same contents; History shows Restored.
- [ ] Restore when a file with the same name exists: the dialog offers Skip / Keep Both / Replace.
- [ ] `openclean schedule purge --daily` creates the LaunchAgent; `--off` removes it.

## Accessibility and appearance
- [ ] Every control reachable with Tab and arrow keys.
- [ ] VoiceOver reads checkbox state ("selected", "partially selected", "not selected") and safety badges.
- [ ] Light and dark mode both readable.
