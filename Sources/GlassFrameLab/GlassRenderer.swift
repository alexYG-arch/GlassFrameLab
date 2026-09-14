import AppKit
import MetalKit
import MetalPerformanceShaders
import LabSupport

@MainActor final class GlassRenderer {
    let rasterDiagnostics = ProcessInfo.processInfo.environment["GLASS_RASTER_DIAGNOSTICS"] == "1"
    let view: MTKView
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let adaptive: Bool
    private let statisticsPipeline: MTLComputePipelineState?
    private let statistics: MTLBuffer
    private var statisticsSequence: Int?
    private var statisticsCrop: SIMD4<Float>?
    private(set) var statisticsEncodes = 0
    var statisticsBytes: Int { statistics.allocatedSize }
    private var blur: MPSImageGaussianBlur?
    private var cache: CVMetalTextureCache?
    private var blurred: MTLTexture?
    private(set) var style: GlassStyle
    private var shadowInset: Double { style.shadowExtent }
    private var lastBlurSequence: Int?
    private(set) var blurEncodes = 0
    private(set) var submissions = 0
    private(set) var textureAllocations = 0
    let metrics = RenderMetrics()
    private(set) var inFlight = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    var intermediateTextureCount: Int { blurred == nil ? 0 : 1 }

    init(frame: CGRect, style: GlassStyle, adaptive: Bool = true) throws {
        self.adaptive = adaptive
        self.style = try style.validated()
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw OptionError.invalid("Metal device/queue unavailable")
        }
        self.device = device
        self.queue = queue
        view = GlassMetalView(frame: frame, device: device)
        view.autoresizingMask = [.width, .height]
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = false
        view.framebufferOnly = true
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.layer?.isOpaque = false
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        (view.layer as? CAMetalLayer)?.presentsWithTransaction = false
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        guard let stats = device.makeBuffer(length: MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared) else {
            throw OptionError.invalid("Material statistics buffer unavailable")
        }
        statistics = stats
        statistics.contents().storeBytes(of: SIMD4<Float>.zero, as: SIMD4<Float>.self)
        if let function = library.makeFunction(name: "materialStatistics") {
            statisticsPipeline = try device.makeComputePipelineState(function: function)
        } else { statisticsPipeline = nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "glassVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "glassFragment")
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        blur = style.sigma > 0 ? MPSImageGaussianBlur(device: device, sigma: Float(style.sigma)) : nil
        blur?.edgeMode = .clamp
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess else {
            throw OptionError.invalid("CVMetalTextureCache creation failed")
        }
    }

    func applyStyle(_ next: GlassStyle) throws {
        let next = try next.validated()
        if next.sigma != style.sigma {
            blur = next.sigma > 0 ? MPSImageGaussianBlur(device: device, sigma: Float(next.sigma)) : nil
            blur?.edgeMode = .clamp
            lastBlurSequence = nil
        }
        style = next
        statisticsSequence = nil
    }

    func render(buffer: CVPixelBuffer, glassFrame: CGRect, displayFrame: CGRect, sourceRect: CGRect, scale: Double,
                captureTime: Double = 0, sequence: Int = 0, flow: BorderFlowStyle = BorderFlowStyle(), flowPhase: Double = 0, animationOnly: Bool = false, testPresentationDelay: UInt64 = 0, beforePresent: (() -> Bool)? = nil) async throws -> [String: Any] {
        guard let cache else { throw OptionError.invalid("Texture cache unavailable") }
        var wrapped: CVMetalTexture?
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil,
                                                               .bgra8Unorm_srgb, width, height, 0, &wrapped)
        guard status == kCVReturnSuccess, let wrapped, let input = CVMetalTextureGetTexture(wrapped) else {
            throw OptionError.invalid("Capture pixel buffer cannot bind to Metal: \(status)")
        }
        defer { withExtendedLifetime(wrapped) {} }
        let bucketWidth = ((width + 63) / 64) * 64, bucketHeight = ((height + 63) / 64) * 64
        if blurred?.width != bucketWidth || blurred?.height != bucketHeight {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: bucketWidth, height: bucketHeight, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .private
            blurred = device.makeTexture(descriptor: descriptor)
            textureAllocations += 1
            lastBlurSequence = nil
            statisticsSequence = nil
        }
        // Direct CAMetalLayer.nextDrawable() bypasses MTKView's lazy drawable resize.
        // Set the actual producer size, not only MTKView's requested size.
        guard let layer = view.layer as? CAMetalLayer else {
            throw OptionError.invalid("Metal layer unavailable")
        }
        let pixelSize = CGSize(width: ((glassFrame.width + shadowInset * 2) * scale).rounded(),
                               height: ((glassFrame.height + shadowInset * 2) * scale).rounded())
        view.drawableSize = pixelSize
        layer.contentsScale = scale
        layer.drawableSize = pixelSize
        guard let blurred, let command = queue.makeCommandBuffer(), let drawable = layer.nextDrawable() else {
            throw OptionError.invalid("Metal drawable or local blur texture unavailable")
        }
        guard drawable.texture.width == Int(pixelSize.width), drawable.texture.height == Int(pixelSize.height) else {
            throw OptionError.invalid("Drawable pixel size does not match geometry")
        }
        if rasterDiagnostics {
            let diagnostic: [String: Any] = ["uptime": ProcessInfo.processInfo.systemUptime,
                "requested": NSStringFromSize(view.drawableSize),
                "texture": "\(drawable.texture.width)x\(drawable.texture.height)",
                "glass": NSStringFromRect(glassFrame), "view": NSStringFromRect(view.bounds),
                "layer": NSStringFromRect(layer.bounds), "contents_scale": layer.contentsScale,
                "backing_scale": view.window?.backingScaleFactor ?? 0]
            if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print("RASTER " + text) }
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = view.clearColor
        if let blur, lastBlurSequence != sequence {
            blur.clipRect = MTLRegionMake2D(0, 0, width, height)
            blur.encode(commandBuffer: command, sourceTexture: input, destinationTexture: blurred)
            lastBlurSequence = sequence
            blurEncodes += 1
        }
        let glassTop = displayFrame.maxY - glassFrame.maxY
        var uniforms = [SIMD4<Float>(Float(glassFrame.width), Float(glassFrame.height), Float(scale), Float(min(style.cornerRadius, min(glassFrame.width, glassFrame.height) / 2))),
                        SIMD4<Float>(Float((glassFrame.minX - displayFrame.minX - sourceRect.minX) / sourceRect.width),
                                     Float((glassTop - sourceRect.minY) / sourceRect.height),
                                     Float(glassFrame.width / sourceRect.width), Float(glassFrame.height / sourceRect.height)),
                        SIMD4<Float>(Float(shadowInset), Float(style.shadowOpacity), Float(style.innerStrength), Float(min(style.innerWidth, min(glassFrame.width, glassFrame.height) * 0.12))),
                        SIMD4<Float>(Float(style.strokeWidth), Float(style.strokeOpacity), Float(style.saturation), Float(style.brightness)),
                        SIMD4<Float>(Float(style.tintColor[0]), Float(style.tintColor[1]), Float(style.tintColor[2]), Float(style.tintOpacity)),
                        SIMD4<Float>(Float(style.lightDirection[0]), Float(style.lightDirection[1]), Float(style.nonuniformity), Float(style.innerShade)),
                        SIMD4<Float>(Float(style.shadowColor[0]), Float(style.shadowColor[1]), Float(style.shadowColor[2]), 0),
                        SIMD4<Float>(Float(style.innerColor[0]), Float(style.innerColor[1]), Float(style.innerColor[2]), 0),
                        SIMD4<Float>(Float(style.strokeColor[0]), Float(style.strokeColor[1]), Float(style.strokeColor[2]), adaptive ? 1 : 0),
                        SIMD4<Float>(Float(flowPhase), Float(flow.tailFraction), flow.clockwise ? 1 : -1, flow.enabled ? Float(flow.strength) : 0),
                        SIMD4<Float>(Float(flow.innerGlowGain), Float(flow.innerShadeGain), Float(flow.spread), 0),
                        SIMD4<Float>(Float(flow.headColor[0]), Float(flow.headColor[1]), Float(flow.headColor[2]), 0),
                        SIMD4<Float>(Float(flow.tailColor[0]), Float(flow.tailColor[1]), Float(flow.tailColor[2]), 0)]
        if blur != nil {
            uniforms[1] *= SIMD4<Float>(Float(width) / Float(bucketWidth), Float(height) / Float(bucketHeight),
                                        Float(width) / Float(bucketWidth), Float(height) / Float(bucketHeight))
        }
        if (adaptive || flow.enabled), let statisticsPipeline, statisticsSequence != sequence || statisticsCrop != uniforms[1] {
            guard let compute = command.makeComputeCommandEncoder() else { throw OptionError.invalid("Material statistics encoder unavailable") }
            var crop = uniforms[1]
            compute.setComputePipelineState(statisticsPipeline)
            compute.setTexture(blur == nil ? input : blurred, index: 0)
            compute.setBytes(&crop, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            compute.setBuffer(statistics, offset: 0, index: 1)
            compute.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            compute.endEncoding()
            statisticsSequence = sequence
            statisticsCrop = uniforms[1]
            statisticsEncodes += 1
        }
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw OptionError.invalid("Metal render encoder unavailable")
        }
        encoder.setFragmentBuffer(statistics, offset: 0, index: 1)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(blur == nil ? input : blurred, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride * uniforms.count, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        let receipt = FramePresentationReceipt(metrics: metrics, captured: animationOnly ? 0 : captureTime, sequence: sequence)
        drawable.addPresentedHandler { drawable in
            receipt.presented(at: drawable.presentedTime)
        }
        submissions += 1
        inFlight = true
        defer {
            inFlight = false
            let waiters = idleWaiters
            idleWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        let result: (String?, Double) = await withCheckedContinuation { continuation in
            command.addCompletedHandler { completed in
                receipt.completed(gpuMilliseconds: (completed.gpuEndTime - completed.gpuStartTime) * 1000)
                continuation.resume(returning: (completed.error.map(String.init(describing:)),
                                                (completed.gpuEndTime - completed.gpuStartTime) * 1000))
            }
            command.commit()
        }
        if let error = result.0 { receipt.presented(at: 0); throw OptionError.invalid("Metal command failed: \(error)") }
        if testPresentationDelay > 0 { try? await Task.sleep(nanoseconds: testPresentationDelay) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let shouldPresent = beforePresent?() ?? true
        // Queue the completed image before flushing the matching window geometry.
        // Otherwise the compositor may observe the new bounds without its image.
        if shouldPresent { drawable.present() } else { receipt.presented(at: 0) }
        CATransaction.commit()
        CATransaction.flush()
        return ["gpu_command_ms": result.1, "submissions": submissions,
                "input_size_px": "\(width)x\(height)", "drawable_size_px": NSStringFromSize(view.drawableSize),
                "local_intermediate_textures": 1, "texture_allocations": textureAllocations, "blur_encodes": blurEncodes, "rendered": true]
    }

    func waitForIdle() async {
        guard inFlight else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    """ + BorderFlowShader.source + """
    struct Vertex { float4 position [[position]]; float2 uv; };
    struct Params { float4 geometry; float4 crop; float4 layout; float4 edge; float4 tint; float4 light; float4 shadow; float4 inner; float4 stroke; float4 flow; float4 optics; float4 headColor; float4 tailColor; };
    kernel void materialStatistics(texture2d<float, access::sample> background [[texture(0)]],
                                   constant float4& crop [[buffer(0)]], device float4& result [[buffer(1)]]) {
        constexpr sampler sampleLinear(coord::normalized, address::clamp_to_edge, filter::linear);
        float total = 0, dark = 0, rawTotal = 0;
        for (uint y=0; y<8; ++y) for (uint x=0; x<8; ++x) {
            float3 rgb = background.sample(sampleLinear, crop.xy + (float2(x,y)+.5)/8.0*crop.zw).rgb;
            float value = dot(rgb, float3(.2126,.7152,.0722));
            total += min(value,.20); dark += value <= .10 ? 1.0 : 0.0;
            rawTotal += value;
        }
        float L=total/64, D=dark/64;
        result=float4(L,D,(1-smoothstep(.025,.10,L))*smoothstep(.75,.95,D),rawTotal/64);
    }
    vertex Vertex glassVertex(uint index [[vertex_id]]) {
        float2 p = float2((index << 1) & 2, index & 2);
        return { float4(p * float2(2, -2) + float2(-1, 1), 0, 1), p };
    }
    fragment float4 glassFragment(Vertex in [[stage_in]], texture2d<float> background [[texture(0)]], constant Params& base [[buffer(0)]], device const float4& statistics [[buffer(1)]]) {
        Params p = base;
        float w = base.stroke.w > 0 ? statistics.z : 0;
        p.layout.y *= mix(1.0, .08/.14, w);
        p.layout.z *= mix(1.0, .055/.16, w);
        p.light.w *= mix(1.0, .025/.055, w);
        p.inner.rgb = mix(p.inner.rgb, float3(.30), w);
        p.edge.y *= mix(1.0, .16/.40, w);
        p.stroke.rgb = mix(p.stroke.rgb, float3(.45), w);
        p.tint.rgb = mix(p.tint.rgb, float3(0), w);
        p.tint.a = mix(p.tint.a, .012, w);
        constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 size = p.geometry.xy;
        float radius = p.geometry.w;
        float2 position = in.uv * (size + 2 * p.layout.x) - p.layout.x;
        float2 glassUV = position / size;
        float2 q = abs(position - size * .5) - (size * .5 - radius);
        float distance = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
        float aa = 1.0 / p.geometry.z;
        float alpha = 1.0 - smoothstep(-aa, aa, distance);
        float falloff = 1.0 - smoothstep(0.0, p.layout.x, max(distance, 0.0));
        float shadowAlpha = p.layout.y * falloff * falloff * (1.0 - alpha);
        float4 flowOptics = p.optics;
        flowOptics.w = smoothstep(.12, .60, statistics.w);
        float4 flow = borderFlow(position, size, radius, distance, aa, p.flow, flowOptics);
        // One shared blue-to-purple progression for both backgrounds.
        float3 flowColor = mix(p.headColor.rgb, p.tailColor.rgb,
                               smoothstep(0.0,.9,flow.w));
        if (flow.x + flow.y + flow.z > 0)
            flowColor = adaptFlowColor(flowColor, flowOptics.w);
        float outer = flow.x * (1-alpha) * falloff*falloff;
        if (alpha <= 0.0) {
            float4 baseShadow = float4(p.shadow.rgb*shadowAlpha,shadowAlpha);
            float4 legacy = float4(flowColor*outer + baseShadow.rgb*(1-outer), outer + shadowAlpha*(1-outer));
            if (flow.x <= 0 || flowOptics.w <= 0) return legacy;
            return mix(legacy,lightFlowOver(baseShadow,flowColor,flow,0),flowOptics.w);
        }
        float3 color = background.sample(linearSampler, p.crop.xy + glassUV * p.crop.zw).rgb;
        float luminance = dot(color, float3(.2126, .7152, .0722));
        color = mix(float3(luminance), color, p.edge.z) + p.edge.w;
        color = mix(color, p.tint.rgb, p.tint.a);
        float2 normal = sign(position - size * .5) * max(q, 0.0);
        if (dot(normal, normal) < .0001) normal = q.x > q.y ? float2(sign(position.x-size.x*.5),0) : float2(0,sign(position.y-size.y*.5));
        float light = .5 + .5 * dot(normal / max(length(normal), .001), normalize(p.light.xy));
        float depth = max(-distance, 0.0);
        float width = max(.1, p.layout.w * mix(1.0, .55 + .9 * light, p.light.z));
        float glow = p.layout.z * mix(1.0, .25 + .75 * light, p.light.z) * exp(-depth / width) * smoothstep(.15, 1.2, depth);
        float shade = p.light.w * mix(1.0, .25 + .75 * (1.0-light), p.light.z) * exp(-depth / (width * 1.6)) * smoothstep(0.0, .7, depth);
        color = mix(color * (1.0-shade), p.inner.rgb, glow);
        float edge = 1.0 - smoothstep(max(0.0,p.edge.x-aa*.4), p.edge.x+aa*.4, depth);
        color = mix(color, p.stroke.rgb, edge * p.edge.y * mix(1.0,.6+.4*light,p.light.z));
        float4 glassOnly = float4(clamp(color,0.0,1.0)*alpha + p.shadow.rgb*shadowAlpha,alpha+shadowAlpha);
        color = mix(color*(1-flow.z), flowColor, clamp(flow.y,0.0,1.0));
        color = mix(color, flowColor, clamp(flow.x,0.0,1.0));
        float4 baseResult = float4(clamp(color,0.0,1.0)*alpha + p.shadow.rgb*shadowAlpha, alpha+shadowAlpha);
        float4 legacy = float4(flowColor*outer + baseResult.rgb*(1-outer), outer + baseResult.a*(1-outer));
        if (flowOptics.w <= 0 || flow.x+flow.y+flow.z <= 0) return legacy;
        return mix(legacy,lightFlowOver(glassOnly,flowColor,flow,alpha),flowOptics.w);
    }
    """

    func writeBlurPNG(to url: URL) throws {
        guard let blurred, let input = CIImage(mtlTexture: blurred, options: [.colorSpace: CGColorSpaceCreateDeviceRGB()]) else {
            throw OptionError.invalid("No blur texture for diagnostic export")
        }
        try CIContext(mtlDevice: device).writePNGRepresentation(of: input, to: url, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    }
}

final class GlassMetalView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Development marker rendered at display resolution after the background material.
final class ForegroundProbeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        ("前景 Aa 123" as NSString).draw(at: NSPoint(x: 7, y: 5), withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white])
    }
}
