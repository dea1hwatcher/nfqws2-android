# DESIGN.md — nfqws2-android WebUI

> The shared source of interface values for the nfqws2-android WebUI.
> Read this whole file before any UI work. Use values strictly by token or role name.
> Add a missing role here and in code tokens together; never introduce undocumented interface values.

Updated: 2026-11-13

## 1. Direction & Art Direction

- **Concept:** High-performance Android network engine control cockpit built with Material 3 Expressive principles.
- **Qualities:** Precise data-density, tactile responsiveness (expressive springs, instant touch feedback), adaptive platform fit (Monet color roles, safe-area insets).
- **Avoid:** Generic AI template card grids, low-contrast washed-out text, text below 12px, unconstrained horizontal layouts.
- **Motion:** Purposeful, physics-grounded transitions with M3 Expressive springs (`cubic-bezier(.34, 1.41, .64, 1)`), zero-duration fallback on `prefers-reduced-motion: reduce` or `data-animations="false"`.
- **Signature Details:** Dynamic Monet system palette extraction from Android wallpaper, stacked corner list groups, interactive real-time reachability diagnostics.

## 2. Code Tokens & Architecture

| Platform / Area | File | Token Naming |
| --- | --- | --- |
| Core tokens & layout | `webroot/css/base.css` | `--ts-*`, `--lh-*`, `--shape-*`, `--dur-*`, `--spring*` |
| Application components | `webroot/css/app.css` | `.card`, `.pill`, `.chip`, `.list-item`, `.hero` |
| Monet color roles | `webroot/js/theme.js` | `--md-sys-color-*` (light & dark schemes) |
| Device insets | `webroot/internal/insets.css` | `--window-inset-top`, `--window-inset-bottom` |

Units: CSS px mapped directly to Android dp (1px = 1dp at baseline mdpi).

## 3. Typography & Font Floor

| Role | Family | Fallback | Weights | Notes |
| --- | --- | --- | --- | --- |
| UI / Text | `Roboto` | `system-ui, -apple-system, sans-serif` | 400, 500, 600, 700 | Full Cyrillic & Latin support |
| Code / Data | `Roboto Mono` | `ui-monospace, 'Cascadia Mono', monospace` | 400, 500 | Configs, logs, raw packet data |

### Absolute Font Floor & Tabular Kerning Invariants
1. **Absolute Font Floor**: No visible UI element may render below **12px**. Inline `font-size: 11px` or classes below 12px are strictly prohibited.
2. **Tabular Kerning**: Dynamic numbers, timers, bitrates, queue drops, packet limits, and ping latencies strictly declare `font-variant-numeric: tabular-nums` to eliminate layout jitter.

### Type Scale

| Role | Token | Size | Line Height | Weight | Tracking | Usage |
| --- | --- | --- | --- | --- | --- | --- |
| Display Large | `--ts-display-large` | 57px | 64px | 400 | -0.25px | Hero metrics |
| Headline Large | `--ts-headline-large` | 32px | 40px | 400 | 0px | Major page headers |
| Headline Medium | `--ts-headline-medium` | 28px | 36px | 400 | 0px | Sub-headers |
| Title Large | `--ts-title-large` | 22px | 28px | 400/500 | 0px | Top app bar, modal titles |
| Title Medium | `--ts-title-medium` | 16px | 24px | 500 | 0.15px | Card titles, section headers |
| Title Small | `--ts-title-small` | 14px | 20px | 500 | 0.1px | Group headers |
| Body Large | `--ts-body-large` | 16px | 24px | 400 | 0.5px | Long-form reading |
| Body Medium | `--ts-body-medium` | 14px | 20px | 400 | 0.25px | Standard list item titles |
| Body Small | `--ts-body-small` | 12px | 16px | 400 | 0.4px | Secondary descriptions, hints |
| Label Large | `--ts-label-large` | 14px | 20px | 500 | 0.1px | Action buttons, tabs |
| Label Medium | `--ts-label-medium` | 12px | 16px | 500 | 0.5px | Chips, badges |
| Label Small | `--ts-label-small` | 12px | 16px | 600 | 0.5px | Compact status pills (Floor = 12px) |

## 4. Color & Elevation

### Semantic Roles (Material 3 Dynamic Palette)
Colors are calculated dynamically by `roles()` in `webroot/js/theme.js` from the selected seed color (system Monet or custom swatch) with strict WCAG AA (>= 4.5:1 for normal text, >= 3:1 for graphical UI objects):

- `var(--md-sys-color-primary)`: Key focal action, selected states, progress indicators.
- `var(--md-sys-color-on-primary)`: High-contrast text on primary buttons.
- `var(--md-sys-color-surface)`: Page canvas background.
- `var(--md-sys-color-surface-container-low)`: Bottom sheets and cards.
- `var(--md-sys-color-surface-container)`: Navbars and dialog bars.
- `var(--md-sys-color-surface-container-high)`: Hover and elevated cards.
- `var(--md-sys-color-on-surface)`: High-contrast primary text (contrast >= 7:1 against surface).
- `var(--md-sys-color-on-surface-variant)`: Secondary captions and icons (contrast >= 4.5:1 against surface).
- `var(--md-sys-color-outline)` / `var(--md-sys-color-outline-variant)`: Hairlines and container dividers.
- `var(--md-sys-color-error)` / `var(--md-sys-color-on-error)`: Destructive states, drop warnings.

### Surface Depth & Input Borders (Luma Standard)
- Cards and containers separate layers through background luminance stepping (+2%..+4% Luma).
- Input fields, textareas, and select elements strictly preserve defined boundaries and visible focus rings (`focus-visible: outline 2px solid var(--md-sys-color-primary)`).

## 5. Spacing & Geometry

- **Scale:** 4px, 8px, 12px, 16px, 24px, 32px, 48px, 64px (`--gap: 12px`).
- **Proximity Ladder:** Inside a control (4–8px) < between items in a group (8–12px) < between groups/cards (16–24px) <= container padding (16px phone / 24px desktop).
- **Hit-Target Floor:** All interactive controls (buttons, icon buttons, switches, chips, list items) strictly maintain a hit target of at least **32×32px** on desktop and **48×48dp** on touch devices.
- **Stacked Corners:** Sibling list items inside `.list` containers share 4dp inner corners while the first and last items feature 16dp outer rounded corners (`--shape-large`).

## 6. Shapes & Radii

| Role | Token | Value | Usage |
| --- | --- | --- | --- |
| Extra Small | `--shape-extra-small` | 4px | Inner stacked corners in lists |
| Small | `--shape-small` | 8px | Dropdown chips, inner controls |
| Medium | `--shape-medium` | 12px | Compact cards |
| Large | `--shape-large` | 16px | Strategy cards, outer list corners |
| Extra Large | `--shape-extra-large` | 28px | Hero status banner, bottom sheet top |
| Pill / Full | `--shape-full` | 9999px | Status pills, search bar, switches |

## 7. Motion & Interaction

- **Expressive Springs:**
  - Standard Spring: `cubic-bezier(.34, 1.41, .64, 1)`
  - Strong Spring: `cubic-bezier(.28, 1.62, .55, .92)`
  - Standard Ease: `cubic-bezier(.2, 0, 0, 1)`
- **Durations:** 50ms (extra-short), 100ms (short), 250ms (medium), 350ms (medium-long), 450ms (long).
- **Modal Chassis Invariants:**
  - Bottom sheet ceiling: `max-height: 86vh` with `flex-1 min-h-0 overflow-y-auto`.
  - Fixed header and actions without layout shift during scroll.
  - Backdrop and `Escape` key dismissal contract.
- **Accessibility:** Reduced-motion media query `@media (prefers-reduced-motion: reduce)` immediately clamps durations to 1ms without removing state visibility.
