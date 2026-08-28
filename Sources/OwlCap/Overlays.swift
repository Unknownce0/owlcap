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

// MARK: - Region selection

/// Drag-to-select overlay. Returns the chosen rect in the display's own point
/// coordinates (top-left origin), which is what SCStreamConfiguration.sourceRect wants.
final class RegionSelector {
    private var windows: [OverlayWindow] = []
    private var continuation: CheckedContinuation<(CGDirectDisplayID, CGRect)?, Never>?

    func select() async -> (CGDirectDisplayID, CGRect)? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            for screen in NSScreen.screens {
                let window = OverlayWindow(frame: screen.frame, interactive: true)
                let view = RegionView(frame: NSRect(origin: .zero, size: screen.frame.size))
                view.screen = screen
                view.onFinish = { [weak self] result in self?.finish(result) }
                window.contentView = view
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                windows.append(window)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func finish(_ result: (CGDirectDisplayID, CGRect)?) {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private final class RegionView: NSView {
    weak var screen: NSScreen?
    var onFinish: (((CGDirectDisplayID, CGRect)?) -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.32).setFill()
        bounds.fill()
        guard let rect = selectionRect() else {
            drawHint()
            return
        }
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()

        let text = "\(Int(rect.width)) × \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        let badge = NSRect(x: rect.midX - size.width / 2 - 8,
                           y: max(4, rect.minY - size.height - 12),
                           width: size.width + 16, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()
        text.draw(at: NSPoint(x: badge.minX + 8, y: badge.minY + 4), withAttributes: attrs)
    }

    private func drawHint() {
        let text = "Drag to choose an area   •   Esc to cancel"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let size = text.size(withAttributes: attrs)
        let box = NSRect(x: bounds.midX - size.width / 2 - 14,
                         y: bounds.midY - size.height / 2 - 8,
                         width: size.width + 28, height: size.height + 16)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        text.draw(at: NSPoint(x: box.minX + 14, y: box.minY + 8), withAttributes: attrs)
    }

    private func selectionRect() -> NSRect? {
        guard let start, let current else { return nil }
        let rect = NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                          width: abs(start.x - current.x), height: abs(start.y - current.y))
        return rect.width >= 4 && rect.height >= 4 ? rect : nil
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { start = nil; current = nil }
        guard let rect = selectionRect(), let screen, let displayID = screen.displayID else {
            onFinish?(nil)
            return
        }
        // View coords are bottom-left; sourceRect wants top-left within the display.
        let flipped = CGRect(x: rect.minX,
                             y: screen.frame.height - rect.maxY,
                             width: rect.width, height: rect.height)
        onFinish?((displayID, flipped.integral))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onFinish?(nil) }
}
