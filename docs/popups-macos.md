# Popups/tooltips en macOS: anomalías y aborto del VM

## Síntomas

1. Spam en consola al haber varias ventanas:
   ```
   [ERROR:flutter/lib/ui/window/platform_configuration.cc(475)]
   Reported frame time is older than the last one; clamping. ...
   ```
2. Al mostrar/ocultar popups (sobre todo con rapidez o varios seguidos), aborto fatal del proceso:
   ```
   runtime_entry.cc: 5380: error: Callback invoked after it has been deleted.
     DLRT_GetFfiCallbackMetadata
     -[FlutterWindowOwner viewDidUpdateContents:withSize:]
     __41-[FlutterView onPresent:withBlock:delay:]_block_invoke
     ResizeSynchronizer.performCommit(forSize:afterDelay:notify:)
   ```
   Observado con Dart `3.14.0-10.0.dev` (build del 2026-07-10), macOS arm64.

## Análisis

- El punto 1 es ruido del scheduler de frames con múltiples vistas/ventanas: los timestamps de frames de distintas ventanas llegan desordenados y el engine los "clampa". Molesto, pero inocuo.
- El punto 2 es una **carrera en el embedder de windowing**: las ventanas *sized-to-content* (popups y tooltips) programan un commit de redimensionado diferido (`ResizeSynchronizer.performCommit(afterDelay:)`). Si la ventana se **destruye** con ese commit aún pendiente, el bloque nativo se ejecuta después e invoca vía FFI un callback de Dart (`viewDidUpdateContents`) que ya fue cerrado al destruir el controlador → assert del VM y SIGABRT. Alternar el popup rápido (crear → destruir en <1 s) o destruirlo dos veces lo dispara con facilidad.
- No encontramos issue upstream con esta traza (el SDK usado se publicó el día anterior); es candidato a reporte en `flutter/flutter` adjuntando el volcado completo y la versión exacta.

## Mitigación aplicada en el demo (lib/main.dart)

1. **Máquina de estados por emergente**: `cerrado → abriendo → abierto → cerrando → cerrado`. Durante `abriendo` y `cerrando` el botón se deshabilita y los clics se ignoran; solo se permite destruir en `abierto`.
2. **Periodo de asentamiento**: tras crear el popup/tooltip se espera un frame más ~250 ms (`addPostFrameCallback` + `Future.delayed`) antes de pasar a `abierto`, dando tiempo a que el commit de redimensionado inicial termine.
3. **Destroy único** (`destruirSeguro`): un `Set<BaseWindowController>` garantiza que `destroy()` se invoque a lo sumo una vez por controlador, sin importar desde dónde se cierre (botón de alternado, contenido de la ventana o lista de ventanas). El delegate limpia el set en `onWindowDestroyed`.

Con contenido estático en las emergentes (sin más commits tras el inicial), la ventana de carrera queda reducida al mínimo alcanzable desde el lado de la app. **El bug de fondo es del engine y afecta a cualquier ventana** destruida con un commit de presentación/redimensionado pendiente, no solo a las emergentes: se observó también al cerrar el diálogo fullscreen de `showDialog`, cuya ventana destruye el framework de forma síncrona en `_DialogWindowRoute.didPop` (la animación del sheet deja commits diferidos). Para ese caso, el botón "Cerrar" del diálogo del demo se habilita ~600 ms después de abrirse (`_BotonCerrarTrasAsentar`). Puede seguir reproduciéndose, por ejemplo, cerrando la ventana padre con emergentes recién creadas.

## Segundo aborto: enumeración mutada al perder el foco (diálogos/sheets)

Síntoma:
```
NSGenericException: *** Collection <__NSArrayM> was mutated while being enumerated.
  -[FlutterWindowController windowDidResignKey:]
  -[FlutterWindowOwner windowDidResignKey:]
  ...
  -[NSSheetMoveHelper openSheet]
  -[NSWindow _beginWindowBlockingModalSessionForSheet:...]
```

Repro: tener un popup o tooltip abierto y abrir un diálogo (el modal se presenta como *sheet*; también aplica a cualquier ventana nueva que tome el foco). Al dejar de ser *key window* la principal, el embedder (`FlutterWindowController.windowDidResignKey:`) recorre su lista de ventanas emergentes para cerrarlas y la **muta durante la propia enumeración** → AppKit lanza `NSGenericException` y el proceso muere. Es un bug clásico de mutación-durante-enumeración en el código nuevo de popups del embedder de macOS (`FlutterWindowController.mm`).

Mitigación en el demo: antes de crear cualquier diálogo (`DialogWindowController` o `showDialog`) **o ventana regular**, `_cerrarEmergentes()` destruye popup/tooltip, espera la confirmación de sus delegates (`Completer` por emergente, con timeout de 2 s) y deja un margen de ~80 ms para que AppKit estabilice la ventana clave. Así, cuando la principal pierde el foco, la lista de emergentes ya está vacía y no hay nada que enumerar.

Límite de la mitigación: si el usuario cambia el foco por su cuenta (clic en otra ventana o en otra app) con emergentes abiertas, el mismo código del embedder se ejecuta y puede abortar; eso no es controlable desde la app.

## Si vuelve a ocurrir

Anota la acción exacta y el intervalo (p. ej. "ocultar popup ~200 ms tras mostrarlo"), conserva el volcado y compáralo: si la traza pasa por `ResizeSynchronizer`/`viewDidUpdateContents`, es esta misma carrera. Tras un `fvm flutter upgrade` conviene reintentar: el área de windowing recibe fixes casi a diario en main.
