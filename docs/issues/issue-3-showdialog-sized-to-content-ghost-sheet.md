# Draft — flutter/flutter issue (template: 02_bug.yml)

**Suggested title:** [windowing][macOS] Plain `showDialog` creates an invisible 0×0 sized-to-content sheet that blocks the parent window and prevents Quit

**Suggested labels:** `a: desktop`, `platform-macos`, `f: material design`, `framework`, `engine`

---

### Steps to reproduce

Environment: Flutter `master`, Dart `3.14.0-10.0.dev` (build 2026-07-10), macOS arm64, `flutter config --enable-windowing`, headless macOS runner (as in `examples/multiple_windows`).

1. Run the code sample.
2. Click "showDialog (plain)".
3. Observe: no dialog appears; a new entry shows up in the `WindowRegistry`; the parent window's traffic lights become disabled; app menu "Quit" is refused with a beep. Only force-quit (or stopping from the IDE) recovers.
4. Control experiment: click "showDialog (fullscreenDialog: true)" — this variant renders correctly.

### Expected results

The dialog is displayed in its own child dialog window (sheet), as documented for windowing-enabled platforms.

### Actual results

An invisible, window-modal ghost sheet blocks the parent. Instrumentation from the native side (observer on `NSWindow.willBeginSheetNotification`, measured 5 s after the sheet begins):

```
[demo] Sheet after 5 s: frame={{560, 534}, {0, 0}} subviews=1   ← plain showDialog (ghost)
[demo] Sheet after 5 s: frame={{100, 198}, {920, 640}} subviews=2 ← fullscreenDialog: true (renders)
[demo] Sheet after 5 s: frame={{360, 404}, {400, 260}} subviews=2 ← DialogWindowController(size: 400×260) (renders)
```

**Suspected mechanism.** `showRawDialog` pushes `_DialogWindowRoute`, which uses `DialogWindowController.sizedToContent(...)` when no size is given (`packages/flutter/lib/src/widgets/dialog.dart`); with `fullscreenDialog: true` it takes the fixed-size branch instead. On macOS the sized-to-content dialog window never receives a size (0×0, one subview) yet its window-blocking modal sheet session still starts, disabling the parent and refusing app termination. While that session is active, Dart-side timers do not fire (merged UI/platform thread run loop appears starved), so the app cannot rescue itself; ending the sheet from native code (`endSheet`) restores the run loop and Dart resumes. Fixed-size dialog windows (both `fullscreenDialog: true` and explicit-size `DialogWindowController`) present fine, isolating the failure to the sized-to-content dialog path.

Related: umbrella issues #30701, #142845.

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

  void _open(BuildContext context, {required bool fullscreen}) {
    showDialog<void>(
      context: context,
      fullscreenDialog: fullscreen,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Dialog'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ElevatedButton(
              onPressed: () => _open(context, fullscreen: false),
              child: const Text('showDialog (plain) — ghost sheet'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => _open(context, fullscreen: true),
              child: const Text('showDialog (fullscreenDialog: true) — works'),
            ),
          ],
        ),
      ),
    );
  }
}
```

</details>

### Screenshots or Video

<details open><summary>Screenshots / Video demonstration</summary>

[Screenshot: parent window with disabled traffic lights, no visible dialog, registry showing one dialog entry]

</details>

### Logs

<details open><summary>Logs</summary>

```console
# No crash dump — the process deadlocks instead of aborting.
# Native measurement (NSWindow.willBeginSheetNotification observer, +5 s):
2026-07-11 17:00:10.667 windowing_demo [demo] Sheet after 5 s: frame={{560, 534}, {0, 0}} subviews=1
# Quit from the app menu is refused (system beep) while the modal sheet session is active.
```

</details>

### Flutter Doctor output

<details open><summary>Doctor output</summary>

```console
[Paste the output of `flutter doctor -v` here]
```

</details>
