// Archivo intencionalmente vacío.
//
// La plantilla de `flutter create` creaba aquí un FlutterViewController al
// arrancar (MainFlutterWindow.awakeFromNib), lo que provoca el crash
// "Multiview can only be enabled before adding any view controllers" al
// crear la primera ventana con la API de windowing.
//
// Con multiventana, el engine se arranca sin ventanas en AppDelegate.swift y
// MainMenu.xib ya no instancia ninguna NSWindow, así que esta clase dejó de
// usarse. Puede eliminarse el archivo del proyecto Xcode si se prefiere
// (clic derecho → Delete en Xcode); se conserva como stub porque la entrega
// por zip no puede borrar archivos.
