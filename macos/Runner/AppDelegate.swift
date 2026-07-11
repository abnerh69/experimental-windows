import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  var engine: FlutterEngine?

  // Con la API de windowing, el engine se ejecuta sin crear ningún
  // FlutterViewController ni NSWindow: todas las ventanas (incluida la
  // principal) se crean desde Dart. Habilitar multi-view exige que no
  // exista ningún view controller previo.
  override func applicationDidFinishLaunching(_ notification: Notification) {
    engine = FlutterEngine(name: "project", project: nil)
    engine?.run(withEntrypoint: nil)
    instalarVigilanteDeSheetsFantasma()
  }

  // MARK: - Vigilante de sheets fantasma
  //
  // Bug del canal main (docs/showdialog-macos.md): showDialog crea la
  // ventana-diálogo con sizedToContent y en macOS ese sheet nunca recibe
  // tamaño ni contenido; su sesión modal bloquea la ventana principal y
  // puede congelar el run loop donde corre Dart (hilo UI/plataforma
  // fusionado), de modo que ningún rescate escrito en Dart alcanza a
  // ejecutarse. Este vigilante corre en AppKit: a los 5 s de comenzar un
  // sheet, si sigue adjunto y sin tamaño o sin contenido, lo termina y
  // devuelve el control (Dart se reanuda y la sonda del diálogo cierra la
  // ruta huérfana).
  private func instalarVigilanteDeSheetsFantasma() {
    NotificationCenter.default.addObserver(
      forName: NSWindow.willBeginSheetNotification,
      object: nil,
      queue: .main
    ) { notification in
      guard let padre = notification.object as? NSWindow else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
        guard let sheet = padre.attachedSheet else { return }
        let subvistas = sheet.contentView?.subviews.count ?? 0
        let marco = sheet.frame
        NSLog(
          "[windowing_demo] Sheet tras 5 s: frame=%@ subvistas=%d",
          NSStringFromRect(marco), subvistas)
        let sinTamano = marco.width < 4 || marco.height < 4
        let sinContenido = subvistas == 0
        if sinTamano || sinContenido {
          NSLog("[windowing_demo] Terminando sheet fantasma")
          padre.endSheet(sheet)
          sheet.orderOut(nil)
        }
      }
    }
  }
}
