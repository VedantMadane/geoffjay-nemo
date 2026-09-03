---
type: Plan
title: Tailwind-style `<div>` primitives and utility-class styling
description: A `<div>` (and sibling primitives) whose `class`/`classes` attribute carries Tailwind-style utilities mapped at runtime to GPUI's fluent div API — letting SFC authors build reusable layout primitives without a Rust component.
tags: [components, styling, gpui, sfc, planning]
timestamp: 2026-08-13T00:00:00Z
---

# Tailwind-style `<div>` primitives and utility-class styling

## The question

Can an SFC author write:

```xml
<div classes="flex flex-col gap-3">
  <div classes="bg-red" />
  <div classes="bg-blue" />
  <div classes="bg-green" />
</div>
```

using "raw" GPUI layout primitives instead of only the packaged components
(`<stack>`, `<panel>`, …) Nemo registers today?

**Answer: no, today — but yes, and it is straightforward to add.**

Today's rendering has no `<div>` component type. `render_component`
(`crates/nemo/src/app.rs:780`) dispatches on `component_type` against ~60
registered names; the `_` fallback arm (`:1341`) renders a bare
`div().flex().flex_col()` with children but is never intentionally reached
(it exists for unknown types). Styling is attribute-based
(`width="820"`, `padding="16"`, `background="#f00"`), applied uniformly by
`apply_layout_styles` (`:529`) and constrained to the
[universal style attributes](../../crates/nemo-registry/src/schema_surface.rs:47).
There is no parser that converts a space-separated utility-class string
(`"flex flex-col gap-3 bg-red"`) into GPUI's fluent `Div` builder calls.

## Why it is possible

GPUI's `div()` returns a `Div` — a **runtime fluent builder** whose methods
(`.flex()`, `.flex_col()`, `.gap(px(12.))`, `.items_center()`, `.bg(hsla)`,
`.w(px(64.))`, `.p(px(16.))`, `.rounded(px(8.))`, …) consume and return
`Self`. You can thread a `Div` through a loop at runtime, applying each
utility conditionally:

```rust
let mut el = div().id(SharedString::from(id));
for util in classes.split_whitespace() {
    el = apply_utility(el, util, cx);
}
el.children(children).into_any_element()
```

No compile-time codegen is needed. The entire feature is a **string→method
mapping table** plus a `<div>` component registration. GPUI's `Div` already
exposes every layout/decoration primitive the utilities map to — the same
methods `Stack`/`Panel`/`apply_layout_styles` already call.

## What already exists (and is reused)

| Existing machinery | Role in this plan |
|---|---|
| `apply_layout_styles` (`app.rs:529`) | The universal-attribute style wrapper. A `<div>` can either use it (attributes) *or* the class parser (utilities) — or both, with classes applied to the inner div and geometry attrs on the wrapper. |
| `universal_style_attributes` (`schema_surface.rs:47`) | The canonical attr list the linter/schema exporter skip as known. A `classes`/`class` attr joins this list. |
| `resolve_color` / `resolve_theme_color` (`components/mod.rs:80`/`:110`) | Color resolution for `bg-*`, `text-*`, `border-*` utilities — reused verbatim. |
| `apply_shadow` / `apply_rounded` (`components/mod.rs:164`/`:178`) | Shadow/rounding presets — reused for `shadow-*`/`rounded-*` utilities. |
| `flex_is_truthy` / `container_grows` (`components/mod.rs:61`/`:69`) | Flex-growth predicates — reused for `flex-1`/`flex-grow`. |
| SFC `<style>` folding (`fold_sfc_styles`, `runtime.rs:2622`) | Already maps CSS names → nemo attrs. A class-selector extension (`.foo { … }`) folds onto `class="foo"` nodes. |
| Four-file component workflow | `<div>` follows it exactly: `components/div.rs` + `mod.rs` + `builtins.rs` + `app.rs` render arm. |
| `NemoComponent` derive | `<div>` uses `#[derive(IntoElement, NemoComponent)]` with `#[children]` + `#[source]`, like `Stack`/`Panel`. |

## Design

### The utility-class parser

A new module `crates/nemo/src/components/class_parser.rs` exports:

```rust
/// Apply one space-separated class string to a Div, returning the styled Div.
pub(crate) fn apply_classes(
    mut el: Div,
    classes: &str,
    cx: &App,
) -> Div
```

It splits on whitespace and dispatches each token through a match. Unknown
tokens warn and are skipped (same posture as `fold_sfc_styles` unknown-prop
handling). The match is organized by category:

```
flex / flex-col / flex-row / inline-flex / hidden / block
flex-1 / flex-grow / flex-shrink / flex-shrink-0 / flex-none
gap-<n> / gap-x-<n> / gap-y-<n>
items-center / items-start / items-end / items-stretch / items-baseline
justify-center / justify-start / justify-end / justify-between / justify-around / justify-evenly
w-<n> / w-full / w-auto / w-screen
h-<n> / h-full / h-auto / h-screen
min-w-<n> / min-w-0 / max-w-<n> / min-h-<n> / max-h-<n>
p-<n> / px-<n> / py-<n> / pt-<n> / pr-<n> / pb-<n> / pl-<n>
m-<n> / mx-<n> / my-<n> / mt-<n> / mr-<n> / mb-<n> / ml-<n> / mx-auto
border / border-<n> / border-x / border-y / border-t / border-r / border-b / border-l
border-<color> / border-color-<color>
rounded / rounded-<preset> / rounded-full / rounded-none
bg-<color> / bg-transparent
text-<color> / text-<size> / text-center / text-left / text-right
font-bold / font-medium / font-normal / font-light
shadow / shadow-<preset>
opacity-<pct>
absolute / relative / fixed / static / inset-0 / inset-x-0 / inset-y-0
overflow-hidden / overflow-y-scroll / overflow-x-scroll / overflow-auto
cursor-pointer / cursor-default
```

`<n>` is a spacing-scale integer (see below). `<color>` resolves through
`resolve_color` (so `bg-red` → a palette color, `bg-theme.danger` →
`resolve_theme_color`, `bg-#4c566a` → hex). `<preset>` reuses the existing
shadow/rounded presets. `<size>` maps to the `nemo-tokens` font-size scale.

### The spacing scale

Tailwind's spacing scale is `1 unit = 0.25rem = 4px` (at 16px base). Nemo
already has a token-based spacing system (`nemo-tokens::Space`) used by
`gap_t(Space::Xs)`, `px_t(Space::Sm)`, etc. The utility parser uses a
**pixel-based scale** for determinism:

| Utility suffix | Pixels |
|---|---|
| `-0` | 0 |
| `-px` | 1 |
| `-0.5` | 2 |
| `-1` | 4 |
| `-1.5` | 6 |
| `-2` | 8 |
| `-3` | 12 |
| `-4` | 16 |
| `-5` | 20 |
| `-6` | 24 |
| `-8` | 32 |
| `-10` | 40 |
| `-12` | 48 |
| `-16` | 64 |
| `-20` | 80 |
| `-24` | 96 |

This is a fixed lookup table, not a multiplier, so it matches Tailwind's
non-linear scale exactly. Arbitrary values use bracket syntax: `w-[320px]`,
`p-[13px]`, `gap-[0.625rem]` (rem → px at 16px base).

**Future:** optionally route the named scale through `nemo-tokens::Space` so
`gap-4` respects a configurable base unit. Phase 1 ships the fixed table for
predictability; the token integration is a Phase 3 refinement.

### The color palette

`bg-red`, `text-blue`, `border-green` need concrete colors. Two strategies,
**both supported**:

1. **Nemo theme refs** (primary): `bg-theme.primary`, `text-theme.text_muted`,
   `border-theme.border` — resolved by `resolve_theme_color`. These already
   work and track the active theme.
2. **Named palette** (secondary): a small Tailwind-inspired palette
   (`red`/`orange`/`amber`/`yellow`/`lime`/`green`/`emerald`/`teal`/`cyan`/
   `sky`/`blue`/`indigo`/`violet`/`purple`/`fuchsia`/`pink`/`rose`/`slate`/
   `gray`/`zinc`/`neutral`/`stone`), each at `-50`–`-950` shades, stored as a
   const lookup table in `class_parser.rs`. `bg-red` = `bg-red-500` (the 500
   shade is the default when no shade suffix is given). Hex values
   (`bg-#4c566a`) and `bg-transparent` also work.

The palette is **static** (not theme-aware) — it matches Tailwind's
behavior. For theme-aware coloring, use `bg-theme.*`. This split is
documented in the component doc and the SFC pattern.

### The `<div>` component

```rust
// crates/nemo/src/components/div.rs
#[derive(IntoElement, NemoComponent)]
pub struct Div {
    #[property]
    classes: Option<String>,   // "flex flex-col gap-3"
    #[source]
    source: nemo_layout::BuiltComponent,
    #[children]
    children: Vec<AnyElement>,
}

impl RenderOnce for Div {
    fn render(self, _window: &mut Window, cx: &mut App) -> impl IntoElement {
        let mut el = div().id(SharedString::from(self.source.id.clone()));
        if let Some(classes) = &self.classes {
            el = crate::components::class_parser::apply_classes(el, classes, cx);
        }
        // Also apply universal layout attrs (width, height, flex, …) so
        // <div classes="bg-red" width="100"> works — attributes and classes
        // compose. The wrapper from apply_layout_styles handles geometry;
        // classes handle the inner div's flex/decoration.
        el.children(self.children).into_any_element()
    }
}
```

**Attribute + class composition:** `apply_layout_styles` runs on *every*
component after `render_component` returns, so a `<div classes="flex gap-3"
width="200" bg="theme.surface">` gets the `width`/`bg` from the universal
wrapper *and* the `flex`/`gap` from classes. To avoid double-application,
`apply_layout_styles` skips decoration props (padding/border/rounded/shadow/
background) for `div` the same way it does for `panel` — the class parser
owns those when classes are present. Geometry (width/height/margin/flex)
stays on the wrapper so both paths compose cleanly. If `classes` is absent,
`<div>` behaves like the existing `_` fallback (a plain flex column
container).

### Sibling primitives

`<span>`, `<section>`, `<aside>`, `<header>`, `<footer>`, `<main>`, `<nav>`
are **aliases** — they register as separate component types but dispatch to
the same `Div::new(component)` arm (or a thin wrapper that sets a default
`classes` if none is provided, e.g. `<section>` defaults to `flex flex-col`).
This gives authors semantic HTML-like tags in SFC templates without N new
render paths. Phase 2.

### SFC `<style>` integration

The existing `<style>` folding (`fold_sfc_styles`) supports type (`button {}`)
and `#id` selectors. **Class selectors** (`.my-class {}`) are a natural
extension and the bridge to utility-class authoring:

```nemo
<!-- components/hero.nemo -->
<template name="hero">
  <div classes="hero-container">
    <div classes="hero-title"><slot name="title" /></div>
    <div classes="hero-body"><slot /></div>
  </div>
</template>
<style>
  .hero-container { display: flex; flex-direction: column; gap: 12px; padding: 24px; }
  .hero-title { font-size: 20px; font-weight: bold; }
  .hero-body { padding: 16px; }
</style>
```

`fold_sfc_styles` matches a `.class-name` selector against any template node
whose `classes` string *contains* that token (space-separated check), then
folds the rule's declarations onto the node as inline attrs (only where
absent, same precedence as today: `<style>` → inline attr → instance attr).
This means **class-based `<style>` rules and utility classes compose**: a
node can carry `classes="hero-container flex gap-3"` where `hero-container`
is resolved from `<style>` and `flex gap-3` are utilities applied at render.

Phase 3 extends `parse_style_rules` (`runtime.rs`) with a `.class` selector
arm and `display`/`flex-direction`/`gap`/`font-size`/`font-weight` CSS
property normalization (mapping to the same nemo attrs the utilities use).

## Phasing

### Phase 1 — `<div>` + core utility parser

**Scope:** register `<div>` as a built-in container; implement the utility
parser for the highest-frequency utilities; ship the spacing scale and color
palette.

**Files:**
* `crates/nemo/src/components/div.rs` — the `Div` component (above).
* `crates/nemo/src/components/class_parser.rs` — `apply_classes()` + the
  utility match table + spacing scale + color palette const table.
* `crates/nemo/src/components/mod.rs` — `mod div; mod class_parser;` +
  `pub use div::Div;` + re-export `apply_classes`.
* `crates/nemo-registry/src/builtins.rs` — register `"div"` in
  `register_layout_components` with a `ConfigSchema` declaring `classes`
  (string, optional) + the universal attrs.
* `crates/nemo-registry/src/schema_surface.rs` — add `classes` to
  `universal_style_attributes` (or a new `class_attributes` list) so the
  linter/schema exporter recognize it on any component, not just `<div>`.
* `crates/nemo/src/app.rs` — add the `"div"` render arm
  (`Div::new(component.clone()).children(children).into_any_element()`);
  extend `apply_layout_styles` to skip decoration props for `div` when
  `classes` is present (same pattern as `is_panel`).

**Utility coverage (Phase 1):** flex/flex-col/flex-row/flex-1/flex-shrink-0,
gap-N, items-*, justify-*, w-N/h-N/w-full/h-full, p-N/m-N (all sides),
border/border-N, rounded-*, bg-color, text-color, shadow-*. This covers the
user's example and ~80% of real-world layout utility usage.

**Acceptance:** `nemo validate --strict` accepts `<div classes="flex
flex-col gap-3">…</div>`; a live render shows a vertical flex column with
12px gap and colored child divs; `nemo schema` includes `div` in its
component list.

### Phase 2 — Extended utilities + sibling primitives

**Scope:** complete the utility table (text sizing, font weight, opacity,
position, overflow, cursor, min/max sizing, arbitrary `[val]` syntax) and
register `<span>`/`<section>`/`<aside>`/`<header>`/`<footer>`/`<main>`/
`<nav>` as `Div` aliases.

**Files:** `class_parser.rs` (extended match arms); `div.rs` (no change —
aliases dispatch here); `builtins.rs` (register alias types pointing at the
same schema); `app.rs` (alias arms: `"span" | "section" | … => Div::new(…)`).

### Phase 3 — SFC `<style>` class selectors

**Scope:** extend `fold_sfc_styles` / `parse_style_rules` with `.class`
selectors and the CSS properties that map to utility-equivalent attrs
(`display`→`flex`, `flex-direction`→`flex_col`/`flex_row`, `gap`,
`font-size`, `font-weight`).

**Files:** `crates/nemo/src/runtime.rs` (`fold_sfc_styles`,
`parse_style_rules`, `normalize_style_prop`); `nemo-registry/src/schema_surface.rs`
(extend the fold allowlist with the new attrs).

**Acceptance:** the `hero.nemo` example above validates and renders
correctly; `nemo build` compiles it; `test_sfc_style_folding_and_precedence`
gains a class-selector case.

### Phase 4 — Token-aware spacing (optional)

Route the named spacing scale (`gap-4`, `p-6`) through `nemo-tokens::Space`
so a configurable base unit scales all utilities. Low risk, additive; ships
only if the fixed-pixel scale proves limiting for theme variation.

## Cross-cutting risks & decisions

* **`apply_layout_styles` vs classes.** Both run; they must not double-apply
  decoration. The `is_panel` skip pattern extends to `is_div_with_classes`:
  when a `<div>` has `classes`, the class parser owns padding/border/rounded/
  shadow/background; `apply_layout_styles` still handles geometry
  (width/height/margin/flex) on the wrapper. A `<div>` *without* `classes`
  uses `apply_layout_styles` for everything (identical to today's behavior).
  Documented in [layout sizing and centering](../patterns/layout-sizing-and-centering.md).

* **Performance.** `apply_classes` runs every render for every `<div>`. The
  match is O(n) in the number of utility tokens (typically 3–8). No
  allocation beyond `split_whitespace()` (which is zero-alloc on the input
  slice). If profiling shows this is hot, a `HashMap<&str, Utility>` lookup
  or a compiled-style cache (hash the class string → pre-built `Div`-shaping
  closure) can be added — but the match is almost certainly negligible next
  to GPUI's layout pass.

* **Color palette drift.** The static palette in `class_parser.rs` is
  hand-maintained. It should be generated from `nemo-tokens` if/when the
  tokens crate gains a color-palette section. Until then, a const table with
  a test asserting the count is sufficient.

* **`classes` on non-`<div>` components.** The `classes` attribute is
  universal (added to `universal_style_attributes`), so `<stack classes="…">`
  or `<panel classes="…">` also parse utilities. This is powerful but
  potentially confusing (a `<stack>` already has `direction`/`spacing`/
  `align`/`justify` attrs that overlap with `flex`/`flex-col`/`items-*`/
  `gap-*` utilities). **Decision:** `classes` on non-div components is
  allowed but **utilities override component-specific attrs** (classes are
  applied after the component's own `render` builds its base div, so later
  `.flex_row()` calls win). Document the precedence: component attrs →
  `apply_layout_styles` wrapper → `classes` utilities (innermost wins for
  conflicting properties, since classes apply to the inner div, the wrapper
  is outer). Phase 1 supports `classes` on `<div>` only; Phase 2 generalizes.

* **Unknown utilities.** Same posture as unknown `<style>` properties: warn
  and skip. The linter (`nemo validate --strict`) can optionally check
  utilities against the known set in a later phase.

* **Interaction with `nemo build`.** The class parser is a render-time
  concern, not a parse/compile-time one — `classes` is just a string
  attribute that survives the build pipeline. No build-system changes.

## Relationship to existing plans

* **[Design tokens](design-tokens.md):** the spacing scale and color palette
  should eventually source from `nemo-tokens`. Phase 1 ships a fixed table
  for determinism; Phase 4 (optional) routes through tokens. The palette
  table can be generated by `xtask design-export` in a future iteration.
* **[SFC components](sfc-components.md):** this plan makes SFC templates
  dramatically more expressive — authors can build layout primitives
  (`<div>`) instead of composing `<stack>`/`<panel>` for every container.
  The `<style>` class-selector extension (Phase 3) is a natural SFC Phase 7.
* **[Layout sizing and centering](../patterns/layout-sizing-and-centering.md):**
  the flexbox-native rules documented there apply identically to `<div
  classes="flex …">` — the utilities call the same GPUI methods. The pattern
  doc should be updated to note `<div>` as an alternative to `<stack>`.
* **[Declarative children migration](declarative-children-migration.md):**
  orthogonal; `<div>` takes generic children like `<stack>`.

## Critical files

| File | Role |
|---|---|
| `crates/nemo/src/components/div.rs` | **New.** The `Div` component — `NemoComponent` derive, `classes` property, `#[children]`, `RenderOnce`. |
| `crates/nemo/src/components/class_parser.rs` | **New.** `apply_classes(Div, &str, &App) -> Div` — the utility→GPUI mapping table, spacing scale, color palette. |
| `crates/nemo/src/components/mod.rs` | Module registration + re-exports. |
| `crates/nemo-registry/src/builtins.rs` | Register `"div"` (+ aliases in P2) in `register_layout_components`. |
| `crates/nemo-registry/src/schema_surface.rs` | Add `classes` to the universal surface. |
| `crates/nemo/src/app.rs` | `"div"` render arm; `apply_layout_styles` skip for div-with-classes. |
| `crates/nemo/src/runtime.rs` | Phase 3: `fold_sfc_styles`/`parse_style_rules` class-selector extension. |

## Verification

* **Unit (class_parser):** `apply_classes` on a `div()` with
  `"flex flex-col gap-3 bg-red"` produces a `Div` with the same method
  chain as `div().flex().flex_col().gap(px(12.)).bg(red_hsla)`. Test each
  utility category; test unknown-token warning (no panic); test arbitrary
  value `[320px]`/`[0.5rem]` parsing; test color resolution (palette,
  theme ref, hex).
* **Unit (div component):** `Div::new(component).children(children).render()`
  with and without `classes`; verify children render; verify
  `apply_layout_styles` skip logic.
* **End-to-end:** an `examples/tailwind-div/` app (or extend `examples/sfc/`)
  with the user's three-colored-div example, validated by `nemo validate
  --strict` and rendered in a live GPUI window. Confirm: vertical flex
  column, 12px gap, three colored divs stacking vertically.
* **SFC integration (Phase 3):** `hero.nemo` with class selectors in
  `<style>` validates, builds, and renders with the folded styles.
* **Schema:** `nemo schema` includes `div` with `classes` in its property
  list.

## Knowledgebase updates required when implemented

* [Components](../concepts/components.md) — add a "Utility-class primitives"
  section: `<div>`/`<span>`/etc., the `classes` attribute, and the parser.
* [Layout sizing and centering](../patterns/layout-sizing-and-centering.md)
  — note `<div classes="flex …">` as an alternative to `<stack>`.
* [Single-file components](../patterns/single-file-components.md) — update
  the `<style>` section to cover class selectors (Phase 3).
* [Configuration](../concepts/configuration.md) — document the `classes`
  universal attribute and utility-class syntax.
* A new [pattern](../patterns/index.md) for utility-class authoring.
* [Roadmap](roadmap.md) — move this item as phases land.