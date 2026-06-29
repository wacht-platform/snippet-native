import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // The desktop two-pane layout wants room; still allow shrinking to the
    // phone layout below the breakpoint.
    self.minSize = NSSize(width: 720, height: 560)
    self.title = "snippet"

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
