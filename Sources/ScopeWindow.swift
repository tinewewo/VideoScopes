import Cocoa

// One floating window per scope. Move = native title-bar drag, resize = native
// window edges, full-screen = green button or the View menu item. Toggling is
// show / hide driven by the controller panel.
final class ScopeWindowController: NSObject, NSWindowDelegate {
    let kind: ScopeKind
    let window: NSWindow
    let container: ScopeContainerView
    var onVisibilityChanged: (() -> Void)?
    private(set) var pinned = false

    init(kind: ScopeKind, origin: CGPoint) {
        self.kind = kind
        self.container = ScopeContainerView(kind: kind)
        let size = kind.defaultWindowSize
        window = NSWindow(
            contentRect: NSRect(x: origin.x, y: origin.y, width: size.w, height: size.h),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = kind.title
        window.contentView = container
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.backgroundColor = NSColor(white: 0.04, alpha: 1)
        if kind == .vectorscope {
            // square content, proportional resize only
            window.contentAspectRatio = NSSize(width: 1, height: 1)
            window.minSize = NSSize(width: 220, height: 240)
        } else {
            window.minSize = NSSize(width: 240, height: 180)
        }
        super.init()
        window.delegate = self
    }

    var isVisible: Bool { window.isVisible }

    func show() { window.makeKeyAndOrderFront(nil) }
    func hide() { window.orderOut(nil) }
    func toggleFullScreen() { window.toggleFullScreen(nil) }

    func setPinned(_ on: Bool) {
        pinned = on
        window.level = on ? .floating : .normal
    }

    func windowWillClose(_ notification: Notification) {
        // red button hides instead of destroying; refresh the controller toggles
        DispatchQueue.main.async { [weak self] in self?.onVisibilityChanged?() }
    }
}
