import AppKit
import ScreenCaptureKit

/// Shared geometry helpers. ScreenCaptureKit speaks CoreGraphics coordinates (top-left
/// origin, y downwards); AppKit speaks screen coordinates (bottom-left origin).
enum ScreenGeometry {
    static var mainHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func toAppKit(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func toCoreGraphics(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static var unionFrame: CGRect {
        NSScreen.screens.reduce(CGRect.zero) { $0.union($1.frame) }
    }

    /// The display a rect mostly sits on, and the rect expressed in that display's own
    /// points with a top-left origin — which is what SCStreamConfiguration.sourceRect wants.
    static func displayRelative(_ globalRect: CGRect) -> (CGDirectDisplayID, CGRect)? {
        let screen = NSScreen.screens.max { a, b in
            a.frame.intersection(globalRect).area < b.frame.intersection(globalRect).area
        }
        guard let screen, let id = screen.displayID else { return nil }
        let clipped = globalRect.intersection(screen.frame)
        guard clipped.width > 4, clipped.height > 4 else { return nil }
        return (id, CGRect(x: clipped.minX - screen.frame.minX,
                           y: screen.frame.maxY - clipped.maxY,
                           width: clipped.width, height: clipped.height).integral)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

// MARK: - Area selection

/// The dimmed area selector. Unlike a one-shot picker it stays on screen while the
/// capture bar is up, and the rectangle can be moved and resized — and is remembered
/// for next time, the way QuickTime remembers your last selection.
@MainActor
final class SelectionOverlay {
    private var window: OverlayWindow?
    private var view: SelectionView?

    var onChange: ((CGRect) -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    var isVisible: Bool { window?.isVisible ?? false }
    var selection: CGRect? { view?.selection.map { $0.offsetBy(dx: frameOrigin.x, dy: frameOrigin.y) } }
    private var frameOrigin: CGPoint { window?.frame.origin ?? .zero }

    func show(initial: CGRect?) {
        let frame = ScreenGeometry.unionFrame
        let window = self.window ?? OverlayWindow(frame: frame, interactive: true)
        window.setFrame(frame, display: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        // Setting the level clears collectionBehavior, so re-apply it afterwards or the
        // selection stays behind on one Space while the bar follows you to the next.
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = self.view ?? SelectionView(frame: NSRect(origin: .zero, size: frame.size))
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.selection = initial.map { $0.offsetBy(dx: -frame.origin.x, dy: -frame.origin.y) }
        view.onChange = { [weak self] rect in
            guard let self else { return }
            self.onChange?(rect.offsetBy(dx: frame.origin.x, dy: frame.origin.y))
        }
        view.onCommit = { [weak self] in self?.onCommit?() }
        view.onCancel = { [weak self] in self?.onCancel?() }

        window.contentView = view
        window.orderFrontRegardless()
        window.makeFirstResponder(view)
        self.window = window
        self.view = view
    }

    func hide() { window?.orderOut(nil) }
    func close() { window?.orderOut(nil); window = nil; view = nil }
}

private final class SelectionView: NSView {
    var selection: NSRect? { didSet { needsDisplay = true } }
    var onChange: ((NSRect) -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    private enum Drag {
        case none, creating(NSPoint), moving(NSPoint, NSRect), resizing(Handle, NSRect)
    }
    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }
    private var drag: Drag = .none
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard let rect = selection, rect.width > 2, rect.height > 2 else {
            drawHint("Drag to choose an area, then press Record")
            return
        }

        NSColor.clear.setFill()
        rect.fill(using: .copy)

        NSColor.white.withAlphaComponent(0.95).setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 2
        border.stroke()

        for handle in Handle.allCases {
            let point = position(of: handle, in: rect)
            let box = NSRect(x: point.x - 4.5, y: point.y - 4.5, width: 9, height: 9)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: box).fill()
            NSColor.black.withAlphaComponent(0.45).setStroke()
            let ring = NSBezierPath(ovalIn: box)
            ring.lineWidth = 1
            ring.stroke()
        }

        let text = "\(Int(rect.width)) × \(Int(rect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        let badge = NSRect(x: rect.midX - size.width / 2 - 7,
                           y: max(6, rect.minY - size.height - 10),
                           width: size.width + 14, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5).fill()
        text.draw(at: NSPoint(x: badge.minX + 7, y: badge.minY + 3), withAttributes: attrs)
    }

    private func drawHint(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ]
        let size = text.size(withAttributes: attrs)
        let box = NSRect(x: bounds.midX - size.width / 2 - 14,
                         y: bounds.midY - size.height / 2 - 8,
                         width: size.width + 28, height: size.height + 16)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        text.draw(at: NSPoint(x: box.minX + 14, y: box.minY + 8), withAttributes: attrs)
    }

    private func position(of handle: Handle, in rect: NSRect) -> NSPoint {
        switch handle {
        case .topLeft:     return NSPoint(x: rect.minX, y: rect.maxY)
        case .top:         return NSPoint(x: rect.midX, y: rect.maxY)
        case .topRight:    return NSPoint(x: rect.maxX, y: rect.maxY)
        case .right:       return NSPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return NSPoint(x: rect.maxX, y: rect.minY)
        case .bottom:      return NSPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft:  return NSPoint(x: rect.minX, y: rect.minY)
        case .left:        return NSPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func handle(at point: NSPoint) -> Handle? {
        guard let rect = selection else { return nil }
        return Handle.allCases.first { position(of: $0, in: rect).distance(to: point) <= 10 }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let handle = handle(at: point), let rect = selection {
            drag = .resizing(handle, rect)
        } else if let rect = selection, rect.contains(point) {
            drag = .moving(point, rect)
        } else {
            drag = .creating(point)
            selection = NSRect(origin: point, size: .zero)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .none:
            return
        case .creating(let start):
            selection = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                               width: abs(start.x - point.x), height: abs(start.y - point.y))
        case .moving(let start, let original):
            var moved = original.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            moved.origin.x = min(max(0, moved.origin.x), bounds.width - moved.width)
            moved.origin.y = min(max(0, moved.origin.y), bounds.height - moved.height)
            selection = moved
        case .resizing(let handle, let original):
            selection = resize(original, handle: handle, to: point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        drag = .none
        if let rect = selection {
            if rect.width < 12 || rect.height < 12 {
                selection = nil
            } else {
                onChange?(rect)
            }
        }
    }

    private func resize(_ rect: NSRect, handle: Handle, to point: NSPoint) -> NSRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .topLeft:     minX = point.x; maxY = point.y
        case .top:         maxY = point.y
        case .topRight:    maxX = point.x; maxY = point.y
        case .right:       maxX = point.x
        case .bottomRight: maxX = point.x; minY = point.y
        case .bottom:      minY = point.y
        case .bottomLeft:  minX = point.x; minY = point.y
        case .left:        minX = point.x
        }
        return NSRect(x: min(minX, maxX), y: min(minY, maxY),
                      width: abs(maxX - minX), height: abs(maxY - minY))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()                       // esc
        case 36, 76: onCommit?()                   // return / enter
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private extension NSPoint {
    func distance(to other: NSPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
