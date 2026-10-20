import Foundation
import MetalKit
import CryptoKit

enum NoctMetalError: Error, LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case .unavailable(let s) = self { return s }; return nil }
}

/// Fixed shaders only. Guest requests never contain shader code, file names,
/// native handles or Metal object identifiers.
final class NoctMetal {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let displayPipeline: MTLRenderPipelineState
    let trianglePipeline: MTLRenderPipelineState
    private let library: MTLLibrary
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Out { float4 position [[position]]; float4 color; float2 uv; };
    vertex Out screenVertex(uint id [[vertex_id]]) {
        const float2 p[] = {float2(-1,1),float2(-1,-1),float2(1,1),float2(1,-1)};
        const float2 uv[] = {float2(0,0),float2(0,1),float2(1,0),float2(1,1)};
        Out o; o.position=float4(p[id],0,1); o.uv=uv[id]; return o;
    }
    fragment float4 screenFragment(Out in [[stage_in]], texture2d<float> image [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        return float4(image.sample(s,in.uv).rgb,1);
    }
    struct Vertex { float2 position; float4 color; };
    vertex Out triangleVertex(uint id [[vertex_id]], const device Vertex* v [[buffer(0)]]) {
        Out o; o.position=float4(v[id].position,0,1); o.color=v[id].color; return o;
    }
    fragment float4 triangleFragment(Out in [[stage_in]]) { return in.color; }
    """
    init() throws {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else {
            throw NoctMetalError.unavailable("Metal is unavailable on this Mac.")
        }
        device = d; queue = q
        let shaders = try d.makeLibrary(source: Self.source, options: nil)
        library = shaders
        func pipeline(_ vertex: String, _ fragment: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let p = MTLRenderPipelineDescriptor()
            p.vertexFunction = shaders.makeFunction(name: vertex)
            p.fragmentFunction = shaders.makeFunction(name: fragment)
            p.colorAttachments[0].pixelFormat = format
            return try d.makeRenderPipelineState(descriptor: p)
        }
        displayPipeline = try pipeline("screenVertex", "screenFragment", .bgra8Unorm_srgb)
        trianglePipeline = try pipeline("triangleVertex", "triangleFragment", .rgba8Unorm)
    }

    struct Vertex { var position: SIMD2<Float>; var color: SIMD4<Float> }
    struct Result {
        let pixels: Data
        let gpuMilliseconds: Double
        let sha256: String
    }
    /// Offscreen proof/API for first-party Noct apps. This is deliberately a
    /// small raster API, not an OpenGL/Vulkan driver for arbitrary guest apps.
    func render(width: Int, height: Int, vertices: [Vertex], clear: [Double]) throws -> Result {
        guard (16...512).contains(width), (16...512).contains(height), vertices.count <= 12288,
              vertices.count % 3 == 0, clear.count == 4 else {
            throw NoctMetalError.unavailable("GPU request exceeds the surface or geometry limit.")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .renderTarget; descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor), let command = queue.makeCommandBuffer() else {
            throw NoctMetalError.unavailable("Could not allocate a bounded GPU surface.")
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture; pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(clear[0],clear[1],clear[2],clear[3])
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw NoctMetalError.unavailable("Could not encode the GPU render pass.")
        }
        encoder.setRenderPipelineState(trianglePipeline)
        if !vertices.isEmpty {
            guard let buffer = vertices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else {
                encoder.endEncoding(); throw NoctMetalError.unavailable("Could not allocate GPU geometry.")
            }
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        }
        encoder.endEncoding()
        let complete = DispatchSemaphore(value: 0)
        command.addCompletedHandler { _ in complete.signal() }
        command.commit()
        guard complete.wait(timeout: .now() + 3) == .success, command.status == .completed else {
            throw NoctMetalError.unavailable("GPU work failed or exceeded its deadline.")
        }
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0) }
        let hash = SHA256.hash(data: data).map { String(format:"%02x",$0) }.joined()
        return Result(pixels: data, gpuMilliseconds: max(0,command.gpuEndTime-command.gpuStartTime)*1000, sha256: hash)
    }
}

/// Event-driven GPU presentation; there is no idle 60 Hz render loop.
final class NoctMetalSurface: MTKView, MTKViewDelegate {
    private let renderer: NoctMetal
    private var texture: MTLTexture?
    private var sourceSize = CGSize.zero
    private var pendingImage: CGImage?
    private let inFlight = DispatchSemaphore(value: 2)
    init(renderer: NoctMetal) {
        self.renderer = renderer
        super.init(frame: .zero, device: renderer.device)
        colorPixelFormat = .bgra8Unorm_srgb; framebufferOnly = true
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        clearColor = MTLClearColorMake(18/255,11/255,15/255,1)
        isPaused = true; enableSetNeedsDisplay = true; autoResizeDrawable = true
        delegate = self
    }
    required init(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func update(_ image: CGImage?) {
        pendingImage = image
        if image == nil {
            texture = nil; sourceSize = .zero; needsDisplay = true; return
        }
        needsDisplay = true
    }
    private func upload(_ image: CGImage) {
        guard let bytes = image.dataProvider?.data else { return }
        let w = image.width, h = image.height
        // Each submitted texture is immutable. A later CPU upload must not
        // overwrite pixels while an earlier GPU command is sampling them.
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead; d.storageMode = .shared
        texture = renderer.device.makeTexture(descriptor: d)
        if let pointer = CFDataGetBytePtr(bytes) {
            texture?.replace(region: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0, withBytes: pointer, bytesPerRow: image.bytesPerRow)
        }
        sourceSize = CGSize(width: w, height: h); needsDisplay = true
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { needsDisplay = true }
    func draw(in view: MTKView) {
        guard inFlight.wait(timeout: .now()) == .success else { needsDisplay = true; return }
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let command = renderer.queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { inFlight.signal(); return }
        if let image = pendingImage { upload(image); pendingImage = nil }
        if let texture, sourceSize.width > 0 {
            let scale = min(drawableSize.width/sourceSize.width,drawableSize.height/sourceSize.height)
            let w = sourceSize.width*scale, h = sourceSize.height*scale
            encoder.setViewport(MTLViewport(originX: (drawableSize.width-w)/2, originY: (drawableSize.height-h)/2, width: w, height: h, znear: 0, zfar: 1))
            encoder.setRenderPipelineState(renderer.displayPipeline)
            encoder.setFragmentTexture(texture,index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        let semaphore = inFlight
        command.addCompletedHandler { _ in semaphore.signal() }
        encoder.endEncoding(); command.present(drawable); command.commit()
    }
}
