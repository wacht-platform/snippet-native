import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // Open filling the screen's visible area (a real desktop window), not the
    // tiny default. Resizable down to a narrow window where the shell collapses
    // its sidebar into a drawer (still the native desktop UI, never the phone UI).
    if let screen = NSScreen.main {
      self.setFrame(screen.visibleFrame, display: true)
    }
    self.minSize = NSSize(width: 480, height: 520)
    self.title = "snippet"

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
