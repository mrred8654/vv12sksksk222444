// SPDX-License-Identifier: AGPL-3.0-or-later
// AquaVR phase 3: single-eye Metal presentation of decoded frames — replaces the
// visionOS LayerRenderer pipeline of alvr-visionos Renderer.swift (AGPL-3.0).
// Minimal first-light renderer: bgra8 drawable, 2-plane 8-bit 4:2:0 source,
// YUV->RGB by matrix, full-quad texturing, no timewarp/FFR (later phases).

import CoreVideo
import Foundation
import Metal
import MetalKit
import SwiftUI
import simd

private let kShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VOut {
    float4 pos [[position]];
    float2 uv;
};

static constexpr sampler sAddress(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

vertex VOut aqua_vertex(uint vid [[vertex_id]]) {
    float2 pos[4] = { {-1.0, -1.0}, {+1.0, -1.0}, {-1.0, +1.0}, {+1.0, +1.0} };
    float2 uv[4]  = { { 0.0,  1.0}, { 1.0,  1.0}, { 0.0,  0.0}, { 1.0,  0.0} };

    VOut out;
    out.pos = float4(pos[vid], 0.0, 1.0);
    out.uv = uv[vid];
    return out;
}

fragment float4 aqua_fragment(VOut in [[stage_in]],
                              texture2d<float> yTex [[texture(0)]],
                              texture2d<float> uvTex [[texture(1)]],
                              constant float4x4 &yuv [[buffer(0)]]) {
    float y = yTex.sample(sAddress, in.uv).r;
    float2 uv = uvTex.sample(sAddress, in.uv).rg;

    // Column-major (Y row, Cb row, Cr row, offsets) matrix passed from Swift.
    float4 yuvVec = { y, uv.x, uv.y, 1.0 };
    float4 rgb = yuv * yuvVec;
    return float4(rgb.r, rgb.g, rgb.b, 1.0);
}
"""

final class FrameRenderer: NSObject, MTKViewDelegate {
    static let shared = FrameRenderer()

    let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    private var commandQueue: MTLCommandQueue? = nil
    private var library: MTLLibrary? = nil
    private var pipeline: MTLRenderPipelineState? = nil
    private var pipelinePixelFormat: MTLPixelFormat? = nil
    private var textureCache: CVMetalTextureCache? = nil

    override init() {
        super.init()
        guard let device else {
            print("FrameRenderer: no Metal device")
            return
        }
        commandQueue = device.makeCommandQueue()
        library = try? device.makeLibrary(source: kShaderSource, options: nil)
        if library == nil {
            print("FrameRenderer: shader compile failed")
        }
        do {
            textureCache = try CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, nil)
        } catch {
            print("FrameRenderer: texture cache error \(error)")
        }
    }

    private func ensurePipeline(for view: MTKView) {
        guard let device, let library else { return }
        let targetFormat = view.colorPixelFormat
        if let pipeline, pipelinePixelFormat == targetFormat {
            return
        }

        guard let vertexFunction = library.makeFunction(name: "aqua_vertex"),
              let fragmentFunction = library.makeFunction(name: "aqua_fragment") else {
            print("FrameRenderer: shader functions missing")
            return
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = targetFormat
        descriptor.colorAttachments[0].isBlendingEnabled = false

        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            pipelinePixelFormat = targetFormat
        } catch {
            print("FrameRenderer: pipeline error \(error)")
        }
    }

    // Build metal textures for the 2 planes of a decoded 8-bit 4:2:0 pixel buffer.
    private func textures(for pixelBuffer: CVPixelBuffer) -> (MTLTexture, MTLTexture)? {
        guard let textureCache else { return nil }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else { return nil }

        var lumaHolder: CVMetalTexture? = nil
        var status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .r8Unorm,
            CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
            CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
            0,
            &lumaHolder)
        guard status == kCVReturnSuccess, let lumaTex = CVMetalTextureGetTexture(lumaHolder!) else {
            print("FrameRenderer: luma texture error \(status)")
            return nil
        }

        var chromaHolder: CVMetalTexture? = nil
        status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .rg8Unorm,
            CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
            CVPixelBufferGetHeightOfPlane(pixelBuffer, 1),
            1,
            &chromaHolder)
        guard status == kCVReturnSuccess, let chromaTex = CVMetalTextureGetTexture(chromaHolder!) else {
            print("FrameRenderer: chroma texture error \(status)")
            return nil
        }

        return (lumaTex, chromaTex)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // We render at the view's drawable size; nothing to adapt yet.
    }

    func draw(in view: MTKView) {
        ensurePipeline(for: view)
        guard let commandQueue, let pipeline else { return }

        let session = AlvrSession.shared

        // Per-frame head tracking precedes the render (donor order).
        HeadTracker.shared.sendTracking(targetTimestamp: CACurrentMediaTime())

        guard let frame = session.pollFrameForRender() else {
            view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            return
        }

        _ = session.reportCompositorStart(forFrame: frame)

        guard let pixelBuffer = frame.imageBuffer as? CVPixelBuffer else { return }
        guard let (yTex, uvTex) = textures(for: pixelBuffer) else { return }
        guard let videoFormat = session.videoFormat else { return }
        var yuvMatrix = VideoHandler.getYUVTransformForVideoFormat(videoFormat)

        guard let drawable = view.currentDrawable else { return }
        guard let descriptor = view.currentRenderPassDescriptor else { return }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.addCompletedHandler { _ in
            if session.alvrInitialized && session.lastSubmittedTimestamp != frame.timestamp {
                session.reportSubmit(timestamp: frame.timestamp, vsyncQueueNs: 0)
            }
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(yTex, index: 0)
        encoder.setFragmentTexture(uvTex, index: 1)
        encoder.setFragmentBytes(&yuvMatrix, length: MemoryLayout<simd_float4x4>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
