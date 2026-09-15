import AppKit

/// Compile with the production StaticGlassRim.swift; no copied drawing algorithm.
@main struct StaticGlassRimCheck {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.main else { fatalError("Desktop unavailable") }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 50),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let rim = StaticGlassRim(frame: NSRect(x: 0, y: 0, width: 400, height: 50))
        window.contentView = rim
        rim.updateLayer()
        let original = rim.layer!.contents as! CGImage
        let scale = window.backingScaleFactor
        precondition(original.width < Int(400 * scale) && original.height < Int(50 * scale))
        // Repeated layout, appearance invalidation and window movement must reuse
        // the same bitmap. The optional flow clock never participates here.
        for index in 0..<20 {
            window.setFrameOrigin(NSPoint(x: 100 + index, y: 100))
            rim.setFrameSize(rim.frame.size)
            rim.needsDisplay = true
            rim.updateLayer()
            precondition((rim.layer!.contents as! CGImage) === original)
        }
        var generationMilliseconds: [Double] = []
        for size in [NSSize(width: 650, height: 110), NSSize(width: 800, height: 250),
                     NSSize(width: 400, height: 50)] {
            window.setContentSize(size)
            let began = ProcessInfo.processInfo.systemUptime
            rim.updateLayer()
            generationMilliseconds.append((ProcessInfo.processInfo.systemUptime - began) * 1000)
            let image = rim.layer!.contents as! CGImage
            precondition(image === original)
        }
        let image = rim.layer!.contents as! CGImage
        let data = image.dataProvider!.data! as Data
        // Verify the explicitly requested 0.85 pt width without changing white opacity.
        let x = image.width / 2
        let alpha = (0..<min(8, image.height)).map { Int(data[($0 * image.width + x) * 4 + 3]) }
        let expected = 0.85 * scale * 0.4 * 255
        precondition(abs(Double(alpha.reduce(0, +)) - expected) < 2)
        precondition(data[(image.height / 2 * image.width + x) * 4 + 3] == 0)
        rim.cornerRadius = 12
        rim.updateLayer()
        precondition((rim.layer!.contents as! CGImage) !== image)
        window.setContentSize(NSSize(width: 412, height: 62))
        let shadow = StaticGlassOuterShadow(frame: NSRect(x: 0, y: 0, width: 412, height: 62))
        window.contentView = shadow
        shadow.appearance = NSAppearance(named: .aqua)
        shadow.updateLayer()
        let shadowImage = shadow.layer!.contents as! CGImage
        let shadowData = shadowImage.dataProvider!.data! as Data
        let sx = shadowImage.width / 2
        let sy = shadowImage.height / 2
        precondition(shadowData[sy * shadowImage.bytesPerRow + sx * 4 + 3] == 0)
        let outsideY = Int(shadow.extent * scale) - 1
        precondition(shadowData[outsideY * shadowImage.bytesPerRow + sx * 4 + 3] > 0)
        let outermostAlpha = Int(shadowData[sx * 4 + 3])
        precondition(Double(outermostAlpha) * 0.20 <= 2)
        precondition(abs(shadow.layer!.opacity - 0.20) < 0.001)
        for size in [NSSize(width: 650, height: 110), NSSize(width: 800, height: 250), NSSize(width: 412, height: 62)] {
            window.setContentSize(size)
            shadow.updateLayer()
            precondition((shadow.layer!.contents as! CGImage) === shadowImage)
        }
        shadow.appearance = NSAppearance(named: .darkAqua)
        shadow.updateLayer()
        precondition((shadow.layer!.contents as! CGImage) === shadowImage)
        precondition(abs(shadow.layer!.opacity - 0.14) < 0.001)
        let result: [String: Any] = [
            "scope": "production_static_rim_cache_and_geometry_not_visual_acceptance",
            "screen_scale": screen.backingScaleFactor, "window_scale": scale,
            "contents_scale": rim.layer!.contentsScale,
            "bitmap_bytes": image.bytesPerRow * image.height,
            "same_geometry_and_20_moves_reuse_image": true,
            "resize_reuses_corner_atlas_radius_invalidates": true,
            "straight_alpha_integral": alpha.reduce(0, +),
            "expected_straight_alpha_integral": expected,
            "center_transparent": true, "resize_cache_check_ms": generationMilliseconds,
            "shadow_center_transparent_outside_nonzero": true,
            "shadow_resize_and_theme_reuse_image": true,
            "shadow_light_opacity": 0.20, "shadow_dark_opacity": 0.14,
            "shadow_outermost_alpha_before_opacity": outermostAlpha,
            "shadow_bitmap_bytes": shadowImage.bytesPerRow * shadowImage.height
        ]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
        window.orderOut(nil)
    }
}
