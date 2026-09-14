import AppKit
import LabSupport

final class FramePanel: NSPanel {
    var style: GlassStyle
    var shadowInset: Double { style.shadowExtent }
    private var mouseMonitors: [Any] = []
    var draggingGlass = false
    init(screen: NSScreen, style: GlassStyle = GlassStyle()) throws {
        self.style = try style.validated()
        let size = try FramePixelSize.minimum.points(backingScale: screen.backingScaleFactor)
        let panelSize = NSSize(width: size.width + style.shadowExtent * 2, height: size.height + style.shadowExtent * 2)
        let origin = NSPoint(x: screen.visibleFrame.midX - panelSize.width / 2,
                             y: screen.visibleFrame.midY - panelSize.height / 2)
        super.init(contentRect: NSRect(origin: origin, size: panelSize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "GlassFrame"
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        minSize = .zero
        contentMinSize = .zero
        setContentSize(panelSize)
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        let surface = FrameSurface(frame: NSRect(origin: .zero, size: panelSize))
        surface.wantsLayer = true
        surface.layerContentsRedrawPolicy = .onSetNeedsDisplay
        contentView = surface
        acceptsMouseMovedEvents = true
        // Event-driven pass-through: no timer and no pointer recording.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                          .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.updateMousePassThrough(event: event)
            return event
        }) { mouseMonitors.append(monitor) }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.updateMousePassThrough(event: event)
        }) { mouseMonitors.append(monitor) }
        updateMousePassThrough()
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        updateMousePassThrough()
    }

    private func updateMousePassThrough(event: NSEvent? = nil) {
        if draggingGlass { ignoresMouseEvents = false; return }
        let glass = glassFrame
        let radius = min(style.cornerRadius, min(glass.width, glass.height) / 2)
        let point: NSPoint
        if let event, let eventWindow = event.window {
            point = eventWindow.convertPoint(toScreen: event.locationInWindow)
        } else if let location = event?.cgEvent?.location, let primary = NSScreen.screens.first {
            point = NSPoint(x: location.x, y: primary.frame.maxY - location.y)
        } else { point = NSEvent.mouseLocation }
        let ignore = !NSBezierPath(roundedRect: glass, xRadius: radius, yRadius: radius).contains(point)
        if ignoresMouseEvents != ignore { ignoresMouseEvents = ignore }
    }

    func finishGlassDrag(event: NSEvent) {
        draggingGlass = false
        updateMousePassThrough(event: event)
    }

    deinit { mouseMonitors.forEach { NSEvent.removeMonitor($0) } }
}

extension NSWindow {
    var glassFrame: NSRect {
        guard let panel = self as? FramePanel else { return convertToScreen(contentLayoutRect) }
        return frame.insetBy(dx: panel.shadowInset, dy: panel.shadowInset)
    }
    var glassRectInWindow: NSRect {
        glassFrame.offsetBy(dx: -frame.minX, dy: -frame.minY)
    }
}

/// WP-01 window carrier only. Real captured/blurred material arrives in WP-04.
final class FrameSurface: NSView {
    var dragActivity: ((Bool) -> Void)?
    var flowToggle: (() -> Void)?
    var flowEnabled: (() -> Bool)?
    var materialStatus: (() -> String)?
    var reconnectMaterial: (() -> Void)?
    var requestOrigin: ((NSPoint) -> Void)?
    var carrierVisible = true { didSet { needsDisplay = true } }
    private(set) var fallbackActive = false
    private var fallbackView: PassiveVisualEffectView?
    private var dragAnchor: NSPoint?
    private var dragOrigin: NSPoint?
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    // Successful glass has no CPU-drawn carrier pixels. Drop the old carrier
    // backing content instead of asking AppKit to maintain a transparent image.
    override var wantsUpdateLayer: Bool { !carrierVisible && !fallbackActive }
    override func updateLayer() {
        layer?.contents = nil
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // The successful Metal path only needs a cached transparent backing.
        // Carrier/fallback paths still redraw their size-dependent outline.
        if carrierVisible || fallbackActive { needsDisplay = true }
    }
    func showFallback(_ active: Bool) {
        guard active != fallbackActive else { return }
        fallbackActive = active
        if active, fallbackView == nil {
            let effect = PassiveVisualEffectView(frame: .zero)
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.masksToBounds = true
            addSubview(effect, positioned: .below, relativeTo: subviews.first)
            fallbackView = effect
        }
        fallbackView?.isHidden = !active
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        // A hidden fallback does not need geometry/vibrancy updates on every
        // Metal resize. showFallback marks layout dirty when it becomes active.
        guard fallbackActive, let effect = fallbackView else { return }
        let glass = window?.glassRectInWindow ?? bounds
        effect.frame = glass
        effect.layer?.cornerRadius = min((window as? FramePanel)?.style.cornerRadius ?? 16, min(glass.width, glass.height)/2)
        effect.layer?.borderWidth = 0.55
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragAnchor = window.convertPoint(toScreen: event.locationInWindow)
        dragOrigin = window.frame.origin
        (window as? FramePanel)?.draggingGlass = true
        dragActivity?(true)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let anchor = dragAnchor, let origin = dragOrigin else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let target = NSPoint(x: origin.x + point.x - anchor.x, y: origin.y + point.y - anchor.y)
        if let requestOrigin { requestOrigin(target) } else { window.setFrameOrigin(target) }
    }
    override func mouseUp(with event: NSEvent) {
        dragAnchor = nil
        dragOrigin = nil
        (window as? FramePanel)?.finishGlassDrag(event: event)
        dragActivity?(false)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        guard carrierVisible || fallbackActive else { return }
        let glass = window?.glassRectInWindow ?? bounds
        let radius = min((window as? FramePanel)?.style.cornerRadius ?? 16, min(glass.width, glass.height) / 2)
        let path = NSBezierPath(roundedRect: glass.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        if fallbackActive {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowOffset = .zero
            shadow.shadowBlurRadius = (window as? FramePanel)?.shadowInset ?? 6
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.14)
            shadow.set()
            // Do not put an opaque plate behind the native fallback material.
            NSColor.black.withAlphaComponent(0.04).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        // Temporary outline makes the transparent carrier discoverable for window tests.
        NSColor.white.withAlphaComponent(0.07).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.65).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let glass = window?.glassRectInWindow ?? bounds
        let radius = min((window as? FramePanel)?.style.cornerRadius ?? 16, min(glass.width, glass.height) / 2)
        guard NSBezierPath(roundedRect: glass, xRadius: radius, yRadius: radius).contains(point) else { return nil }
        return super.hitTest(point)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if let materialStatus {
            let status = NSMenuItem(title: materialStatus(), action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            let reconnect = NSMenuItem(title: "查看原因 / 重新连接背景…", action: #selector(reconnectBackground), keyEquivalent: "")
            reconnect.target = self
            menu.addItem(reconnect)
            menu.addItem(.separator())
        }
        if flowToggle != nil {
            let flow = NSMenuItem(title: "流光效果", action: #selector(toggleFlow), keyEquivalent: "")
            flow.target = self
            flow.state = flowEnabled?() == true ? .on : .off
            menu.addItem(flow)
            menu.addItem(.separator())
        }
        let close = NSMenuItem(title: "关闭", action: #selector(closeFrame), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        return menu
    }

    @objc private func toggleFlow() { flowToggle?() }
    @objc private func reconnectBackground() { reconnectMaterial?() }

    @objc private func closeFrame() {
        window?.close()
    }
}

/// The material never takes the frame's drag or context-menu events.
private final class PassiveVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
