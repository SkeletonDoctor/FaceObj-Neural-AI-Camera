import CoreVideo
import MetalKit
import SwiftUI

/// Draws each camera frame with Metal as it arrives, aspect-fit, straight from the
/// camera's pixel buffer (no copy: the buffer is wrapped as a texture).
struct MetalVideoView: NSViewRepresentable {
    let frames: FrameBox

    func makeCoordinator() -> Renderer { Renderer(frames: frames) }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = true
        // Draw when a camera frame arrives instead of on a timer: no wasted
        // redraws of the same frame, and each frame goes out as soon as it lands.
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.delegate = context.coordinator
        bind(view, context.coordinator)
        return view
    }

    /// SwiftUI may reuse this view for a different camera: follow the new one.
    func updateNSView(_ view: MTKView, context: Context) {
        guard context.coordinator.frames !== frames else { return }
        context.coordinator.frames.onNewFrame(nil)
        bind(view, context.coordinator)
        view.draw()
    }

    private func bind(_ view: MTKView, _ renderer: Renderer) {
        renderer.frames = frames
        frames.onNewFrame { [weak view] in
            DispatchQueue.main.async { view?.draw() }
        }
    }

    final class Renderer: NSObject, MTKViewDelegate {
        let device: MTLDevice?
        var frames: FrameBox
        private var queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        private var textureCache: CVMetalTextureCache?

        private static let shader = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 uv;
        };

        // One triangle that covers the viewport.
        vertex VertexOut video_vertex(uint vid [[vertex_id]]) {
            float2 p = float2((vid << 1) & 2, vid & 2);
            VertexOut out;
            out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
            out.uv = float2(p.x, 1.0 - p.y);
            return out;
        }

        fragment float4 video_fragment(VertexOut in [[stage_in]], texture2d<float> frame [[texture(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            return float4(frame.sample(s, in.uv).rgb, 1.0);
        }
        """

        init(frames: FrameBox) {
            self.frames = frames
            device = MTLCreateSystemDefaultDevice()
            super.init()
            guard let device else { return }
            queue = device.makeCommandQueue()
            CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
            do {
                let library = try device.makeLibrary(source: Self.shader, options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "video_vertex")
                descriptor.fragmentFunction = library.makeFunction(name: "video_fragment")
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                NSLog("FaceRec: Metal setup failed: \(error)")
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            DispatchQueue.main.async { view.draw() }
        }

        func draw(in view: MTKView) {
            guard let queue, let pipeline, let textureCache,
                  let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let commands = queue.makeCommandBuffer(),
                  let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

            if let frame = frames.get() {
                let w = CVPixelBufferGetWidth(frame), h = CVPixelBufferGetHeight(frame)
                var wrapped: CVMetalTexture?
                CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, frame, nil, .bgra8Unorm, w, h, 0, &wrapped)
                if let wrapped, let texture = CVMetalTextureGetTexture(wrapped) {
                    let fit = aspectFit(CGSize(width: w, height: h), in: view.drawableSize)
                    encoder.setViewport(MTLViewport(originX: fit.minX, originY: fit.minY,
                                                    width: fit.width, height: fit.height, znear: 0, zfar: 1))
                    encoder.setRenderPipelineState(pipeline)
                    encoder.setFragmentTexture(texture, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    // Keep the frame alive until the GPU has finished with it.
                    commands.addCompletedHandler { _ in _ = wrapped }
                }
            }
            encoder.endEncoding()
            commands.present(drawable)
            commands.commit()
        }
    }
}

/// The largest rectangle with `content`'s aspect ratio centred inside `bounds`.
func aspectFit(_ content: CGSize, in bounds: CGSize) -> CGRect {
    guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
    let scale = min(bounds.width / content.width, bounds.height / content.height)
    let size = CGSize(width: content.width * scale, height: content.height * scale)
    return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                  width: size.width, height: size.height)
}
