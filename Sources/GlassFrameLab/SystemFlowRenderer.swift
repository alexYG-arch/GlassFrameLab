import AppKit
import MetalKit
import LabSupport

/// Transparent decoration only. No capture texture, blur, statistics or intermediate texture.
@MainActor final class SystemFlowRenderer {
    let view: MTKView
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private(set) var submissions = 0
    private(set) var inFlight = false
    private(set) var lastPresentedLight = -1.0 // No drawable presented yet.
    let metrics = RenderMetrics()
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    func waitUntilIdle() async {
        if !inFlight { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    init(frame: CGRect) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw OptionError.invalid("Metal decoration unavailable")
        }
        self.queue = queue
        view = SystemFlowView(frame: frame, device: device)
        view.autoresizingMask = [.width, .height]
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = false
        view.framebufferOnly = true
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.layer?.isOpaque = false
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        (view.layer as? CAMetalLayer)?.presentsWithTransaction = true
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "flowVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "flowFragment")
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Geometry is committed with the completed drawable, avoiding stretching an old corner.
    func render(size: CGSize, scale: Double, style: GlassStyle, flow: BorderFlowStyle,
                phase: Double, light: Double, beforePresent: () -> Bool) async throws -> Bool {
        guard !inFlight, let layer = view.layer as? CAMetalLayer else { return false }
        inFlight = true
        defer {
            inFlight = false
            let waiters = idleWaiters; idleWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        let pixels = CGSize(width: (size.width*scale).rounded(), height: (size.height*scale).rounded())
        layer.contentsScale = scale
        view.drawableSize = pixels
        layer.drawableSize = pixels
        guard let drawable = layer.nextDrawable(), let command = queue.makeCommandBuffer() else {
            throw OptionError.invalid("System decoration drawable unavailable")
        }
        let glass = CGSize(width: size.width-2*style.shadowExtent, height: size.height-2*style.shadowExtent)
        var uniforms = [SIMD4<Float>(Float(glass.width), Float(glass.height), Float(scale), Float(min(style.cornerRadius,min(glass.width,glass.height)/2))),
            SIMD4<Float>(Float(style.shadowExtent),Float(light),0,0),
            SIMD4<Float>(Float(phase),Float(flow.tailFraction),flow.clockwise ? 1 : -1,flow.enabled ? Float(flow.strength) : 0),
            SIMD4<Float>(Float(flow.innerGlowGain),Float(flow.innerShadeGain),Float(flow.spread),Float(light)),
            SIMD4<Float>(Float(flow.headColor[0]),Float(flow.headColor[1]),Float(flow.headColor[2]),0),
            SIMD4<Float>(Float(flow.tailColor[0]),Float(flow.tailColor[1]),Float(flow.tailColor[2]),0)]
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = view.clearColor
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw OptionError.invalid("System decoration encoder unavailable") }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride*uniforms.count,index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        submissions += 1
        let receipt = FramePresentationReceipt(metrics: metrics, captured: 0, sequence: submissions)
        drawable.addPresentedHandler { receipt.presented(at: $0.presentedTime) }
        let success: Bool = await withCheckedContinuation { continuation in
            command.addCompletedHandler { buffer in
                receipt.completed(gpuMilliseconds: max(0,buffer.gpuEndTime-buffer.gpuStartTime)*1000)
                continuation.resume(returning: buffer.status == .completed)
            }
            command.commit()
        }
        guard success else { throw OptionError.invalid("System decoration GPU command failed") }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let present = beforePresent()
        if present { drawable.present(); lastPresentedLight = light }
        CATransaction.commit()
        return present
    }

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct VertexOut { float4 position [[position]]; };
    vertex VertexOut flowVertex(uint id [[vertex_id]]) {
        float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
        return {float4(p[id],0,1)};
    }
    """ + BorderFlowShader.source + """
    fragment float4 flowFragment(VertexOut in [[stage_in]], constant float4 *u [[buffer(0)]]) {
        float2 size=u[0].xy;
        float2 p=in.position.xy/u[0].z-u[1].x;
        float radius=u[0].w, aa=1.0/u[0].z;
        float2 q=abs(p-size*.5)-(size*.5-radius);
        float d=length(max(q,0.0))+min(max(q.x,q.y),0.0)-radius;
        float coverage=1.0-smoothstep(-aa*.5,aa*.5,d);
        float4 flow=borderFlow(p,size,radius,d,aa,u[2],u[3]);
        float3 color=mix(u[4].rgb,u[5].rgb,smoothstep(0.0,.9,flow.w));
        color=flowToSRGB(adaptFlowColor(color,u[1].y));
        float shade=clamp(flow.z*coverage*(1-u[1].y),0.0,1.0);
        float spill=clamp(flow.y*coverage,0.0,1.0);
        float edge=clamp(flow.x*(1-u[1].y),0.0,1.0);
        float alpha=spill+shade*(1-spill);
        float3 rgb=color*spill;
        rgb=color*edge+rgb*(1-edge);
        alpha=edge+alpha*(1-edge);
        // The sRGB render target encodes once. WindowServer receives encoded,
        // premultiplied RGB, never RGB greater than alpha on the arc fades.
        return float4(flowToLinear(clamp(rgb,0.0,alpha)),alpha);
    }
    """
}

private final class SystemFlowView: MTKView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
