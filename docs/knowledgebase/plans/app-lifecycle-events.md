---
type: Plan
title: Application lifecycle events
description: A structured set of lifecycle events fired by the runtime so scripts, plugins, and tooling (screenshots, tests, CI) can react to configuration loading, readiness, rendering, and teardown — replacing the fragile --settle-ms timing hack with deterministic signals.
tags: [config, runtime, scripts, plugins, screenshots, planning]
timestamp: 2026-08-05T00:00:00Z
---

# Application lifecycle events

The runtime currently has two ad-hoc lifecycle hooks: `<script on-load="…">`
(fired once after the layout is built) and route-level `on-enter`/`on-leave`
(fired on router navigation). Everything else — config start/finish, layout
ready, first paint, teardown — is invisible to scripts and plugins.

The immediate motivation is `nemo screenshot`: it guesses with `--settle-ms`
because there is no signal for "the app has finished loading, data sources
have delivered their first values, and the first frame has been drawn." A
deterministic ready signal lets the screenshot command (and tests, and CI)
capture at the right moment instead of sleeping.

But the problem is broader. Script authors can't run initialization logic at
the right time (before layout? after layout? after data?), plugins can't
observe readiness, and there's no teardown hook for cleanup. A structured set
of lifecycle events fixes all of these.

# Existing hooks (what we have today)

| Hook | Where | Fired by | Timing |
|------|-------|----------|--------|
| `on-load` (`<script on-load="fn">`) | `App::new` (`app.rs:84`) | `runtime.call_handler` | Once, after layout is built, before first paint |
| `on-enter` (`<route on-enter="fn">`) | `apply_pending_navigations` (`runtime.rs:1299`) | `runtime.call_handler` | When a route becomes active |
| `on-leave` (`<route on-leave="fn">`) | `apply_pending_navigations` (`runtime.rs:1387`) | `runtime.call_handler` | When a route is navigated away from |

These are string handler names dispatched through `call_handler`. They are
synchronous, run on the main thread, and are the only lifecycle surface.

# The problem

`nemo screenshot` needs to know when the app is fully rendered. Today it
polls: it pumps data updates in 50ms slices for `--settle-ms` (default 500ms,
but SVG asset loading needs 2–3s), explicitly drives `Window::draw` each
tick, then captures. This is fragile — the right settle time varies by app
(HTTP latency, SVG file size, MQTT broker distance) and there's no way for
the app to say "I'm ready."

The same problem exists for:
* **Tests** — a test harness has no way to know when to assert against the
  rendered output.
* **Plugins** — a plugin can't observe readiness or do startup work at a
  specific phase.
* **Scripts** — `on-load` fires after layout but before data sources deliver;
  there's no "data sources started" or "first values received" hook.

# Proposed events

The runtime should fire a structured set of lifecycle events. These map to
real state transitions in the runtime, not abstract concepts:

| Event | Fired after | Use cases |
|-------|-------------|----------|
| `config:load:start` | `NemoRuntime::load_config` begins | Timing, logging |
| `config:load:finish` | Config parsed, templates expanded, settings overlay applied | Validate config before layout; plugins can inspect config |
| `runtime:ready` | `NemoRuntime::initialize` finishes (scripts loaded, layout applied, data sources started) | The `on-load` replacement — app is structurally complete; scripts can hydrate state |
| `app:ready` | First render frame is drawn (`App::new` completes + first `cx.notify` lands) | Screenshot capture; test harness entry point; "the user can see something" |
| `app:unloading` | Shutdown begins (window close, `cx.quit`) | Cleanup: persist state, close connections, flush sinks |

## Why these five (and not more)

The initial list of seven concepts (application start, config loading start,
config loading finish, application ready, component render start, component
render finish, configuration unloaded) was trimmed to five by mapping each
candidate against real runtime state transitions:

* **"Application start"** merges into `config:load:start` — there's nothing
  observable between process launch and config loading; a separate event
  adds noise with no consumer.
* **"Component render start/finish"** (per-component, per-frame) — rejected.
  These fire on every `cx.notify` cycle for every component. They're not
  lifecycle events; they're render-phase hooks. The useful signal is "first
  frame drawn" (= `app:ready`), not "component X is painting." If per-component
  hooks are needed later, they belong on the component itself
  (`on_mount`/`on_unmount`), not on the application lifecycle.
* **"Configuration unloaded"** is kept but renamed to `app:unloading` — it
  fires when the runtime is tearing down (window close / `cx.quit`), which is
  when cleanup code needs to run, not after the config is already gone.

The five events map cleanly to existing code:

```
config:load:start   → runtime.rs:247  (load_config entry)
config:load:finish  → runtime.rs:291  (after config write, before initialize)
runtime:ready       → runtime.rs:440  (after initialize, before App::new)
app:ready           → app.rs:86       (after on-load, first paint committed)
app:unloading       → main.rs:329     (on_window_closed, before shutdown)
```

## What `app:ready` means precisely

`app:ready` is the event the screenshot command (and tests) wait for. It
means:

1. Config is loaded and templates are expanded.
2. Scripts are loaded.
3. Layout is applied (`LayoutManager` has the component tree).
4. Data sources are started (HTTP polling, WebSocket, MQTT — registered and
   spawning; though their first values may not have arrived yet).
5. `on-load` handler has run (if configured).
6. The first render frame has been drawn (the window has a non-empty
   `rendered_frame`).

It does NOT mean "all async data has delivered its first value." That's a
separate concern — a data source may never deliver (connection refused,
empty result). `app:ready` means "the structural app is complete and
rendered; data will flow into it." For the screenshot use case, the command
can optionally wait for a quiescence period after `app:ready` (data sources
settle, no more `data_notify` pulses for N ms) before capturing.

## Quiescence (optional, not an event)

For screenshot capture timing, `app:ready` alone may not be enough — SVG
assets load asynchronously, and data sources deliver at different times.
Rather than adding a "data:quiescent" event (which is hard to define and
racy), the screenshot command can implement quiescence detection on top of
`app:ready`:

1. Wait for `app:ready`.
2. Start a timer; reset it every time `data_notify` fires.
3. When the timer reaches N ms (default 200) with no `data_notify`, capture.

This is a policy decision in the tool, not a runtime event. The runtime's
job is to signal readiness; the tool decides when "enough" is enough.

# Design

## Event bus vs. handler dispatch

Two options for how events reach consumers:

**Option A: EventBus (existing).** The runtime already has an
`EventBus` (`runtime.event_bus`). Events are typed, pub/sub, async. Scripts
and plugins subscribe. Pros: decoupled, multiple consumers, already
infrastructure. Cons: async delivery means a consumer can't run synchronously
at the transition point.

**Option B: Rhai handler dispatch (like `on-load`).** The config declares
handler names (`<script on-ready="fn">`), and the runtime calls them
synchronously at the transition. Pros: synchronous, simple, matches the
existing `on-load`/`on-enter` pattern. Cons: one handler per event, no
plugin participation.

**Recommendation: B for script handlers, A for plugins.** Scripts get
declarative handler attributes (`on-ready`, `on-unload`) dispatched
synchronously — this is the pattern they already use. Plugins subscribe to
the `EventBus` for the same events — this is the pattern they already use
for data events. Both fire at the same transition point; the script path is
synchronous, the plugin path is async (via the existing event bus).

## Config syntax

```xml
<script
  src="handlers.rhai"
  on-load="on_load"      <!-- existing: after layout, before first paint -->
  on-ready="on_ready"    <!-- new: after first paint is drawn -->
  on-unload="on_unload"  <!-- new: before shutdown -->
/>
```

`on-load` stays as-is (it fires at `runtime:ready`, not `app:ready` — it
runs before first paint so scripts can hydrate the UI). `on-ready` is the
new "first frame drawn" hook. `on-unload` is the teardown hook.

## Plugin API

`PluginContext` gains a `subscribe_lifecycle` method:

```rust
fn subscribe_lifecycle(&mut self, event: LifecycleEvent, callback: Box<dyn Fn(&PluginContext) + Send + Sync>);
```

Where `LifecycleEvent` is an enum:

```rust
pub enum LifecycleEvent {
    ConfigLoadStart,
    ConfigLoadFinish,
    RuntimeReady,
    AppReady,
    AppUnloading,
}
```

This is additive to the existing `PluginContext` — plugins that don't
subscribe are unaffected.

## Screenshot integration

The screenshot command replaces its `--settle-ms` timing hack with:

1. Subscribe to `app:ready` (via a one-shot channel or the event bus).
2. After `app:ready`, implement quiescence detection (wait for
   `data_notify` to settle — see above).
3. Capture.

`--settle-ms` becomes a fallback/override for cases where quiescence
detection is wrong (e.g., an app with a continuously-updating data source
that never settles). Default: capture immediately after `app:ready` +
200ms quiescence window.

# Phasing

## Phase 1 — Core events + script handlers

Add the five lifecycle events to the runtime, fired at the transition points
identified above. Wire `on-ready` and `on-unload` script handler attributes
alongside the existing `on-load`. No plugin API changes yet.

* `NemoRuntime::load_config` fires `config:load:start` at entry and
  `config:load:finish` after the config write.
* `NemoRuntime::initialize` fires `runtime:ready` at the end (line 440),
  replacing the implicit "runtime init complete" log.
* `App::new` fires `app:ready` after `on-load` runs and the first frame is
  drawn (requires a one-shot defer: fire after the first `cx.notify` lands
  and the window draws — see the screenshot fix for the `Window::draw`
  pattern).
* Window close handler (`main.rs:329`) fires `app:unloading` before
  `ws.shutdown(cx)`.
* `on-ready` and `on-unload` handler attributes are read from
  `<script>` config and dispatched via `call_handler`, same as `on-load`.

**Verify:** a `.nemo` with `on-ready="fn"` fires the handler after first
paint; `nemo screenshot --wait-ready` (new flag, default on) captures after
`app:ready` instead of sleeping.

## Phase 2 — Plugin API + screenshot integration

* `PluginContext::subscribe_lifecycle` — plugins subscribe to the same
  events via the event bus.
* `nemo screenshot` uses `app:ready` + quiescence detection instead of
  `--settle-ms`. `--settle-ms` remains as an override.
* Tests can wait for `app:ready` before asserting.

**Verify:** a plugin that subscribes to `RuntimeReady` runs its callback at
the right time; `nemo screenshot` without `--settle-ms` captures a fully
rendered frame.

# Critical files

| File | Role |
|------|------|
| `crates/nemo/src/runtime.rs` | Fire `config:load:start/finish`, `runtime:ready`; add `on_ready`/`on_unload` handler read; `app:unloading` in shutdown path |
| `crates/nemo/src/app.rs` | Fire `app:ready` after first paint; read and dispatch `on-ready` handler |
| `crates/nemo/src/main.rs` | Fire `app:unloading` in `on_window_closed` before `ws.shutdown` |
| `crates/nemo/src/commands/screenshot.rs` | Replace `--settle-ms` polling with `app:ready` wait + quiescence |
| `crates/nemo-plugin-api/src/lib.rs` | `LifecycleEvent` enum + `subscribe_lifecycle` on `PluginContext` |
| `crates/nemo/src/runtime.rs` (`RuntimeContext`) | Implement `subscribe_lifecycle` — bridge event bus to plugin callbacks |

# Reuse (avoid new code)

* `EventBus` (`runtime.event_bus`) — already exists, pub/sub, typed events.
  Plugin lifecycle subscriptions use it.
* `call_handler` (`runtime.rs`) — script handler dispatch, same as
  `on-load`/`on-enter`/`on-leave`. No new dispatch path.
* `on_load_handler()` pattern (`runtime.rs:449`) — `on_ready_handler()` and
  `on_unload_handler()` follow the same shape.
* `Window::draw` + `render_to_image` (screenshot.rs fix) — the explicit draw
  pattern from the screenshot settle loop is the same mechanism `app:ready`
  uses to detect "first frame drawn."

# Verification

* **Phase 1:**
  * A `.nemo` with `<script on-ready="log_ready" />` prints a message after
    the first frame renders, before any user interaction.
  * A `.nemo` with `<script on-unload="log_unload" />` prints a message on
    window close / `Cmd-Q`.
  * `nemo screenshot --wait-ready` captures a fully rendered frame without
    `--settle-ms`; the SVG example (which needs 2–3s for asset loading) is
    captured correctly because the screenshot command waits for quiescence.
  * `config:load:start` / `config:load:finish` are observable via the event
    bus (unit test subscribes and asserts ordering).
* **Phase 2:**
  * A plugin subscribing to `RuntimeReady` runs its callback after
    `initialize()` completes, before `App::new` returns.
  * `nemo screenshot` with no `--settle-ms` captures the same frame as
    `--settle-ms 3000` did before.

# Knowledgebase updates required when implemented

* [Architecture](../concepts/architecture.md) — document the lifecycle event
  sequence and where each fires.
* [Data flow](../concepts/data-flow.md) — note `app:ready` as the point after
  which data sources are delivering.
* [Configuration](../concepts/configuration.md) — document `on-ready` /
  `on-unload` script handler attributes.
* This plan — mark phases as implemented.
* The `nemo-xml-reference` skill — add `on-ready`/`on-unload` attributes.

# Relationship to other plans

* **Enables better** [headless screenshots](headless-screenshots.md) —
  replaces `--settle-ms` timing with `app:ready` + quiescence.
* **Independent of** [control-flow directives](control-flow-directives.md) —
  lifecycle events are runtime-level; directives are template-level.
* **Independent of** [build system](build-system.md) — events fire at runtime
  regardless of whether the config was loaded from source or `dist/`.
* **Complementary to** [page router](page-router.md) — route-level
  `on-enter`/`on-leave` are per-route lifecycle; the app-level events here
  are whole-application lifecycle. They coexist without overlap.