// MetalRenderer.swift
//
// Owns the Metal device, pipeline and the canvas texture. The Swift layer
// hands it a flattened RGBA buffer (produced by the Rust core via
// `Document.composite`) and it blits it to screen once per frame. This keeps
// the per-pixel work in Rust and the pixel transfer to a single texture upload.

import Metal
import MetalKit

final class MetalRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    private var canvasTexture: MTLTexture?
    private var canvasWidth = 0
    private var canvasHeight = 0

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "canvas_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "canvas_fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .nearest
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            return nil
        }

        do {
            self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            return nil
        }
        self.queue = queue
        self.sampler = sampler
        super.init()
    }

    /// Upload a flattened RGBA buffer as the canvas texture.
    func updateCanvas(pixels: [UInt8], width: Int, height: Int) {
        guard width > 0, height > 0 else { return }

        if canvasWidth != width || canvasHeight != height || canvasTexture == nil {
            let texDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            texDescriptor.usage = [.shaderRead]
            canvasTexture = device.makeTexture(descriptor: texDescriptor)
            canvasWidth = width
            canvasHeight = height
        }

        guard let texture = canvasTexture else { return }
        pixels.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: width * 4
                )
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Nothing to pre-allocate; the fullscreen triangle adapts to any size.
    }

    func draw(in view: MTKView) {
        guard
            let drawable = view.currentDrawable,
            let descriptor = view.currentRenderPassDescriptor,
            let commandBuffer = queue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor),
            let texture = canvasTexture
        else {
            return
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
