import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var fileDropChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    fileDropChannel = FlutterMethodChannel(
      name: "dev.relay.app/file_drop",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    registerForDraggedTypes([.fileURL])

    super.awakeFromNib()
  }

  private func extractDraggedFilePaths(_ sender: NSDraggingInfo) -> [String] {
    guard
      let urls = sender.draggingPasteboard.readObjects(
        forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]
      ) as? [URL]
    else {
      return []
    }
    return urls.map { $0.path }.filter { !$0.isEmpty }
  }

  @objc func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard !extractDraggedFilePaths(sender).isEmpty else {
      return []
    }
    fileDropChannel?.invokeMethod("dragEnter", arguments: nil)
    return .copy
  }

  @objc func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    return extractDraggedFilePaths(sender).isEmpty ? [] : .copy
  }

  @objc func draggingExited(_ sender: NSDraggingInfo?) {
    fileDropChannel?.invokeMethod("dragLeave", arguments: nil)
  }

  @objc func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    fileDropChannel?.invokeMethod("dragLeave", arguments: nil)
    let paths = extractDraggedFilePaths(sender)
    guard !paths.isEmpty else {
      return false
    }
    fileDropChannel?.invokeMethod("drop", arguments: paths)
    return true
  }
}
