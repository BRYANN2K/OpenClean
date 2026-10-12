---
name: openclean-design
description: OpenClean's visual design system for the SwiftUI app — colors, backdrops, glass panels, the round action button, category icons, safety tags, the logo and copy voice. Use whenever adding or changing any screen, view, component, icon or user-facing text in Apps/OpenClean, or when building a new module (Uninstaller, Space Lens, Performance, menu bar) so it matches the existing look.
---

# OpenClean design system

OpenClean looks like a polished, native Mac utility: deep gradient backdrops, frosted glass panels, one big round glass action per screen, and calm, factual copy. It must never look like a generic dark "AI dashboard" (neon accents, chips everywhere, cards with colored left borders, emoji).

**Source of truth:** `Apps/OpenClean/Sources/OpenCleanApp/Theme.swift`. Every color, gradient and reusable surface lives there. Don't hard-code a color in a view: add a token to `Theme` or reuse one. The reference mockups are in the "OpenClean UI" design canvas on claude.ai (owner: leoAnimesh): https://claude.ai/artifact/CHgZHQMPj9TmMWST3ciJNh

## Principles

1. **One primary action per screen.** It's a `GlassCircleButtonStyle` button (Scan, Clean) centered near the bottom. Everything else is a `CapsuleButtonStyle` pill or a plain link.
2. **The hero carries the screen.** Smart Scan screens center an `Orb` (with `LogoGlyph` or a checkmark inside), a short bold headline, and one sentence of secondary text. Don't stack extra panels around it.
3. **Facts, not game mechanics.** No XP, levels, streaks, scores, "health" numbers, milestones, badges or achievements. They were all tried and removed on purpose. Show real numbers only: bytes freed, free space, item counts, days left in quarantine (`CleanupStats`, `DiskSpace`).
4. **Safety is always spelled out.** Safety level appears as a `SafetyTag` with the word (Safe / Review / Caution), never as color alone. Anything that goes to quarantine says it can be undone and for how long (use `settings.clampedRetentionDays`, never a literal 7).
5. **Native first.** System font (SF Pro), SF Symbols, standard controls in sheets and Settings. The custom look applies to the main window's detail area and sidebar only; the window is forced to dark appearance (`.preferredColorScheme(.dark)` in `ContentView`).

## Tokens (Theme.swift)

| Token | Value | Use |
|---|---|---|
| `Theme.mint` / `teal` / `deepTeal` | #4BF2B8 / #12A88B / #0A4756 | Brand gradient (icon, logo tiles). `deepTeal` is also ink on white or mint fills. |
| `Theme.accent` | #7DF5C8 | The only bright accent: progress rings, checkboxes, selection, success ticks. |
| `Theme.gold` | #FFD58A | Review items, notices, warnings that aren't errors. |
| `Theme.coral` | #FFB894 | Caution items. |
| `Theme.textPrimary` / `textSecondary` / `textTertiary` | white / 80% / 62% | Text on backdrops. Never below 62% white for text. |
| `Theme.glassFill` / `glassStroke` / `glassDivider` | white 9% / 14% / 8% | Glass panels and row dividers. |
| `Theme.sidebar` | #05181D at 55% | Sidebar tint over the window material. |
| `Theme.panelRadius` | 16 | Glass panels; 12–14 for small cards; 10 (`tileRadius`) for icon tiles. |

**Backdrops (`Backdrop`)**, applied once in `ContentView` by screen:
- `.scan`: #082A33 → #0B4A4C → #12795F (default: Smart Scan, Cleanup).
- `.success`: #0A3A3E → #0F6656 → #1FA67A (cleanup complete).
- `.history`: #0C1B33 → #15335A → #1F5A7A (History).
New modules get their own backdrop case: a dark top-leading color moving to a mid-tone bottom-trailing one, in a single hue family distinct from the existing three (e.g. a deep plum for Uninstaller, deep indigo for Space Lens). Keep white text at 4.5:1 or better across the whole gradient.

**Type** (system font, set with `.font(.system(size:weight:))`):
- Screen headline: 30–34 bold. Big number: 56 bold, `.monospacedDigit()`.
- Section title: 18 bold. Row title: 14–15 semibold. Body/secondary: 14–15 regular in `textSecondary`. Captions: 11–12.
- Any number that changes live (sizes, counts, percentages) uses `.rollingNumber(value)` (Theme.swift): monospaced digits that roll to the new value, off with Reduce Motion. Static numbers just use `.monospacedDigit()`.
- Wordmark: `Wordmark` view, rounded design, "Open" regular + "Clean" bold.

## Components (reuse; don't re-create)

- `glassPanel(radius:)`: the frosted container for lists and cards. Lists inside it are `VStack`s of rows separated by `Divider().overlay(Theme.glassDivider)`; set `.scrollContentBackground(.hidden)` on any `List` that sits on a backdrop.
- `GlassCircleButtonStyle(diameter:)`: 112 pt on home screens, 96 pt in bottom bars.
- `CapsuleButtonStyle(prominent:)`: `prominent: true` (white, teal text) for the main secondary action like Done or Restore All; plain for everything else.
- `Orb(size:) { … }`: glossy hero sphere, 180–260 pt.
- `ProgressRing(fraction:lineWidth:)`: around the orb while scanning and in small free-space indicators.
- `StatPill(text:) { icon }`: small status at the top right (e.g. free space). One or two at most.
- `CategoryIcon(category:size:)`: gradient tile + white SF Symbol per `RuleCategory`. A new category must add its symbol and gradient pair in `CategoryIcon.style(for:)` (bright top, darker bottom, same lightness as the others).
- `SidebarRow`: sidebar destinations. Selected = white 16% fill, mint icon, semibold label; hover = white 7%. Never use `List(selection:)` for navigation — it paints the macOS accent colour (often blue).
- `SafetyTag(safety:)`, `CheckboxButton` (unselected: solid white outline, no tick; selected: accent fill, deep-teal tick), `StorageCard`, `AccessBanner`, `ProblemsBanner`.
- `AppIconView`, `LogoGlyph`, `LogoRing`, `Spark`: the brand marks.

## Screen anatomy

```
┌ sidebar (tinted, logo + wordmark top, StorageCard bottom) ┬ backdrop gradient ──────────────┐
│ Smart Scan / Cleanup / History                            │            [StatPill]           │
│ Coming soon: Uninstaller, Space Lens, Performance         │              Orb                │
│                                                           │     Headline (30–34 bold)       │
│                                                           │   one sentence, textSecondary   │
│ [ 186 GB free ▓▓▓░░  / 48 GB freed by OpenClean ]         │        ( Scan )  ← glass        │
│                                                           │      caption, 12 pt             │
└───────────────────────────────────────────────────────────┴─────────────────────────────────┘
```
List screens (Results, History): headline + subtitle at the top left, glass list in the middle (max width ~860–900, centered), actions in a bottom bar or the header.

## Logo

An open ring (the "O" of Open) with a four-point spark in the top-right gap, white on the mint→teal→deep-teal squircle. The ring runs clockwise from 3 o'clock to 12 o'clock; the spark sits in the open quarter.
- Geometry lives in `LogoRing` and `Spark` (Theme.swift), `scripts/make-app-icon.swift` and `docs/brand/logo.svg`. **Change all three together**, then run `make icon` to regenerate `Apps/OpenClean/Resources/AppIcon.icns`.
- The menu bar glyph (sub-project #4) is `LogoGlyph` alone, monochrome, as a template image.
- Never recolor the ring, add text inside the icon, or use MacPaw or CleanMyMac artwork, icons or colors as reference material.

## Copy voice

- Plain and calm: "We found 18.6 GB to clean", "Your Mac is 16.8 GB lighter", "Nothing is removed until you review it".
- Say what happens to files: "freed now" vs "to quarantine", "undo for N days".
- Use the product's own terms: Smart Scan, Cleanup, History, quarantine. No game words (raid, loot, quest, XP, level, streak, milestone, achievement).
- Sentence case for headlines and buttons; verbs on buttons (Scan, Clean, Restore All…, Done). Use an ellipsis when the button opens a confirmation.

## Layout rules learned from testing the real app

- **Never put `.fixedSize(horizontal: false, vertical: true)` on wrapping text in the main window.** While SwiftUI works out the window's minimum size it measures that text at near-zero width, one character per line, and the whole window gets thousands of points tall: content is centered off-screen and the sidebar and buttons vanish. Use `.lineLimit(n)` with `.frame(maxWidth: .infinity, alignment: .leading)` instead.
- The window minimum is 1200 × 720 (`OpenCleanApp.swift`), so the three-column Cleanup view and the home hero both fit. If you add columns or taller heroes, check them at exactly that size.
- The window uses `.windowStyle(.hiddenTitleBar)`: no title text and no grey toolbar band, with the traffic lights sitting over the sidebar.
- Results list only categories that found something. Categories that are empty because Full Disk Access is missing get a single footnote line, never "0 items · Zero KB" rows.
- Disk capacities use `formatCapacity` ("160 GB", no decimals); file and cleanup sizes use `formatBytes`.
- Buttons must not sit inside a `DisclosureGroup` label (they lose clicks). Build expandable rows from a plain chevron `Button` plus your own content, as `SessionRow` does.
- Long-running work gets its own full screen (`ScanningView`, `CleaningView`): the orb inside a ring, a short status line and the big number. Never overlay a spinner on the round action button.
- Every non-home screen has a way back. Results has "Start over" (chevron, top left, Esc) that discards the results without touching files; summaries have Done.
- Size summaries use `splitSummary(now:quarantine:)`, which leaves out a zero side ("81.9 MB freed now", not "… · Zero KB to quarantine").
- Dates in lists read "Today, 5:13 PM" or "Yesterday, …", never a numeric date. Quarantined sessions show "N days left" with a thin accent progress bar.

## Onboarding

- First launch shows `OnboardingView` instead of the main window until `OnboardingModel.finish` succeeds. It finishes only when every feature step has been seen **and** Full Disk Access is granted; there is no skip. Bump `OnboardingModel.currentVersion` to show it again after a release that changes it; Help → Welcome Tour replays it.
- Each step is visual (≈270 pt tall) + eyebrow + title + one paragraph, on the backdrop of the module it explains. Visuals are decorative (`accessibilityHidden`), loop with `PhaseAnimator` through `LoopingPhases`, and hold a still frame with Reduce Motion.
- A new module gets a new step: add an `OnboardingStep` case (mark it `isFeature`), a page in `OnboardingView.page(for:)` and a visual in `OnboardingVisuals.swift`, and update the design canvas board.
- `CapsuleButtonStyle` dims to 40% when disabled; use `.disabled` rather than hiding a button that is temporarily blocked.

## Accessibility checklist

- Decorative art (`Orb`, `CategoryIcon`, logo) is `accessibilityHidden`; the meaning is in adjacent text.
- Composite rows and cards use `.accessibilityElement(children: .combine)`; custom controls set `accessibilityLabel` and `accessibilityValue` (see `CheckboxButton`).
- Keep the keyboard shortcuts: primary action `.defaultAction`, Stop or Cancel `.cancelAction`.
- Animations are short (≤0.35 s, `.easeInOut` or `.spring`) and only for state changes; nothing loops except the scanning ring.

## Before you finish a UI change

1. No new hard-coded colors outside `Theme.swift`; no XP, score, badge or milestone elements.
2. `swift build` and `make lint` pass; `swift test --filter AppModelTests` if you touched `AppModel` or `CleanupStats`.
3. If the change is visual, update the matching artboard in the design canvas (or tell the user it needs updating), so the canvas and the app don't drift apart.
