# Draft — flutter/flutter issue (template: 02_bug.yml)

**Suggested title:** [windowing][macOS] VM abort "Callback invoked after it has been deleted" when a window is destroyed while a present commit is pending

**Suggested labels:** `a: desktop`, `platform-macos`, `c: crash`, `engine`

---

### Steps to reproduce

Environment: Flutter `master`, Dart `3.14.0-10.0.dev` (build 2026-07-10), macOS arm64, `flutter config --enable-windowing`. The macOS runner is set up without view controllers (headless engine in `AppDelegate`, no `NSWindow` in the xib), matching `examples/multiple_windows`.

1. Run the code sample on macOS.
2. Click "Open window" to create a secondary `RegularWindowController` window.
3. Click the "Close (crashes)" button **inside** the secondary window, which calls `WindowScope.of(context).destroy()` synchronously in the tap handler.
4. If it does not abort on the first attempt, repeat steps 2–3 once or twice.

Also reproducible from the framework's own code path: closing a `showDialog(fullscreenDialog: true)` window (its `_DialogWindowRoute.didPop` destroys synchronously) and from rapid show/hide of `PopupWindowController` / `TooltipWindowController`.

### Expected results

The window is destroyed cleanly.

### Actual results

Fatal VM abort (SIGABRT), `Lost connection to device`:

```
runtime_entry.cc: 5380: error: Callback invoked after it has been deleted.
```

**Suspected mechanism.** On frame present, `FlutterSurfaceManager` schedules the commit via `[delegate onPresent:withBlock:delay:]` with `delay = max((presentationTime + lastPresentationTime)/2 − now, 0)` — one to two frames — which `FlutterView` forwards to `ResizeSynchronizer.performCommit(forSize:afterDelay:notify:)`. The close click itself repaints the window (Material ink), enqueueing a commit on the platform run loop; a synchronous `destroy()` executed in the same gesture turn closes the Dart `NativeCallable` before the queued block runs, and the block then invokes the dead callback through `-[FlutterWindowOwner viewDidUpdateContents:withSize:]`. It is an ordering race, not a timing one: window age does not matter.

Deferring every `destroy()` by ~400 ms in app code (yielding the run loop so pending commits drain) eliminates the abort for app-initiated closes, but platform-initiated dismissals (e.g., popups auto-closed on key-window changes) cannot be shielded from Dart. A fix likely belongs in the embedder: cancel or guard pending commit blocks on window teardown.

Related: umbrella issues #30701, #142845. Files: `engine/src/flutter/shell/platform/darwin/macos/framework/Source/{FlutterSurfaceManager.mm, FlutterView.mm, ResizeSynchronizer.swift}`, `-[FlutterWindowOwner viewDidUpdateContents:withSize:]`.

### Code sample

<details open><summary>Code sample</summary>

```dart
// Prerequisites: master channel, `flutter config --enable-windowing`, and a
// macOS runner without view controllers (as in examples/multiple_windows).
// ignore_for_file: invalid_use_of_internal_member, implementation_imports
import 'package:flutter/material.dart';
import 'package:flutter/src/widgets/_window.dart';

void main() {
  runWidget(
    RegularWindow(
      controller: RegularWindowController(
        size: const Size(600, 400),
        title: 'Main',
      ),
      child: const MaterialApp(home: _Home()),
    ),
  );
}

class _Home extends StatelessWidget {
  const _Home();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () {
            final WindowRegistry registry = WindowRegistry.of(context);
            late final WindowEntry entry;
            entry = WindowEntry(
              controller: RegularWindowController(
                size: const Size(400, 300),
                title: 'Secondary',
                delegate: _Unregister(() => registry.unregister(entry)),
              ),
              builder: (_) => const _Secondary(),
            );
            registry.register(entry);
          },
          child: const Text('Open window'),
        ),
      ),
    );
  }
}

class _Unregister with RegularWindowControllerDelegate {
  _Unregister(this.onDestroyed);
  final VoidCallback onDestroyed;

  @override
  void onWindowDestroyed() {
    onDestroyed();
    super.onWindowDestroyed();
  }
}

class _Secondary extends StatelessWidget {
  const _Secondary();

  @override
  Widget build(BuildContext context) {
    return Overlay.wrap(
      child: Scaffold(
        body: Center(
          child: ElevatedButton(
            // Synchronous destroy in the same gesture turn as the ink repaint.
            onPressed: WindowScope.of(context).destroy,
            child: const Text('Close (crashes)'),
          ),
        ),
      ),
    );
  }
}
```

</details>

### Screenshots or Video

<details open><summary>Screenshots / Video demonstration</summary>

N/A — process aborts.

</details>

### Logs

<details open><summary>Logs</summary>

```console
../../../flutter/third_party/dart/runtime/vm/runtime_entry.cc: 5380: error: Callback invoked after it has been deleted.
version=3.14.0-10.0.dev (dev) (Fri Jul 10 01:02:07 2026 -0700) on "macos_arm64"
os=macos, arch=arm64, comp=no, sim=no
  pc ... dart::Profiler::DumpStackTrace(bool)
  pc ... dart::Assert::Fail(char const*, ...)
  pc ... DLRT_GetFfiCallbackMetadata
  pc ... -[FlutterWindowOwner viewDidUpdateContents:withSize:]
  pc ... __41-[FlutterView onPresent:withBlock:delay:]_block_invoke
  pc ... InternalFlutterSwift.ResizeSynchronizer.performCommit(forSize:afterDelay:notify:) closure
  pc ... InternalFlutterSwift.RunLoop.performExpiredTasks
  pc ... __CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE0_PERFORM_FUNCTION__
  ...
  pc ... NSApplicationMain
-- End of DumpStackTrace
Lost connection to device.
```

(Full dumps from three independent sessions available on request.)

</details>

### Flutter Doctor output

<details open><summary>Doctor output</summary>

```console
[Paste the output of `flutter doctor -v` here]
```

</details>
