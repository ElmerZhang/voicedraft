# Interface design

VoiceDraft keeps its own visual language instead of a stock macOS Settings look: a floating light-gray sidebar, large page titles, white cards with hairlines, key caps for shortcuts, pill filters, and a dark floating recording capsule. This page defines that language so every surface stays consistent. Tokens and shared components live in `Sources/VoiceDraft/DesignSystem.swift` (`VD` namespace and `VD*` views). Views must use them instead of hard-coded colors, radii or font sizes.

## Principles

- **One system.** Main pages, the settings overlay, sheets, onboarding and the HUD share the same tokens and components. No per-file palettes.
- **Follows the system appearance.** Every color token adapts to light and dark mode; the light values are the original reference design. Nothing forces a color scheme except the HUD, which is always dark.
- **Content first.** Decoration never pushes the working area below the fold. Marketing-style copy appears only in the Home hero and the About tab.
- **Native controls, custom chrome.** Toggles, pickers, text fields, sheets, dialogs and menus are native; containers, navigation and the HUD are custom.
- **Readable at a glance.** Every state the user must notice (recording, locked, processing, error, permission missing) is visible as text or an icon, never only as a tooltip or a color.
- **Localizable.** Fixed widths only where the content is a control; text always has room to wrap, and nothing relies on English word length.

## Tokens

| Group | Token | Light | Dark | Use |
| --- | --- | --- | --- | --- |
| Color | `ink` | #171719 | #F0F0F5 | primary text, prominent pill fill |
| | `canvas` | white | #1E1E20 | window content background, sheet background |
| | `surface` | #F7F7F8 | #2A2A2D | sidebar, settings rail, shaded boxes, pill track |
| | `elevated` | white | #343437 | cards, chips, key caps, selected pill |
| | `field` | #F9F9FA | white 6% | text editor and search backgrounds |
| | `line` | black 6.5% | white 9% | hairlines |
| | `selection` | black 7% | white 10% | selected navigation row |
| | `accent` | #2657F5 | #6B91FF | links, active badge, record button, toggles (tint) |
| | `accentSoft` | accent 12% | accent 22% | selected mode pill |
| | `recording` | #D63F38 | #F26157 | stop button, recording status |
| | `success` / `warning` / `danger` | system | system | notices, permission status, errors |
| | `onAccent` · `scrim` · `shadow` · `washStart`/`washEnd` | white · black 36% · black 18% · tints | white · black 55% · black 50% · dark tints | icons on accent fills, modal dimming, panel shadow, Home card wash |
| | `hudPanel` | #161617 | same | HUD fill |
| Radius | `control` 8 · `chip` 12 · `card` 16 · `panel` 22 | | | buttons/fields · chips, rows, notices · cards, sheets · sidebar, settings overlay, HUD cards |
| Space | 4 · 8 · 12 · 16 · 24 · 32 | | | the only spacing values between elements |
| Type | `hero` 40 bold · `pageTitle` 30 bold · `sheetTitle` 20 semibold · `sectionTitle` 19 semibold · `cardTitle` 15 semibold · `body` 14 · `detail` 12 · `footnote` 11 · `mono` 12 | | | |

Secondary text uses `.secondary`; tertiary hints use `.tertiary`. Error text uses `danger`, never orange or brown. Minimum text size is 11 (10 inside the HUD capsule only).

## Components

| Component | Use |
| --- | --- |
| `VDSurface(style:)` | Every card. `.plain` for content cards, `.shaded` for informational boxes. Padding 20. |
| `VDPageHeader(title, subtitle:, trailing:)` | The single title of each main page and settings tab. Never stack two titles. |
| `VDSectionHeader(icon:title:)` | Groups inside settings tabs and long pages. |
| `VDSettingRow(title, detail:, control:)` | Every preference: text left, native control right (switch toggles, pickers, buttons). |
| `VDKeyCaps(keys:)` | Every shortcut display: Home, Settings, onboarding, Help. Never show shortcuts as monospaced text. |
| `VDFilterPills` | Segmented filters on History and Vocabulary. |
| `VDBadge` | Status such as Active. |
| `VDIconButton` | Every icon-only action: 28pt target, tooltip and accessibility label. |
| `VDEmptyState` | Lists and grids with nothing to show: History, Vocabulary, Models, styles, routing rules. |
| `VDInlineNotice(kind:)` | Transient feedback and warnings inside pages, sheets and the settings overlay. |
| `.vdPill` / `.vdPillSecondary` | Page-level primary action (New word, Add profile). Sheet and dialog footers use `.borderedProminent` for the confirming action. |
| `.vdEditorBox()` | Every `TextEditor`, so inputs look like inputs. |
| `.vdSheet(width:)` | Every sheet: padding 24, fixed width, canvas background, accent tint. |

Sheet layout: `sheetTitle`, optional detail, content, then a footer `HStack` ordered destructive action (`.tint(VD.Palette.danger)`; the sheet's accent tint would otherwise color it like Cancel) · `Spacer` · secondary actions · Cancel · confirming `.borderedProminent` action. Escape cancels (`.cancelAction`) and Return confirms (`.defaultAction`). Return inside a `TextEditor` still inserts a newline.

## Hit targets

The clickable area of a control must match the shape the user sees.

| Rule | Detail |
| --- | --- |
| Minimum size | Icon-only actions use `VDIconButton` (28×28pt). Text pills and overflow triggers are at least 28pt tall. Nothing interactive is smaller than about 22pt in either dimension, including text-only links. |
| Shape the label | With `.plain` or a custom `ButtonStyle`, SwiftUI hit-tests only drawn content. Padding, `Spacer`s and `.clear` or hover-only backgrounds are not clickable. Apply `.contentShape(…)` after the padding and background, matching the visible shape (`Capsule`, `RoundedRectangle`, `Circle`). Shared components already do this. |
| Overflow menus | Use `VDOverflowMenu`. It uses `.menuStyle(.button)` with `.buttonStyle(.plain)`. `.borderlessButton` wraps the label in an AppKit pop-up that ignores the label frame and shrinks the hit area to the glyph, about 26×15pt. |
| Rows and navigation | A selectable row, nav item or chip is one button whose whole rounded rectangle, including the empty area after the label, is the target. |
| Row actions | Keep row actions in the tree and visible as subdued `VDIconButton`s. Do not insert them on hover. If a reveal is ever needed, use opacity so the layout and hit area stay stable. |
| No nested buttons | A row or card that is itself a button contains no other buttons; put secondary actions in its context menu. A card with inner buttons (model profiles) is not itself clickable. |
| Switches | Only the native `Toggle` switch toggles. The row text does not. |
| Disabled | A disabled control must look disabled. `.plain` and native styles dim automatically; custom styles read `isEnabled` (see `VDPillButtonStyle`). |

## Surfaces

**Window and sidebar.** Full-size content view with a hidden title so the sidebar reaches the top edge; the brand row leaves room for the traffic lights. Sidebar: `surface` fill, `panel` radius, navigation rows with `selection` fill and the selected accessibility trait. Footer icon buttons open Settings, Sync, About and Help. Only Home, History and Vocabulary are main pages; Models and Sync open as settings tabs.

**Home.** Hero (`hero`, up to two lines), optional Fn conflict notice, the shortcut card (five key-cap rows: Dictate, Translate, Edit selection, Ask anything and Insert last result, each with a one-line detail; enabled bindings only; informational only) beside the stats card, then the testing workspace: mode pills, record card (64pt record button, status text, elapsed time, level meter), input device row, model chain row with a Configure link that opens Settings → Models, selection box for Edit/Ask, transcript and result editors side by side, and a permissions row that states the current Accessibility status and offers the Allow button only when needed. When on-screen context and its OCR switch are both on, the same card adds a Screen Recording line with the same icon, title and detail layout and an Allow button when missing. No decorative use-case cards and no concatenated shortcut text line.

**History.** Header with the “Only on this Mac” label and an overflow menu (keep history toggle, clear history). When history is off, an inline notice says so. Filter pills and search on one row. Entries grouped by day in a plain card list with 28pt action buttons; the expanded original transcript sits in a shaded box. Privacy sentence as a footnote under the list.

**Vocabulary.** Header with the New word pill and an overflow menu for bulk add. Import, export and context extraction stay as buttons in their own section because they own a review sheet. "Extract from <app>" names the last external app; with none it reads "Extract from screen" and is disabled, and an excluded app disables it, each with a help text giving the reason. Its review sheet reuses the C6 layout with screen copy and "Screen · Accessibility" / "Screen · OCR" source labels. One control row: filter pills, status picker, master enable toggle, search. Chip grid, then the learning box as a shaded surface with setting rows, then the model projection disclosure and the sync footnote.

**Settings overlay.** In-window modal over a scrim, `panel` radius. Rail with the selected trait. Each tab has exactly one `VDPageHeader`. General is ordered Shortcuts · Recording · On-screen context · Audio · Language · General · Updates. On-screen context has the master switch, then Recognition hints, Writing reference and the OCR switch (dimmed while the master is off), a Screen Recording row with an Allowed badge or Allow button only while OCR is on, the "Never read these apps" list (bundle IDs in mono; built-ins carry a Built in badge and no delete; user rows have a trash `VDIconButton`) with a `SingleLineField`, a Running apps menu and an Exclude button, and a privacy footnote. Shortcuts starts with the hold/tap hint and lists every action, including Insert last result with its one-line detail as the row's `detail`. Each row's trailing content is, left to right: the key caps as one plain button (the whole caps area, at least 32pt tall with a `contentShape`, starts recording; disabled bindings show their caps at 40% opacity), a `VDOverflowMenu` with Use Fn alone and Use default shortcut (naming the default's keys), and the enable `VDSwitch`. While recording, the caps become an `accentSoft` field with an accent border showing the modifiers held right now followed by “…”, and a footnote-size accent caption “Press keys · Esc cancels” appears under the row. Escape, clicking the field again, opening another row or leaving the tab cancels and reinstalls the global shortcuts. A rejected combination keeps the previous binding and shows a footnote-size `danger` line under that row (“Already used by Dictate”, “Add Control, Option or Command, or use Fn”); recording continues so another combination can be tried. Rejections never use the global error banner. Below the rows a secondary footnote explains Fn chords, then Restore default shortcuts sits right-aligned, then the Fn status card. Every section a `VDSectionHeader` with `VDSettingRow`s and switch toggles. Models and Sync reuse their editors without a second title; Sync fields have visible labels (server address, access token, passphrase), and connection status is a shaded box with a status dot. Personalization groups styles, per-app routing, writing style prompt and translation target; the explicit save action sits under the fields it saves.

**Sheets.** Profile editor, vocabulary term, bulk add, import review and style editor follow the sheet layout above; every field has a visible label.

**Onboarding.** Fixed 740×620. A step indicator (dots plus “n / m”), one title per step, content in surfaces: models step reuses the profile cards; permissions step shows a row per permission (Microphone, Accessibility, and the optional Screen Recording row, which never turns on any on-screen option) with a status badge (allowed in `success`, missing in `warning`) and an Allow button when missing; the last step shows the dictation shortcut as large key caps with hold/tap guidance.

**Recording HUD.** Always dark, `hudPanel` fill over a thin material, bottom-center of the screen with the mouse. The compact capsule shows cancel, a level waveform with the elapsed time (and a lock icon when locked, and an 8pt `text.viewfinder` glyph when on-screen context is in use) under it, and finish. With on-screen context, the waveform's accessibility label includes "On-screen context" and the live card's right-hand header reads "On-screen context · N terms" while recording. No screen text is ever shown in the HUD. Processing replaces the waveform with a spinner and a label. Live transcript and result cards share the capsule chrome. Result and failure cards have a 28pt close target, a pill Copy action, and failure adds an Open VoiceDraft link. A failure with no transcript text is a compact notice card sized to its header, error line and footer. Escape closes a visible card when no run is active. The panel fades in, fades out, and animates between sizes; it never steals focus. The status item icon reflects recording. Its menu has Open VoiceDraft, Start / stop dictation, Insert last result, Extract words from this screen… (disabled while busy; opens Vocabulary's review sheet for the app that was frontmost) and Quit.

## Localization rule

New copy goes into `Desktop.strings` through `D("…")` in all eight catalogs (`scripts/check-desktop-localizations.py` enforces parity). `F(english, chinese)` is only acceptable for existing call sites; do not add new ones.

## Verification

`VOICEDRAFT_CAPTURE_PREVIEWS`, `VOICEDRAFT_CAPTURE_ONBOARDING`, `VOICEDRAFT_CAPTURE_HUD_PREVIEWS` and `VOICEDRAFT_CAPTURE_SHEETS` render every surface in isolated preview mode. `VOICEDRAFT_PREVIEW_APPEARANCE=dark` renders the same captures in dark mode. Inspect both before shipping a visual change and keep the captures under `dist/`.
