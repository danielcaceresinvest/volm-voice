import MetalKit
import SwiftUI
import VOLMVoiceCore

/// What the orb shows. Written on main by the app, read on main by the renderer each frame.
final class OrbModel {
    var mode: VoiceState = .offline
    var inputLevel: Double = 0
    var outputLevel: Double = 0
    var ring: Double = 0
    var viscosity: Float = 0.45
    var turbulence: Float = 0.55
    var reaction: Double = 1
    var cut = false
}

private struct OrbUniforms {
    var a: SIMD4<Float>      // res.x, res.y, time, level
    var b: SIMD4<Float>      // fill, amp, swirl, tilt
    var c: SIMD4<Float>      // viscosity, turbulence, ring, posterize
    var fluid: SIMD4<Float>
    var deep: SIMD4<Float>
    var ink: SIMD4<Float>
}

private struct ModeLook {
    var fill: Float, amp: Float, fillGain: Float, ampGain: Float, swirl: Float, tilt: Float
    var fluid: SIMD3<Float>, deep: SIMD3<Float>, time: Float
}

/// The liquid orb from the prototype, ported from GLSL to Metal and compiled at runtime
/// (the Command Line Tools ship no offline Metal compiler).
final class OrbRenderer: NSObject, MTKViewDelegate {
    private static let red = SIMD3<Float>(0.886, 0.137, 0.102), redDeep = SIMD3<Float>(0.36, 0.05, 0.035)
    private static let paper = SIMD3<Float>(0.898, 0.882, 0.843), paperDeep = SIMD3<Float>(0.43, 0.41, 0.37)
    private static let grey = SIMD3<Float>(0.42, 0.40, 0.37), greyDeep = SIMD3<Float>(0.17, 0.165, 0.15)

    private static func look(_ mode: VoiceState) -> ModeLook {
        switch mode {
        case .idle: return ModeLook(fill: 0.44, amp: 0.03, fillGain: 0.15, ampGain: 0.05, swirl: 0, tilt: 0, fluid: red, deep: redDeep, time: 0.6)
        case .listening: return ModeLook(fill: 0.30, amp: 0.04, fillGain: 0.45, ampGain: 0.24, swirl: 0, tilt: 0, fluid: paper, deep: paperDeep, time: 1)
        case .thinking: return ModeLook(fill: 0.46, amp: 0.05, fillGain: 0, ampGain: 0, swirl: 1, tilt: 0.28, fluid: paper, deep: paperDeep, time: 1)
        case .speaking: return ModeLook(fill: 0.30, amp: 0.04, fillGain: 0.50, ampGain: 0.28, swirl: 0, tilt: 0, fluid: red, deep: redDeep, time: 1)
        case .followUp: return ModeLook(fill: 0.28, amp: 0.04, fillGain: 0.35, ampGain: 0.18, swirl: 0, tilt: 0, fluid: red, deep: redDeep, time: 0.8)
        case .offline: return ModeLook(fill: 0.20, amp: 0, fillGain: 0, ampGain: 0, swirl: 0, tilt: 0, fluid: grey, deep: greyDeep, time: 0.05)
        }
    }

    let model: OrbModel
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var level: Double = 0
    private var loggedFirstFrame = false
    private var loggedNoDrawable = false
    private var clock: Double = 0
    private var last = CACurrentMediaTime()
    private var cur = ModeLook(fill: 0.2, amp: 0, fillGain: 0, ampGain: 0, swirl: 0, tilt: 0, fluid: grey, deep: greyDeep, time: 0.05)

    init?(device: MTLDevice, model: OrbModel) {
        self.model = model
        guard let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "orb_vertex")
            desc.fragmentFunction = library.makeFunction(name: "orb_fragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            Log.write("orb shader failed: \(error)")
            return nil
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = min(0.1, now - last)
        last = now
        let m = model
        let fps = m.cut ? 12 : 60
        if view.preferredFramesPerSecond != fps { view.preferredFramesPerSecond = fps }

        var target: Double
        switch m.mode {
        case .listening, .followUp: target = m.inputLevel
        case .speaking: target = m.outputLevel
        case .thinking: target = 0.08
        case .idle: target = 0.02
        case .offline: target = 0
        }
        target = min(1, target * m.reaction)
        level += (target - level) * (target > level ? 0.35 : 0.08)

        let goal = Self.look(m.mode)
        let k: Float = m.cut ? 1 : 0.06
        let lv = Float(level)
        cur.fill += (goal.fill + goal.fillGain * lv - cur.fill) * min(1, k * 1.6)
        cur.amp += (goal.amp + goal.ampGain * lv - cur.amp) * (m.cut ? 1 : 0.2)
        cur.swirl += (goal.swirl - cur.swirl) * k
        cur.tilt += (goal.tilt - cur.tilt) * k
        cur.time += (goal.time - cur.time) * k
        cur.fluid += (goal.fluid - cur.fluid) * k
        cur.deep += (goal.deep - cur.deep) * k
        clock += dt * Double(cur.time) * (1 + level * 0.8)

        let size = view.drawableSize
        guard size.width >= 1, size.height >= 1 else { return }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
            if !loggedNoDrawable { loggedNoDrawable = true; Log.write("orb: no drawable at \(size)") }
            return
        }
        if !loggedFirstFrame { loggedFirstFrame = true; Log.write("orb: first frame \(size)") }
        var u = OrbUniforms(
            a: SIMD4(Float(size.width), Float(size.height), Float(clock.truncatingRemainder(dividingBy: 10_000)), lv),
            b: SIMD4(cur.fill, cur.amp, cur.swirl, cur.tilt),
            c: SIMD4(m.viscosity, m.turbulence, Float(m.mode == .followUp ? m.ring : 0), m.cut ? 1 : 0),
            fluid: SIMD4(cur.fluid, 1), deep: SIMD4(cur.deep, 1), ink: SIMD4(0.082, 0.078, 0.071, 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<OrbUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 position [[position]]; };

    vertex VOut orb_vertex(uint vid [[vertex_id]]) {
        const float2 corners[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };
        VOut out;
        out.position = float4(corners[vid], 0.0, 1.0);
        return out;
    }

    struct Uniforms { float4 a; float4 b; float4 c; float4 fluid; float4 deep; float4 ink; };

    static float hash21(float2 p) { p = fract(p * float2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
    static float noise2(float2 p) {
        float2 i = floor(p); float2 f = fract(p);
        float a = hash21(i), b = hash21(i + float2(1.0, 0.0)), c = hash21(i + float2(0.0, 1.0)), d = hash21(i + float2(1.0, 1.0));
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
    }
    static float fbm(float2 p) {
        float v = 0.0, amp = 0.5;
        float2x2 m = float2x2(float2(1.6, 1.2), float2(-1.2, 1.6));
        for (int i = 0; i < 5; i++) { v += amp * noise2(p); p = m * p; amp *= 0.5; }
        return v;
    }
    static float2x2 rot(float a) { float c = cos(a), s = sin(a); return float2x2(float2(c, -s), float2(s, c)); }

    fragment float4 orb_fragment(VOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        float2 res = u.a.xy; float t = u.a.z; float level = u.a.w;
        float fill = u.b.x, amp = u.b.y, swirl = u.b.z, tilt = u.b.w;
        float visc = u.c.x, turb = u.c.y, ring = u.c.z, post = u.c.w;
        float3 fluid = u.fluid.rgb, deep = u.deep.rgb, ink = u.ink.rgb;

        float m = min(res.x, res.y);
        float2 uv = float2(in.position.x - 0.5 * res.x, 0.5 * res.y - in.position.y) / (0.5 * m);
        float px = 2.0 / m;
        float R = 0.94;
        float r = length(uv);
        float mask = 1.0 - smoothstep(R - px, R + px, r);
        if (mask <= 0.0) { return float4(0.0); }

        float2 p = rot(swirl * ((1.25 - r) * 2.4 + t * 0.7)) * uv;
        float x = p.x;
        float wave = 0.55 * sin(x * 3.1 + t * 2.0) + 0.30 * sin(x * 6.7 - t * 3.1) + 0.8 * (fbm(float2(x * 1.8 + t * 0.35, t * 0.5)) - 0.5);
        float surf = mix(-0.8, 0.6, fill) + amp * wave + tilt * sin(t * 1.3) * x;
        float d = surf - p.y;
        float inside = smoothstep(-px * 1.5, px * 1.5, d);

        float sp = mix(0.45, 0.06, visc);
        float k = 2.0 + 4.0 * turb;
        float2 q = p * 1.7;
        float2 w1 = float2(fbm(q + float2(0.0, t * sp)), fbm(q + float2(5.2, 1.3) - float2(t * sp * 0.8, 0.0)));
        float2 w2 = float2(fbm(q + k * w1 + float2(1.7, 9.2) + t * sp * 1.3), fbm(q + k * w1 + float2(8.3, 2.8) - t * sp));
        float f = fbm(q + k * (0.7 + level * 0.9) * w2);
        float3 liquid = mix(deep, fluid, smoothstep(0.28, 0.82, f));
        float men = 1.0 - smoothstep(0.0, 0.035 + amp * 0.25, d);
        liquid = mix(liquid, min(fluid * 1.12 + 0.07, float3(1.0)), men * 0.6);
        liquid *= 0.78 + 0.26 * smoothstep(-1.0, surf, p.y);

        float3 air = mix(ink, fluid, 0.06 * fbm(q * 0.8 + t * 0.05));
        float spray = step(0.985 - level * 0.05, noise2(p * 22.0 + float2(0.0, -t * 1.5))) * smoothstep(0.25, 0.0, -d) * level;
        air = mix(air, fluid, spray * 0.7);

        float3 col = mix(air, liquid, inside);
        col *= 1.0 - 0.3 * pow(r / R, 4.0);
        float rim = smoothstep(R - px * 3.0, R - px, r);
        col = mix(col, float3(0.9, 0.88, 0.84), rim * 0.22);
        if (ring > 0.0) {
            float a01 = fract(atan2(uv.x, uv.y) / 6.28318);
            float band = smoothstep(R - px * 7.0, R - px * 5.0, r) * (1.0 - smoothstep(R - px * 2.0, R - px * 0.5, r));
            if (a01 < ring) { col = mix(col, float3(0.886, 0.137, 0.102), band); }
        }
        if (post > 0.5) { col = floor(col * 5.0 + 0.5) / 5.0; }
        return float4(col * mask, mask);
    }
    """
}

struct OrbView: NSViewRepresentable {
    let model: OrbModel

    final class Coordinator {
        var renderer: OrbRenderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let device = MTLCreateSystemDefaultDevice()
        let view = MTKView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        if let device, let renderer = OrbRenderer(device: device, model: model) {
            context.coordinator.renderer = renderer
            view.delegate = renderer
            Log.write("orb: view ready on \(device.name)")
        } else {
            Log.write("orb: no Metal device or renderer")
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {}
}
