# Windowing en Flutter macOS sin morir en el intento

Guía de supervivencia destilada de este proyecto (canal main, julio 2026). Complementa al README (preparación con fvm) y a los análisis de `docs/`. La API es `@internal`: todo lo dicho aquí caduca con cada `flutter upgrade`; la referencia viva es `examples/multiple_windows` en el repo de Flutter.

## Modelo mental en cinco líneas

Un solo engine y un solo isolate renderizan todas las ventanas (multi-view): el estado en Dart se comparte sin canales ni IPC. La ventana principal nace en `main()` con `runWidget(RegularWindow(...))`. `MaterialApp` inserta un `WindowManager` que provee el `WindowRegistry`; toda ventana adicional es un `WindowEntry` (controlador + builder) que registras y — obligatorio — desregistras cuando su delegate avisa `onWindowDestroyed`. Dentro de cualquier ventana, `WindowScope.of(context)` te da su controlador.

## Las reglas que evitan los abortos

1. **El runner de macOS no debe crear view controllers.** La plantilla de `flutter create` crashea con "Multiview can only be enabled before adding any view controllers": engine *headless* en `AppDelegate`, xib sin `NSWindow`, `MainFlutterWindow` fuera. Detalle en `runner-macos.md`.
2. **Nunca destruyas una ventana en el mismo turno del gesto.** El clic de cierre repinta la ventana (ink) y encola commits de presentación; un `destroy()` síncrono les gana y el VM aborta (`Callback invoked after it has been deleted`). Centraliza la destrucción: un solo punto que garantice **un** `destroy()` por controlador y lo **difiera ~400 ms** (patrón `destruirSeguro` + `_demoraDestruccion` en `lib/main.dart`). Intercepta también el semáforo con `onWindowCloseRequested` en tus delegates para rutearlo por el mismo camino.
3. **Cierra popups y tooltips antes de crear cualquier ventana que robe el foco** (diálogos — que en macOS son sheets — y regulares). Si la principal pierde la condición de key window con emergentes abiertas, el embedder aborta ("Collection was mutated while being enumerated"). Espera la confirmación de destrucción del delegate (Completer) antes de continuar; evita además cambiar de app con emergentes abiertas.
4. **No uses `showDialog` a secas todavía.** Sin `fullscreenDialog: true` crea la ventana con `sizedToContent` y en macOS nace un sheet invisible de 0×0 que bloquea la app entera. Alternativas que sí funcionan: `showDialog(fullscreenDialog: true)`, `DialogWindowController` con `size` explícito, o la ruta clásica empujando `DialogRoute` a mano. Si necesitas exponer el botón roto (como este demo), monta el rescate de dos capas: vigilante nativo de sheets fantasma en el `AppDelegate` + sonda de `WindowScope.maybeContentSizeOf` dentro del contenido.
5. **Da tiempo de asentamiento a las emergentes.** Popups y tooltips se redimensionan a su contenido justo tras crearse; una máquina de estados (`cerrado → abriendo → abierto → cerrando`) que deshabilite el botón durante las transiciones elimina los cierres prematuros y el doble-clic nervioso.

## Recetas por tipo de ventana

- **Regular secundaria**: `RegularWindowController(size:, title:, delegate:)` + `WindowEntry` + `registry.register`. Contenido envuelto en `Overlay.wrap(child: Scaffold(...))`; Theme y MediaQuery se heredan solos.
- **Popup / tooltip**: `PopupWindowController` / `TooltipWindowController` con `parent: WindowScope.of(context)`, `anchorRect` calculado del `RenderBox` del ancla (`localToGlobal & size`) y un `WindowPositioner` (anclas padre/hijo + offset). Contenido: `Overlay.wrap(alwaysSizeToContent: true, child: IntrinsicWidth(child: Material(...)))` con columnas `MainAxisSize.min`. No siguen al ancla si mueves la ventana: para eso hay que llamar `updatePosition` (ver el tracker del ejemplo oficial).
- **Diálogo de API**: `DialogWindowController(size:, parent: …)` → modal (sheet) de su padre; sin `parent` → modeless independiente. Ambos estables hoy.
- **showDialog de Material**: ver regla 4. Bonus: al cerrar el fullscreen, el framework destruye la ventana bajo el lock del Navigator y suelta dos aserciones de debug no fatales; el filtro acotado de `main.dart` (`suprimirAsercionesConocidas`, canales `FlutterError.onError` + `PlatformDispatcher.onError`) las reduce a una línea.

## Estado verificado (11-jul-2026, Dart 3.14.0-10.0.dev)

| Característica | Estado | Nota |
|---|---|---|
| Ventana regular (crear/cerrar/lista) | ✅ | con destrucción diferida |
| Popup anclado | ✅ | asentamiento + cierre coordinado |
| Tooltip anclado | ✅ | alternado por clic (sin hover) |
| Diálogo modal API (`parent`) | ✅ | se presenta como sheet |
| Diálogo modeless API | ✅ | — |
| `showDialog` clásico (`DialogRoute`) | ✅ | misma ventana, con barrera |
| `showDialog` fullscreen | ⚠️ | abre bien; aserciones filtradas al cerrar |
| `showDialog` sized-to-content | ❌ | sheet fantasma 0×0; rescate automático |

## Higiene de sesión

El spam `Reported frame time is older... clamping` es ruido inocuo del scheduler multi-vista. Cierra las ventanas secundarias antes de un hot restart. Tras cada `fvm flutter upgrade`: `fvm flutter doctor` primero, reintenta los casos ❌/⚠️ (los fixes llegan casi a diario) y, si algo deja de compilar, compara contra `examples/multiple_windows`. Para reportar hallazgos upstream, usa el informe en inglés de `field-report-windowing-macos.md`, que incluye los canales correctos.
