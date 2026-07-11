# Flutter Desktop Windowing on macOS — Field Report (main channel, July 2026)

Findings from an experimental app exercising the official windowing API (`--enable-windowing`) on macOS arm64. Environment: Flutter master, Dart `3.14.0-10.0.dev` (build 2026-07-10), engine embedder `FlutterMacOS` with Impeller (MetalSDF). Reference app: this repository (single-file demo, `lib/main.dart`), modeled on `examples/multiple_windows`.

All four issues below reproduce with the stock windowing pipeline; none are caused by app code. Each section states the symptom, the verified mechanism, our workaround, and its limits.

## 1. VM abort: FFI callback invoked after deletion when destroying a window

**Symptom.** Fatal `runtime_entry.cc: error: Callback invoked after it has been deleted` (SIGABRT). Stack: `DLRT_GetFfiCallbackMetadata` ← `-[FlutterWindowOwner viewDidUpdateContents:withSize:]` ← `-[FlutterView onPresent:withBlock:delay:]` block ← `InternalFlutterSwift.ResizeSynchronizer.performCommit(forSize:afterDelay:notify:)`.

**Mechanism (verified against engine sources).** On frame present, `FlutterSurfaceManager` schedules the commit with `delay = max((presentationTime + lastPresentationTime)/2 − now, 0)` — one to two frames. The race is about **ordering, not window age**: the close click itself repaints the window (Material ink, ~300 ms animation), enqueueing fresh commits on the platform run loop; a synchronous `controller.destroy()` executed inside the same gesture turn closes the Dart `NativeCallable` before the queued commit block fires, and the block then invokes the dead callback. Reproduces from any close affordance (toggle buttons, in-window close buttons, window list, and the framework's own synchronous destroy in `_DialogWindowRoute.didPop` for `showDialog` windows).

**Workaround.** Never destroy in the gesture turn. All destruction goes through a single helper that (a) guarantees at most one `destroy()` per controller and (b) defers it ~400 ms, yielding the run loop so in-flight commits (including the ink animation's) drain first. Traffic-light closes are routed through the same helper via `onWindowCloseRequested` delegate overrides; the `showDialog` window's close button defers its `pop` likewise. Zero aborts since.

**Limit.** Platform-initiated destroys (e.g., popups auto-dismissed when the parent resigns key) bypass app code and can still abort. Fix belongs in the embedder: cancel or guard pending commits on window teardown.

## 2. AppKit abort: collection mutated while enumerated in `windowDidResignKey:`

**Symptom.** `NSGenericException: Collection <__NSArrayM> was mutated while being enumerated`, thrown from `-[FlutterWindowController windowDidResignKey:]` when the parent window resigns key — in our repro, at the moment a sheet opens (`-[NSWindow _beginWindowBlockingModalSessionForSheet:...]`) while a popup or tooltip is open.

**Mechanism.** On key resignation the controller iterates its child/popup window list to dismiss them and mutates that same list during enumeration (`FlutterWindowController.mm`, the macOS popup implementation).

**Workaround.** Before creating anything that steals key status (dialogs — presented as sheets when parented — and regular windows), the app destroys open popups/tooltips and awaits delegate-confirmed destruction (per-window `Completer`, 2 s timeout, plus ~80 ms for AppKit to settle key ordering).

**Limit.** User-initiated focus changes (clicking another window or app) with popups open hit the same code path and cannot be intercepted from Dart.

## 3. `showDialog` (sized-to-content) creates an invisible 0×0 sheet that deadlocks the app

**Symptom.** Pressing a plain `showDialog`: nothing visible, a new `WindowRegistry` entry appears, the parent window's traffic lights disable, and `Quit` is refused (beep). Without rescue, only force-quit recovers.

**Mechanism.** `showRawDialog` builds `_DialogWindowRoute`, which uses `DialogWindowController.sizedToContent(...)` when no size is given (`packages/flutter/lib/src/widgets/dialog.dart`). On macOS that sheet never receives a size: our native probe measured `frame = {0, 0}` with 1 subview after 5 s. The window-blocking modal sheet session then disables the parent and can starve the merged UI/platform run loop, freezing Dart — which is why a Dart-only watchdog cannot self-rescue. Control experiment: `showDialog(fullscreenDialog: true)` takes the fixed-size branch and renders correctly (920×640 sheet, 2 subviews), isolating the failure to sized-to-content dialog windows. API dialogs with explicit sizes (400×260) also present fine as sheets.

**Workaround (two layers).** (a) Native watchdog in `AppDelegate`: on `NSWindow.willBeginSheetNotification`, after 5 s, ends any still-attached sheet that has no size or no subviews (`endSheet` + `orderOut`), logging frame/subview data; runs in AppKit, immune to Dart freezes. (b) A Dart probe inside the dialog content checks `WindowScope.maybeContentSizeOf(context)` after 5 s and pops the orphaned route (cleaning registry and controller via `didPop`), surfacing a SnackBar. Verified end-to-end: sheet terminated, route cleaned, registry back to zero.

## 4. Synchronous `destroy()` under the Navigator lock in `_DialogWindowRoute.didPop`

**Symptom.** Every close of a (working) fullscreen `showDialog` window raises two non-fatal debug assertions: `'!_debugLocked'` in `NavigatorState.dispose`, then `'_lifecycleState != _ElementLifecycle.defunct'` in `setState`.

**Mechanism.** `didPop` destroys the window synchronously while the outer Navigator is locked; the destroy pumps a nested `PlatformDispatcher._drawFrame`, whose `finalizeTree` unmounts the dialog's internal `_NavigatorShim` (its `NavigatorState.dispose` asserts under the lock). Returning, the shim's own `pop` continues (`_afterNavigation → _cancelActivePointers → setState`) on its now-defunct element. Suggested fix: defer the `destroy()` in `didPop` to a microtask or post-frame callback instead of running it under the lock. Note the second assertion surfaces either through the gesture arena (sync pop) or as an unhandled async exception (pop after an `await`), depending on the caller.

**Workaround.** A narrowly-scoped filter (exact message + stack-frame signatures only) reduces both assertions to one log line, installed on both channels: `FlutterError.onError` and `PlatformDispatcher.onError`. Toggleable via a single const to recover full traces for reporting.

## Where to report (supporting the Canonical-led desktop effort)

Flutter Desktop (Linux, Windows, macOS) is maintained upstream with Canonical as lead maintainer / Strategic Steward; the windowing code lives in the `flutter/flutter` monorepo, so the correct destination is the upstream tracker — there is no separate Canonical tracker for this work:

1. **File one issue per bug** at `https://github.com/flutter/flutter/issues/new?template=02_bug.yml` (the URL the assertions themselves print). Include: `flutter doctor -v`, the exact Dart/engine build (`3.14.0-10.0.dev`, 2026-07-10), the full crash dumps collected in this repo's `docs/`, and minimal repro steps (this demo qualifies; `examples/multiple_windows` is the team's own reference app).
2. **Cross-reference the umbrella issues** so the desktop/windowing team is subscribed: flutter/flutter#30701 (multi-window support) and flutter/flutter#142845 (multi-view for Windows/macOS). Mention the source files pinpointed here — `FlutterWindowController.mm`, `ResizeSynchronizer.swift`, `FlutterSurfaceManager.mm`, `packages/flutter/lib/src/widgets/dialog.dart` — it materially speeds triage.
3. For interactive discussion, the **Flutter Contributors Discord** (`#hackers-desktop`) is where the desktop embedder work, including Canonical engineers, is coordinated; linking your filed issues there is the effective way to get eyes on them.
4. After each `flutter upgrade` on main, re-run the four repros before commenting on the issues — this area receives near-daily fixes, and "still reproduces on <newer hash>" is high-value signal.
