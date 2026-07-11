# showDialog como ventana en macOS: sheet invisible que bloquea la app

## Síntoma

Al pulsar el botón de `showDialog` de Material: no aparece ningún diálogo, pero sí una entrada nueva en la lista de "Ventanas secundarias". La ventana principal queda bloqueada: el semáforo (botón rojo de cierre) se deshabilita y `Quit windowing_demo` emite un pitido sin cerrar la app. Única salida sin mitigación: detener desde el IDE o forzar salida.

## Causa (verificada en el código de master)

Con windowing activo, `showRawDialog` (que `showDialog` invoca) empuja una `_DialogWindowRoute` que crea el controlador así (`packages/flutter/lib/src/widgets/dialog.dart`):

```dart
_controller = size != null
    ? DialogWindowController(parent: parentController, size: size, ...)
    : DialogWindowController.sizedToContent(parent: parentController, ...);
```

- Sin `fullscreenDialog`, `size` es `null` → usa **`sizedToContent`**.
- La ruta registra su `WindowEntry` en el `WindowRegistry` (por eso aparece en la lista).
- En macOS (canal main, jul-2026) la ventana-diálogo *sized-to-content* **no llega a presentarse**: se crea el *sheet* nativo, window-modal respecto a la principal, pero sin tamaño/contenido → un sheet fantasma invisible.
- Al haber una sesión modal de sheet activa (`_beginWindowBlockingModalSessionForSheet`), AppKit deshabilita los controles de la ventana padre y rechaza `Quit` (el pitido).

Pista que confirma el diagnóstico: `showDialog(..., fullscreenDialog: true)` toma la rama de **tamaño fijo** (el de la principal) y sí se muestra.

## Mitigaciones en el demo

1. **Watchdog de 6 s** en `_mostrarShowDialog`: el `builder` del diálogo marca `_dialogoMaterialRenderizado = true` en su primer frame; si a los 6 s no hubo confirmación, se hace `navigator.pop()` — eso dispara `didPop` de la ruta, que desregistra la entrada y destruye el controlador, cerrando el sheet fantasma y desbloqueando la app — y se avisa con un SnackBar. Si el bug se corrige upstream, el watchdog simplemente nunca actúa.
2. **Botón `showDialog fullscreen`**: demuestra la rama con tamaño fijo, funcional hoy.
3. **Botón `showDialog clásico`**: empuja `DialogRoute` a mano con `Navigator.push`, esquivando por completo la rama de windowing de `showRawDialog`; diálogo superpuesto con barrera dentro de la misma ventana, como en stable.

## Si te quedas bloqueado sin watchdog

`kill <pid>` del proceso (el PID sale en los volcados) o detener la ejecución desde el IDE. Forzar salida (⌥⌘⎋) también funciona.

## Estado upstream

No encontramos issue con este síntoma exacto a la fecha; candidato a reporte en `flutter/flutter` citando la ruta `_DialogWindowRoute`/`sizedToContent` y el bloqueo por sesión modal de sheet. Revisar tras cada `fvm flutter upgrade`: la rama fullscreen demuestra que el resto de la tubería ya funciona.
