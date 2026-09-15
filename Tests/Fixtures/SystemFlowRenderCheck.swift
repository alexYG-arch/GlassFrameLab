// Render the extracted production overlay against transparency, without a window/background.
import AppKit
import Metal
import LabSupport
let output=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
let source=try String(contentsOf:output.appendingPathComponent("overlay.metal"),encoding:.utf8)
let device=MTLCreateSystemDefaultDevice()!, queue=device.makeCommandQueue()!
let flow=BorderFlowStyle()
func color(_ c:[Double])->SIMD4<Float>{SIMD4(Float(c[0]),Float(c[1]),Float(c[2]),0)}
for mode in ["full","spill","line","off"] {
    let code=mode == "spill" ? source.replacingOccurrences(of:"float edge=clamp(flow.x*(1-u[1].y),0.0,1.0);",with:"float edge=0;") : source
    let lib=try device.makeLibrary(source:code,options:nil)
    let desc=MTLRenderPipelineDescriptor()
    desc.vertexFunction=lib.makeFunction(name:"flowVertex");desc.fragmentFunction=lib.makeFunction(name:"flowFragment")
    desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
    let pipe=try device.makeRenderPipelineState(descriptor:desc)
    for light:Float in [0,0.5,1] { for phase:Float in [0,0.30,0.435,0.485,0.52,0.935,0.985] {
        let textureDesc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm_srgb,width:824,height:124,mipmapped:false)
        textureDesc.storageMode = .shared;textureDesc.usage = .renderTarget
        let target=device.makeTexture(descriptor:textureDesc)!
        var u:[SIMD4<Float>] = [SIMD4(400,50,2,16),SIMD4(6,light,0,0),
            SIMD4(phase,Float(flow.tailFraction),1,mode == "off" ? 0 : Float(flow.strength)),
            SIMD4(mode == "line" ? 0 : Float(flow.innerGlowGain),mode == "line" ? 0 : Float(flow.innerShadeGain),Float(flow.spread),light),color(flow.headColor),color(flow.tailColor)]
        let command=queue.makeCommandBuffer()!
        let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=target
        pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
        let enc=command.makeRenderCommandEncoder(descriptor:pass)!
        enc.setRenderPipelineState(pipe);enc.setFragmentBytes(&u,length:u.count*16,index:0)
        enc.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);enc.endEncoding()
        command.commit();command.waitUntilCompleted();if let error=command.error { throw error }
        var bytes=[UInt8](repeating:0,count:824*124*4)
        target.getBytes(&bytes,bytesPerRow:824*4,from:MTLRegionMake2D(0,0,824,124),mipmapLevel:0)
        try Data(bytes).write(to:output.appendingPathComponent(String(format:"%@-%.1f-%.3f.bgra",mode,light,phase)))
    }}
}
