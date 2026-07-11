# Draft — flutter/flutter issue (template: 02_bug.yml)

**Suggested title:** [windowing] `_DialogWindowRoute.didPop` destroys the dialog window synchronously under the Navigator lock — `'!_debugLocked'` and defunct-`setState` assertions on every close

**Suggested labels:** `a: desktop`, `platform-macos`, `f: routes`, `framework`

---

### Steps to reproduce

Environment: Flutter `master`, Dart `3.14.0-10.0.dev` (build 2026-07-10), macOS arm64, `flutter config --enable-windowing`, headless macOS runner (as in `examples/multiple_windows`).

1. Run the code sample.
2. Click "showDialog (fullscreenDialog: true)" — the dialog window (sheet) renders correctly.
3. Click its "Close" button (`Navigator.of(context).pop()`).
4. Two debug assertions are thrown on every close. The app keeps running (non-fatal), but the pair fires reliably each time.

### Expected results

The dialog window closes without framework assertions.

### Actual results

Two assertions per close:

1. `'!_debugLocked': is not true` in `NavigatorState.dispose`, thrown "while finalizing the widget tree".
2. `'_lifecycleState != _ElementLifecycle.defunct': is not true` in `Element.markNeedsBuild` via `State.setState`.

**Verified chain (from the stacks).** `NavigatorState.pop → _flushHistoryUpdates → _DialogWindowRoute.didPop → _controller.destroy() → _MacOSPlatformInterface._destroyWindow → PlatformDispatcher._drawFrame`: the route destroys the window **synchronously while the outer Navigator is locked**; the destroy pumps a nested frame whose `finalizeTree` unmounts the dialog's subtree — including its internal `_NavigatorShim` navigator, whose `dispose` asserts under the lock (assertion 1). Control then returns to the shim's own `pop`, which continues with `_afterNavigation → _cancelActivePointers → setState` on its now-defunct element (assertion 2).

Note: assertion 2 surfaces through the gesture arena (and thus `FlutterError.onError`) when the pop is called synchronously from the tap handler, but arrives as an **unhandled asynchronous exception** (`PlatformDispatcher.onError` channel) when the pop happens after an `await` — same signature either way.

**Suggested fix.** Defer the `destroy()` in `_DialogWindowRoute.didPop` (microtask or post-frame callback) instead of executing it under the Navigator lock. The synchronous destroy is also implicated in a separate VM abort when present commits are pending (filed separately).

Related: umbrella issues #30701, #142845. Files: `packages/flutter/lib/src/widgets/dialog.dart` (`_DialogWindowRoute.didPop`), `packages/flutter/lib/src/material/dialog.dart` (`_NavigatorShim`), `packages/flutter/lib/src/widgets/_window_macos.dart`.

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
          onPressed: () => showDialog<void>(
            context: context,
            fullscreenDialog: true,
            builder: (BuildContext context) => AlertDialog(
              title: const Text('Dialog window'),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(), // asserts
                  child: const Text('Close'),
                ),
              ],
            ),
          ),
          child: const Text('showDialog (fullscreenDialog: true)'),
        ),
      ),
    );
  }
}
```

</details>

### Screenshots or Video

<details open><summary>Screenshots / Video demonstration</summary>

N/A — console assertions.

</details>

### Logs

<details open><summary>Logs</summary>

```console
======== Exception caught by widgets library =======================================================
The following assertion was thrown while finalizing the widget tree:
'package:flutter/src/widgets/navigator.dart': Failed assertion: line 4128 pos 12: '!_debugLocked': is not true.
#2   NavigatorState.dispose (navigator.dart:4128)
#3   StatefulElement.unmount
...  (_InactiveElements._unmount cascade)
#101 BuildOwner.finalizeTree
#102 WidgetsBinding.drawFrame
#108 PlatformDispatcher._drawFrame
#110 _MacOSPlatformInterface._destroyWindow (_window_macos.dart)
#112 _WindowControllerMixin.destroy (_window_macos.dart:273)
#113 _DialogWindowRoute.didPop (widgets/dialog.dart:189)
#115 NavigatorState._flushHistoryUpdates
#116 NavigatorState.pop
#117 _NavigatorShim.build.<closure> (material/dialog.dart:1481)
#118 NavigatorState.pop
====================================================================================================

[ERROR:flutter/runtime/dart_vm_initializer.cc(40)] Unhandled Exception:
'package:flutter/src/widgets/framework.dart': Failed assertion: line 5353 pos 12: '_lifecycleState != _ElementLifecycle.defunct': is not true.
#2   Element.markNeedsBuild
#3   State.setState
#4   NavigatorState._cancelActivePointers (navigator.dart:5916)
#5   NavigatorState._afterNavigation
#6   NavigatorState.pop
<asynchronous suspension>
```

</details>

### Flutter Doctor output

<details open><summary>Doctor output</summary>

```console
[Paste the output of `flutter doctor -v` here]
```

</details>
