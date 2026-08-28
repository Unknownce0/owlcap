import AppKit
import QuartzCore

// MARK: - Borderless overlay window

final class OverlayWindow: NSWindow {
    init(frame: NSRect, interactive: Bool) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = !interactive
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { true }
}

// MARK: - Click highlighting

/// A transparent, click-through window that paints a ring wherever the user clicks.
/// Because it sits on screen it gets picked up by the capture itself — the same trick
/// QuickTime's "show mouse clicks in recording" uses.
final class ClickOverlay {
    private var window: OverlayWindow?
    private var monitor: Any?
    private var localMonitor: Any?

    var windowID: CGWindowID? {
        guard let window else { return nil }
        return CGWindowID(window.windowNumber)
    }

    func start() {
        let frame = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        let window = OverlayWindow(frame: frame, interactive: false)
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        window.contentView = view
        window.orderFrontRegardless()
        self.window = window

        let handler: (NSEvent) -> Void = { [weak self] event in
            self?.ping(at: NSEvent.mouseLocation)
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            handler(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            handler(event)
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        monitor = nil
        localMonitor = nil
        window?.orderOut(nil)
        window = nil
    }

    private func ping(at screenPoint: NSPoint) {
        guard let window, let host = window.contentView?.layer else { return }
        let origin = window.frame.origin
        let point = CGPoint(x: screenPoint.x - origin.x, y: screenPoint.y - origin.y)

        let radius: CGFloat = 26
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        ring.position = point
        ring.fillColor = NSColor.systemYellow.withAlphaComponent(0.28).cgColor
        ring.strokeColor = NSColor.systemYellow.withAlphaComponent(0.95).cgColor
        ring.lineWidth = 3
        host.addSublayer(ring)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.35
        grow.toValue = 1.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        ring.add(group, forKey: "click")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ring.removeFromSuperlayer() }
    }
}

// MARK: - Countdown

final class CountdownOverlay {
    private var window: OverlayWindow?
    private let label = NSTextField(labelWithString: "")

    func show(number: Int) {
        if window == nil {
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let size = NSSize(width: 220, height: 220)
            let frame = NSRect(x: screen.frame.midX - size.width / 2,
                               y: screen.frame.midY - size.height / 2,
                               width: size.width, height: size.height)
            let window = OverlayWindow(frame: frame, interactive: false)
            let view = NSView(frame: NSRect(origin: .zero, size: size))
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
            view.layer?.cornerRadius = 36
            label.frame = NSRect(x: 0, y: 40, width: size.width, height: 140)
            label.alignment = .center
            label.font = .systemFont(ofSize: 116, weight: .semibold)
            label.textColor = .white
            view.addSubview(label)
            window.contentView = view
            window.orderFrontRegardless()
            self.window = window
        }
        label.stringValue = "\(number)"
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}
