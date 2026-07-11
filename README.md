# windowing_demo

Proyecto **experimental** que demuestra la API oficial de windowing de Flutter (multiventana) en macOS: ventanas regulares, popups, tooltips y diálogos, usando el canal `main`/`master`.

> **Advertencia.** La API vive en `package:flutter/src/widgets/_window.dart`, está marcada `@internal` y Flutter hará cambios rompientes incluso entre parches. No usar en producción ni en paquetes publicados en pub.dev. Referencia: issue [flutter#30701](https://github.com/flutter/flutter/issues/30701).

## Requisitos

- macOS con Xcode instalado (`flutter doctor` en verde para el target macOS).
- `fvm` instalado.
- IntelliJ IDEA con los plugins de Flutter y Dart.

## Preparación con fvm

```bash
# 1. Instalar el canal main (fvm lo llama "master")
fvm install master

# 2. Crear la carpeta del proyecto y fijar la versión
mkdir windowing_demo && cd windowing_demo
fvm use master --force        # --force porque aún no existe pubspec

# 3. Generar el esqueleto del proyecto solo para macOS
fvm flutter create . --platforms=macos --project-name windowing_demo

# 4. Activar la bandera experimental de windowing (global para este SDK)
fvm flutter config --enable-windowing

# 5. Sobrescribir con los archivos de este repo:
#    pubspec.yaml, lib/main.dart y — imprescindible — macos/Runner/
#    (AppDelegate.swift, MainFlutterWindow.swift y Base.lproj/MainMenu.xib)

# 6. Ejecutar
fvm flutter pub get
fvm flutter run -d macos
```

> **Importante.** Sin el paso 5 sobre `macos/Runner/`, la app aborta al crear la primera ventana con `NSInternalInconsistencyException: Multiview can only be enabled before adding any view controllers`. La plantilla estándar de `flutter create` crea un `FlutterViewController` al arrancar, incompatible con la API de windowing. Diagnóstico y detalle del cambio en [`docs/runner-macos.md`](docs/runner-macos.md).

Verificación: `fvm flutter doctor -v` debe listar `enable-windowing` entre los *Feature flags*. Para desactivarla luego: `fvm flutter config --no-enable-windowing`.

Para actualizar el canal más adelante ejecuta `fvm flutter upgrade` (el canal main cambia a diario; cualquier actualización puede romper este código, ver más abajo).

## Configuración en IntelliJ IDEA

1. `Settings → Languages & Frameworks → Flutter → Flutter SDK path` y apuntar al SDK de fvm. Lo más cómodo es usar el enlace simbólico que fvm crea dentro del proyecto: `<proyecto>/.fvm/flutter_sdk` (alternativa: `~/fvm/versions/master`).
2. Crear una Run Configuration de tipo Flutter con `lib/main.dart` como entry point y `macOS (desktop)` como dispositivo.
3. La bandera `enable-windowing` ya quedó activada a nivel de SDK en el paso 4, así que no hace falta pasar argumentos extra al ejecutar desde el IDE.
4. El analizador no marcará los miembros `@internal` porque cada archivo lleva `// ignore_for_file: invalid_use_of_internal_member` e `implementation_imports`, igual que el ejemplo oficial `examples/multiple_windows` del repo de Flutter.

## Qué demuestra

Todo cuelga de un único engine y un único isolate (arquitectura *multi-view*), a diferencia de plugins comunitarios como `desktop_multi_window` que levantan un engine por ventana.

- **Ventana regular**: `RegularWindowController` + widget `RegularWindow`. La principal se crea en `main()` con `runWidget`; las secundarias se registran como `WindowEntry` en el `WindowRegistry` que `MaterialApp` provee automáticamente (vía el widget interno `WindowManager`).
- **Popup**: `PopupWindowController` anclado al rectángulo de un botón (`anchorRect`) y posicionado con `WindowPositioner` (anclas padre/hijo + offset). Es una ventana nativa: puede sobresalir de la ventana padre.
- **Tooltip**: `TooltipWindowController`, misma mecánica de anclaje. En este demo se alterna con clic (no hay hover automático).
- **Diálogos**, en tres sabores:
  - `DialogWindowController` con `parent` → modal respecto a su ventana padre.
  - `DialogWindowController` sin `parent` → modeless, flota independiente.
  - `showDialog` de Material sin cambios: con la bandera activa, Flutter lo renderiza como ventana nativa hija en lugar de una ruta superpuesta.
- **Estado compartido**: un `ValueNotifier<int>` global se muestra e incrementa desde cualquier ventana en tiempo real, sin canales ni IPC.
- **Ciclo de vida**: cada controlador recibe un *delegate*; `onWindowDestroyed` desregistra la entrada del `WindowRegistry` (obligatorio antes de que la ventana muera). Cerrar la ventana principal termina la app (`exit(0)`).

Detalle de implementación: el contenido de ventanas secundarias se envuelve en `Overlay.wrap` (con `alwaysSizeToContent: true` en popups/tooltips, que no reciben tamaño y se ajustan a su contenido), siguiendo el patrón del ejemplo oficial.

## Bugs y limitaciones conocidos (macOS, canal main, mediados de 2026)

- **`showDialog` como ventana crea un sheet invisible que bloquea la app** (sin botón rojo, `Quit` pita): la variante *sized-to-content* del diálogo no se presenta en macOS. El demo lo rescata en dos capas — vigilante nativo en el AppDelegate que termina el sheet (inmune al congelamiento de Dart) y sonda en Dart que cierra la ruta huérfana — más las variantes `fullscreen` (tamaño fijo: se muestra, con dos aserciones de debug no fatales al cerrar que el demo filtra) y clásica (`DialogRoute` manual, sin problemas); análisis en [`docs/showdialog-macos.md`](docs/showdialog-macos.md).
- **Aborto del VM al destruir ventanas con commits pendientes** (`Callback invoked after it has been deleted`): carrera del engine entre `destroy()` y commits diferidos de presentación/redimensionado; afecta a popups/tooltips y también al cierre del diálogo fullscreen. El demo lo mitiga con una máquina de estados, periodo de asentamiento y destroy único; análisis completo en [`docs/popups-macos.md`](docs/popups-macos.md).
- **Aborto de AppKit al abrir diálogos con emergentes abiertas** (`Collection was mutated while being enumerated` en `windowDidResignKey:`): al perder el foco la principal, el embedder cierra sus emergentes mutando la lista que enumera. El demo cierra popup/tooltip y espera su destrucción confirmada antes de crear diálogos o ventanas; mismo documento. Cambiar el foco manualmente (otra ventana u otra app) con emergentes abiertas puede seguir abortando: es del engine.

- **Flash al crear ventanas regulares**: la ventana nativa aparece antes de que el contenido Flutter esté listo (fotogramas en negro, posición inicial incorrecta, reaparición). Issue [#184701](https://github.com/flutter/flutter/issues/184701).
- **Hot reload / hot restart con varias ventanas**: históricamente dejaba ventanas sin respuesta en macOS (mitigado en gran parte por el fix de [#180287](https://github.com/flutter/flutter/pull/180287), incluido en 3.44). Si algo queda raro tras un restart, cierra las secundarias y vuelve a crearlas.
- **API inestable por diseño**: nombres, firmas y comportamiento cambian entre commits del canal main. Si tras `fvm flutter upgrade` el proyecto no compila, compara contra `examples/multiple_windows` del repo de Flutter, que es la referencia viva de la API.
- **`--enable-windowing` altera comportamiento existente**: por ejemplo, `showDialog` deja de usar `barrierColor` (no hay barrera; el diálogo es una ventana). Algunos tests de widgets pueden fallar con la bandera activa.
- Los popups/tooltips de este demo no siguen al botón si mueves o redimensionas la ventana mientras están abiertos (el ejemplo oficial lo resuelve con un *tracker* que llama a `controller.updatePosition`; aquí se omitió por simplicidad).

## Estructura

```
windowing_demo/
├── README.md
├── pubspec.yaml
├── analysis_options.yaml
├── docs/
│   └── runner-macos.md            # por qué y cómo se modifica el runner
├── lib/
│   └── main.dart                  # todo el demo en un solo archivo
└── macos/Runner/
    ├── AppDelegate.swift          # engine headless (sin view controllers)
    ├── MainFlutterWindow.swift    # stub vacío (la plantilla original crashea)
    └── Base.lproj/MainMenu.xib    # sin NSWindow; solo menú
```

El resto de `macos/` y demás plataformas lo genera `flutter create` en el paso 3; estos tres archivos del runner **sobrescriben** a los generados.
