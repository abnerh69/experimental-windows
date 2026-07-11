# Draft — flutter/flutter issue (template: 02_bug.yml)

**Suggested title:** [windowing][macOS] NSGenericException "Collection was mutated while being enumerated" in `-[FlutterWindowController windowDidResignKey:]` when a sheet opens while a popup is open

**Suggested labels:** `a: desktop`, `platform-macos`, `c: crash`, `engine`

---

### Steps to reproduce

Environment: Flutter `master`, Dart `3.14.0-10.0.dev` (build 2026-07-10), macOS arm64, `flutter config --enable-windowing`, headless macOS runner (as in `examples/multiple_windows`).

1. Run the code sample.
2. Click "Show popup" — a `PopupWindowController` window opens anchored to the button.
3. With the popup still open, click "Open modal dialog" — a `DialogWindowController` with `parent` set, which macOS presents as a sheet.
4. The app aborts the moment the sheet begins (parent window resigns key).

Any key-window change with a popup/tooltip open appears to hit the same path (e.g., clicking another window), a sheet just makes it deterministic.

### Expected results

The popup is dismissed and the modal dialog sheet opens.

### Actual results

Uncaught `NSGenericException`, process terminates:

```
*** Collection <__NSArrayM: 0x...> was mutated while being enumerated.
```

**Suspected mechanism.** When the parent resigns key, `-[FlutterWindowController windowDidResignKey:]` iterates its list of child/popup windows to dismiss them and mutates that same array during enumeration (classic fast-enumeration violation). The popup implementation for macOS landed in #182371 (`FlutterWindowController.mm`).

App-side workaround in use: destroy open popups/tooltips and await their delegate-confirmed destruction before creating anything that takes key status. This cannot cover user-initiated focus changes.

Related: umbrella issues #30701, #142845; PR #182371.

### Code sample

<details open><summary>Code sample</summary>

```dart
// Prerequisites: master channel, `flutter config --enable-windowing`, and a
// macOS runner without view controllers (as in examples/multiple_windows).
// ignore_for_file: invalid_use_of_internal_member, implementation_imports
import 'package:flutter/material.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_positioner.dart';

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

  static final GlobalKey _anchor = GlobalKey();

  Rect _anchorRect() {
    final RenderBox box =
        _anchor.currentContext!.findRenderObject()! as RenderBox;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    final WindowRegistry registry = WindowRegistry.of(context);
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ElevatedButton(
              key: _anchor,
              onPressed: () {
                late final WindowEntry entry;
                entry = WindowEntry(
                  controller: PopupWindowController(
                    parent: WindowScope.of(context),
                    anchorRect: _anchorRect(),
                    positioner: const WindowPositioner(
                      parentAnchor: WindowPositionerAnchor.bottomLeft,
                      childAnchor: WindowPositionerAnchor.topLeft,
                    ),
                    delegate: _UnregisterPopup(
                        () => registry.unregister(entry)),
                  ),
                  builder: (_) => Overlay.wrap(
                    alwaysSizeToContent: true,
                    child: const Material(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('Popup'),
                      ),
                    ),
                  ),
                );
                registry.register(entry);
              },
              child: const Text('Show popup'),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
                late final WindowEntry entry;
                entry = WindowEntry(
                  controller: DialogWindowController(
                    size: const Size(400, 260),
                    title: 'Modal',
                    parent: WindowScope.of(context), // presented as a sheet
                    delegate: _UnregisterDialog(
                        () => registry.unregister(entry)),
                  ),
                  builder: (_) => Overlay.wrap(
                    child: const Material(child: Center(child: Text('Dialog'))),
                  ),
                );
                registry.register(entry); // aborts here with popup open
              },
              child: const Text('Open modal dialog (crashes)'),
            ),
          ],
        ),
      ),
    );
  }
}

class _UnregisterPopup with PopupWindowControllerDelegate {
  _UnregisterPopup(this.onDestroyed);
  final VoidCallback onDestroyed;
  @override
  void onWindowDestroyed() {
    onDestroyed();
    super.onWindowDestroyed();
  }
}

class _UnregisterDialog with DialogWindowControllerDelegate {
  _UnregisterDialog(this.onDestroyed);
  final VoidCallback onDestroyed;
  @override
  void onWindowDestroyed() {
    onDestroyed();
    super.onWindowDestroyed();
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
*** Terminating app due to uncaught exception 'NSGenericException', reason: '*** Collection <__NSArrayM: 0xad3023ab0> was mutated while being enumerated.'
*** First throw call stack:
(
  3   FlutterMacOS  -[FlutterWindowController windowDidResignKey:] + 220
  4   FlutterMacOS  -[FlutterWindowOwner windowDidResignKey:] + 180
  5   CoreFoundation  __CFNOTIFICATIONCENTER_IS_CALLING_OUT_TO_AN_OBSERVER__
  10  AppKit  -[NSWindow resignKeyWindow]
  13  AppKit  -[NSWindow makeKeyWindow]
  15  AppKit  -[NSSheetMoveHelper openSheet]
  21  AppKit  -[NSWindow _beginWindowBlockingModalSessionForSheet:service:completionHandler:isCritical:]
  ...
)
libc++abi: terminating due to uncaught exception of type NSException
Lost connection to device.
```

</details>

### Flutter Doctor output

<details open><summary>Doctor output</summary>

```console
[Paste the output of `flutter doctor -v` here]
```

</details>
