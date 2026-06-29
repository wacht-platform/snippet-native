import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // Open filling the screen's visible area (a real desktop window), not the
    // tiny default. Still resizable down to the phone layout.
    if let screen = NSScreen.main {
      self.setFrame(screen.visibleFrame, display: true)
    }
    self.minSize = NSSize(width: 720, height: 560)
    self.title = "snippet"

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
