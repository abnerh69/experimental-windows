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

> **Postmortem del primer intento.** El watchdog original (un `Timer` externo más una bandera puesta con `addPostFrameCallback` desde el `builder`) no funcionó por dos razones que se suman: (1) `addPostFrameCallback` es global del `SchedulerBinding` — cualquier frame de *cualquier* vista, incluida la ventana principal, lo dispara — así que la bandera se marcaba como "renderizado" aunque el sheet siguiera invisible y el watchdog se autoanulaba; y (2) la sesión modal del sheet puede dejar el run loop en un modo que congela al isolate de Dart (hilo UI/plataforma fusionado en macOS), con lo que ningún rescate escrito en Dart llega siquiera a ejecutarse. Moraleja doble: las señales de "se renderizó" deben leerse desde dentro de la vista afectada, y un rescate contra bloqueos del run loop debe vivir en el lado nativo.

Rescate actual, en dos capas:

1. **Vigilante nativo (`AppDelegate.swift`)**: observa `NSWindow.willBeginSheetNotification`; a los 5 s, si el sheet sigue adjunto y está sin tamaño (frame < 4 px) o sin subvistas, hace `endSheet` + `orderOut`. Corre en AppKit, inmune al congelamiento de Dart, y registra en consola el frame y el número de subvistas del sheet (útil para el reporte upstream). Al terminar el sheet, el run loop y Dart se reanudan.
2. **Sonda en Dart (`_SondaVentanaDialogo`)**: widget que envuelve el contenido del diálogo; a los 5 s consulta `WindowScope.maybeContentSizeOf(context)` — el tamaño real de la ventana que lo aloja, no una señal global. Si es nulo o vacío, hace `pop()` de la ruta huérfana (limpiando registro y controlador vía `didPop`) y muestra un SnackBar. Si Dart estuvo congelado, esta sonda remata la limpieza en cuanto el vigilante nativo lo despierta.

Complementos:

3. **Botón `showDialog fullscreen`**: demuestra la rama con tamaño fijo, funcional hoy.
4. **Botón `showDialog clásico`**: empuja `DialogRoute` a mano con `Navigator.push`, esquivando por completo la rama de windowing de `showRawDialog`; diálogo superpuesto con barrera dentro de la misma ventana, como en stable.

## Si te quedas bloqueado sin watchdog

`kill <pid>` del proceso (el PID sale en los volcados) o detener la ejecución desde el IDE. Forzar salida (⌥⌘⎋) también funciona.

## Cierre del diálogo fullscreen: aserciones `!_debugLocked` y `defunct`

Con `fullscreenDialog: true` el diálogo-ventana **sí se muestra**, pero cada cierre produce dos aserciones de debug **no fatales** (aparecen como "Exception caught by widgets library / by gesture" y la app sigue funcionando):

1. `'!_debugLocked': is not true` en `NavigatorState.dispose`. Cadena verificada en la traza: `pop → _flushHistoryUpdates → _DialogWindowRoute.didPop → controller.destroy() → _MacOSPlatformInterface._destroyWindow → PlatformDispatcher._drawFrame` — es decir, la ruta destruye la ventana **sincrónicamente dentro del pop**, con el Navigator aún bloqueado; ese destroy bombea un frame anidado cuyo `finalizeTree` desmonta el subárbol del diálogo, incluido el navigator interno (`_NavigatorShim`) cuyo `dispose` asserta.
2. `'_lifecycleState != _ElementLifecycle.defunct'` en `setState`: al volver del pop real, el `pop` del shim continúa (`_afterNavigation → _cancelActivePointers → setState`) sobre su propio elemento, ya desmontado por el paso anterior.

Corrección que correspondería upstream: diferir el `destroy()` de `_DialogWindowRoute.didPop` (microtask o post-frame) en lugar de ejecutarlo bajo el lock del Navigator.

Mitigación en el demo: `_instalarFiltroDeAsercionesConocidas()` (activable con la constante `suprimirAsercionesConocidas` en `main.dart`) intercepta `FlutterError.onError` y reduce **solo esas dos firmas exactas** (texto + frame de pila) a una línea de log, delegando todo lo demás al manejador previo. Ponla en `false` para capturar las trazas íntegras al preparar el reporte.

## Estado upstream

Verificado en pruebas locales (jul-2026): la ruta clásica funciona; el fullscreen se muestra pero asserta al cerrar; el sized-to-content sigue produciendo el sheet fantasma. No encontramos issues con estos síntomas exactos a la fecha; ambos son candidatos a reporte en `flutter/flutter` — el del sheet fantasma citando `_DialogWindowRoute`/`sizedToContent` y el bloqueo por sesión modal, y el de las aserciones citando el `destroy()` síncrono bajo el lock del Navigator. Revisar tras cada `fvm flutter upgrade`.
