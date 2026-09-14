// Executes the production shader against fixed inputs; no screen access or app bundle.
import AppKit
import Metal
import LabSupport

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let width = 824, height = 124
let glass = GlassStyle(), flow = BorderFlowStyle()
let currentSource = try String(contentsOf: output.appendingPathComponent("current.metal"), encoding: .utf8)
let current = try device.makeLibrary(source: currentSource, options: nil)
// Fixture-only layer isolation; both variants still execute the production fragment.
let lineOnly = try device.makeLibrary(source: currentSource.replacingOccurrences(of: "float outer = flow.x", with: "flow.y = 0; flow.z = 0; float outer = flow.x"), options: nil)
let spillOnly = try device.makeLibrary(source: currentSource.replacingOccurrences(of: "float outer = flow.x", with: "flow.x = 0; float outer = flow.x"), options: nil)
let old = try device.makeLibrary(source: String(contentsOf: output.appendingPathComponent("baseline.metal"), encoding: .utf8), options: nil)
var results: [[String: Any]] = []
func vector(_ a: [Double], _ w: Double = 0) -> SIMD4<Float> { SIMD4(Float(a[0]),Float(a[1]),Float(a[2]),Float(w)) }
// Query the production color function on the GPU, independent of image appearance.
var colorInputs = [vector(flow.headColor,1),vector(flow.tailColor,1),vector(zip(flow.headColor,flow.tailColor).map { ($0+$1)/2 },1)]
let inputColors=device.makeBuffer(bytes:&colorInputs,length:48,options:.storageModeShared)!
let outputColors=device.makeBuffer(length:48,options:.storageModeShared)!
let colorCommand=queue.makeCommandBuffer()!
let c=colorCommand.makeComputeCommandEncoder()!
c.setComputePipelineState(try device.makeComputePipelineState(function:current.makeFunction(name:"checkFlowColors")!))
c.setBuffer(inputColors,offset:0,index:0);c.setBuffer(outputColors,offset:0,index:1)
c.dispatchThreads(MTLSize(width:3,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:1,height:1,depth:1));c.endEncoding()
colorCommand.commit();colorCommand.waitUntilCompleted()
if let error=colorCommand.error { throw error }
let colorPointer=outputColors.contents().bindMemory(to:SIMD4<Float>.self,capacity:3)
let colorRows=(0..<3).map { i in ["input":[colorInputs[i].x,colorInputs[i].y,colorInputs[i].z],"output":[colorPointer[i].x,colorPointer[i].y,colorPointer[i].z]] }
try JSONSerialization.data(withJSONObject:colorRows,options:.prettyPrinted).write(to:output.appendingPathComponent("flow-colors.json"))
for name in ["white","gray","warm","cool","dark","dark-detail","mixed","pattern"] {
    var pixels = [UInt8](repeating: 255, count: width*height*4)
    for y in 0..<height { for x in 0..<width {
        let rgb: [UInt8]
        switch name {
        case "white": rgb = [255,255,255]
        case "gray": rgb = [242,242,242]
        case "warm": rgb = [252,246,235]
        case "cool": rgb = [239,246,255]
        case "dark": rgb = [19,23,31]
        case "dark-detail": rgb = x % 90 < 30 ? [20,40,60] : [10,15,23]
        case "mixed": rgb = x < width/2 ? [20,20,20] : [255,255,255]
        default: rgb = [UInt8(100+80*sin(Double(x)/45)),UInt8(100+70*cos(Double(x)/70)),UInt8(110+80*sin(Double(y)/60))]
        }
        let i=(y*width+x)*4; pixels[i]=rgb[2];pixels[i+1]=rgb[1];pixels[i+2]=rgb[0]
    }}
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
    desc.storageMode = .shared; desc.usage = [.shaderRead, .renderTarget]
    let input = device.makeTexture(descriptor: desc)!
    input.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: width*4)
    for mode in ["baseline","adaptive-off","adaptive-on","flow","flow-base-off","flow-line","flow-spill"] {
        let library = mode == "baseline" ? old : (mode == "flow-line" ? lineOnly : (mode == "flow-spill" ? spillOnly : current))
        let render = MTLRenderPipelineDescriptor()
        render.vertexFunction = library.makeFunction(name: "glassVertex")
        render.fragmentFunction = library.makeFunction(name: "glassFragment")
        render.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        let pipeline = try device.makeRenderPipelineState(descriptor: render)
        let phases: [Float] = mode == "flow" ? [0.02,0.30,0.45,0.52,0.80,0.95] : [0.30]
        for phase in phases {
            let target = device.makeTexture(descriptor: desc)!
            let stats = device.makeBuffer(length: 16, options: .storageModeShared)!
            stats.contents().storeBytes(of: SIMD4<Float>.zero, as: SIMD4<Float>.self)
            let enabled = mode.hasPrefix("flow")
            let adaptive = mode == "adaptive-on" || (enabled && mode != "flow-base-off")
            var u: [SIMD4<Float>] = [SIMD4(400,50,2,16),SIMD4(6.0/412,6.0/62,400.0/412,50.0/62),
                SIMD4(Float(glass.shadowExtent),Float(glass.shadowOpacity),Float(glass.innerStrength),Float(glass.innerWidth)),
                SIMD4(Float(glass.strokeWidth),Float(glass.strokeOpacity),Float(glass.saturation),Float(glass.brightness)),
                vector(glass.tintColor, glass.tintOpacity),SIMD4(Float(glass.lightDirection[0]),Float(glass.lightDirection[1]),Float(glass.nonuniformity),Float(glass.innerShade)),
                vector(glass.shadowColor),vector(glass.innerColor),vector(glass.strokeColor, adaptive ? 1 : 0),
                SIMD4(phase,Float(flow.tailFraction),1,enabled ? Float(flow.strength) : 0),
                SIMD4(Float(flow.innerGlowGain),Float(flow.innerShadeGain),Float(flow.spread),0),vector(flow.headColor),vector(flow.tailColor)]
            let command = queue.makeCommandBuffer()!
            if mode != "baseline", adaptive || enabled {
                let compute = command.makeComputeCommandEncoder()!
                compute.setComputePipelineState(try device.makeComputePipelineState(function: current.makeFunction(name: "materialStatistics")!))
                compute.setTexture(input,index:0); var crop=u[1]
                compute.setBytes(&crop,length:16,index:0);compute.setBuffer(stats,offset:0,index:1)
                compute.dispatchThreads(MTLSize(width:1,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:1,height:1,depth:1));compute.endEncoding()
            }
            let pass = MTLRenderPassDescriptor();pass.colorAttachments[0].texture=target
            pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
            let encoder=command.makeRenderCommandEncoder(descriptor:pass)!
            encoder.setRenderPipelineState(pipeline);encoder.setFragmentTexture(input,index:0)
            encoder.setFragmentBytes(&u,length:u.count*16,index:0)
            if mode != "baseline" { encoder.setFragmentBuffer(stats,offset:0,index:1) }
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3);encoder.endEncoding()
            command.commit();command.waitUntilCompleted()
            if let error=command.error { throw error }
            let values=stats.contents().load(as:SIMD4<Float>.self)
            var bytes=[UInt8](repeating:0,count:width*height*4)
            target.getBytes(&bytes,bytesPerRow:width*4,from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0)
            let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:width*4,bitsPerPixel:32)!
            for i in stride(from:0,to:bytes.count,by:4) {
                bitmap.bitmapData![i]=bytes[i+2];bitmap.bitmapData![i+1]=bytes[i+1];bitmap.bitmapData![i+2]=bytes[i];bitmap.bitmapData![i+3]=bytes[i+3]
            }
            let filename="\(name)-\(mode)-\(String(format:"%.2f",phase)).png"
            try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(filename))
            results.append(["input":name,"mode":mode,"phase":phase,"statistics":[values.x,values.y,values.z,values.w],"file":filename])
        }
    }
}
try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("render-results.json"))
print("RENDERED \(results.count) images")
