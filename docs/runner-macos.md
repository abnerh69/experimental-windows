# Runner de macOS y multi-view

## Síntoma

Al pulsar cualquier acción que crea una ventana (o al crearse la principal), la app aborta con:

```
*** Terminating app due to uncaught exception 'NSInternalInconsistencyException',
reason: 'Multiview can only be enabled before adding any view controllers.'
  3  FlutterMacOS  -[FlutterEngine enableMultiView]
  4  FlutterMacOS  InternalFlutter_WindowController_CreateRegularWindow
```

## Causa

La plantilla estándar de `flutter create` para macOS arranca así:

1. `MainMenu.xib` instancia una `NSWindow` de clase `MainFlutterWindow`.
2. `MainFlutterWindow.awakeFromNib` crea un `FlutterViewController()` (lo que además crea y ejecuta un engine implícito) y lo asigna como `contentViewController`.

La API de windowing, en cambio, llama internamente a `enableMultiView` la primera vez que Dart crea una ventana (`InternalFlutter_WindowController_CreateRegularWindow`). El embedder solo permite habilitar multi-view **antes** de que el engine tenga cualquier view controller registrado. Con la plantilla estándar ya existe uno (el de la ventana del xib), de ahí la excepción.

## Solución (la misma del ejemplo oficial `examples/multiple_windows`)

1. **`AppDelegate.swift`**: crear y ejecutar el engine manualmente, sin ventana ni view controller:

   ```swift
   var engine: FlutterEngine?

   override func applicationDidFinishLaunching(_ notification: Notification) {
     engine = FlutterEngine(name: "project", project: nil)
     engine?.run(withEntrypoint: nil)
   }
   ```

2. **`MainMenu.xib`**: eliminar el objeto `NSWindow` por completo (queda solo el menú y el cableado del `AppDelegate`). El xib de este repo es el del ejemplo oficial con `customModule` adaptado a `windowing_demo`.

3. **`MainFlutterWindow.swift`**: sobra. En el ejemplo oficial el archivo se eliminó del proyecto; aquí se deja como stub sin código (la entrega por zip no puede borrar archivos). Opcionalmente elimínalo desde Xcode.

Con esto, el engine arranca "headless" y `runWidget(RegularWindow(...))` en Dart crea la ventana principal; `enableMultiView` se habilita sin conflicto.

## Notas

- **Plugins**: la plantilla registraba plugins con `RegisterGeneratedPlugins(registry: flutterViewController)`. Este demo no usa plugins; si se añaden, habría que registrarlos sobre el engine en `AppDelegate` (`RegisterGeneratedPlugins(registry: engine!)`), igual que en add-to-app.
- El aviso `Failed to foreground app; open returned 1` del log es un efecto menor del lanzamiento con `--start-paused` desde el IDE, no está relacionado con el crash.
- Referencia viva: `examples/multiple_windows/macos/Runner/` en el repo de Flutter (canal main).
