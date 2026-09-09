// MetalRenderer.swift
//
// Owns the Metal device, pipeline and the canvas textures. The Swift layer
// hands it flattened RGBA buffers (produced by the Rust core via
// `Document.composite`) and it blits them once per frame, transformed by the
// viewport uniforms — pan/zoom happen on the GPU, so the pixel buffers only
// cross the boundary when the artwork itself changes.

import Metal
import MetalKit
import simd

/// Mirrors `ViewportUniforms` in CanvasShaders.metal.
struct ViewportUniforms {
    var viewSize: SIMD2<Float>
    var canvasSize: SIMD2<Float>
    var origin: SIMD2<Float>
    var scale: Float
    var gridAlpha: Float
    var onionAlpha: Float
    var onionAlpha2: Float
}

final class MetalRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    private var canvasTexture: MTLTexture?
    private var onionTexture: MTLTexture?
    private var onionTexture2: MTLTexture?
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
    }

    private func makeTexture(width: Int, height: Int) -> MTLTexture? {
        let texDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        texDescriptor.usage = [.shaderRead]
        return device.makeTexture(descriptor: texDescriptor)
    }

    private func upload(_ pixels: [UInt8], to texture: MTLTexture, width: Int, height: Int) {
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

    /// Upload a flattened RGBA buffer as the canvas texture.
    func updateCanvas(pixels: [UInt8], width: Int, height: Int) {
        guard width > 0, height > 0 else { return }

        if canvasWidth != width || canvasHeight != height || canvasTexture == nil {
            canvasTexture = makeTexture(width: width, height: height)
            canvasWidth = width
            canvasHeight = height
        }
        guard let texture = canvasTexture else { return }
        upload(pixels, to: texture, width: width, height: height)
    }

    /// Upload an onion-skin (previous frame) texture; nil disables the slot.
    /// Slot 0 = frame−1, slot 1 = frame−2.
    func updateOnion(pixels: [UInt8]?, width: Int, height: Int, slot: Int) {
        var texture = slot == 0 ? onionTexture : onionTexture2
        guard let pixels, width > 0, height > 0 else {
            if slot == 0 { onionTexture = nil } else { onionTexture2 = nil }
            return
        }
        if texture == nil || texture?.width != width || texture?.height != height {
            texture = makeTexture(width: width, height: height)
            if slot == 0 { onionTexture = texture } else { onionTexture2 = texture }
        }
        guard let texture else { return }
        upload(pixels, to: texture, width: width, height: height)
    }

    func draw(in view: MTKView, uniforms: ViewportUniforms) {
        guard
            let drawable = view.currentDrawable,
            let descriptor = view.currentRenderPassDescriptor,
            let commandBuffer = queue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor),
            let texture = canvasTexture
        else {
            return
        }

        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewportUniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentTexture(onionTexture ?? texture, index: 1)
        encoder.setFragmentTexture(onionTexture2 ?? texture, index: 2)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
