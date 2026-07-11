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
  }
}
