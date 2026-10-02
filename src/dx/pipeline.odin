package dx

import "vendor:directx/d3d12"
import "vendor:directx/dxgi"

Pipeline_State :: struct {
    handle: ^d3d12.IPipelineState,
}

Pipeline_State_Subobject :: struct($T: typeid) #align(8) {
    type: d3d12.PIPELINE_STATE_SUBOBJECT_TYPE,
    data: T,
}

Pipeline_State_Stream :: struct #align(8) {
    root_signature: Pipeline_State_Subobject(^d3d12.IRootSignature),
    vs: Pipeline_State_Subobject(d3d12.SHADER_BYTECODE),
    ps: Pipeline_State_Subobject(d3d12.SHADER_BYTECODE),
    primitive_topology: Pipeline_State_Subobject(d3d12.PRIMITIVE_TOPOLOGY_TYPE),
    rasterizer: Pipeline_State_Subobject(d3d12.RASTERIZER_DESC),
    depth_stencil: Pipeline_State_Subobject(d3d12.DEPTH_STENCIL_DESC),
    blend: Pipeline_State_Subobject(d3d12.BLEND_DESC),
    rtv_formats: Pipeline_State_Subobject(d3d12.RT_FORMAT_ARRAY),
    dsv_format: Pipeline_State_Subobject(dxgi.FORMAT),
}

// How the fragment output combines with the render target.
//   Opaque   — no blend, write all (default)
//   Alpha    — src.a over dst (sorted transparency; draw back-to-front, depth_write = false)
//   Additive — src.a * src + dst (glows/particles; order-independent, depth_write = false)
Blend_Mode :: enum { Opaque, Alpha, Additive }

// Configurable state for a graphics PSO. Odin structs have no per-field defaults, so start
// from PIPELINE_OPTIONS_DEFAULT and tweak the fields you need (same idiom as
// DEFAULT_PARAM_UI_OPTIONS).
Pipeline_Options :: struct {
    topology:    d3d12.PRIMITIVE_TOPOLOGY_TYPE,
    fill_mode:   d3d12.FILL_MODE,
    cull_mode:   d3d12.CULL_MODE,
    front_ccw:   bool,
    depth_test:  bool,          // DepthEnable
    depth_write: bool,          // DepthWriteMask: .ALL when true, .ZERO when false
    depth_func:  d3d12.COMPARISON_FUNC,
    depth_bias:  i32,           // DepthBias (shadow maps); negative pushes away from the eye under reversed-Z
    slope_bias:  f32,           // SlopeScaledDepthBias, same sign rule
    blend:       Blend_Mode,
    rtv_format:  dxgi.FORMAT,   // .UNKNOWN = no render target (depth only)
    dsv_format:  dxgi.FORMAT,
}

PIPELINE_OPTIONS_DEFAULT :: Pipeline_Options {
    topology    = .TRIANGLE,
    fill_mode   = .SOLID,
    cull_mode   = .BACK,        // CW front faces, back-face culled
    front_ccw   = false,
    depth_test  = true,
    depth_write = true,
    depth_func  = .GREATER_EQUAL,   // reversed-Z
    blend       = .Opaque,
    rtv_format  = .R8G8B8A8_UNORM,
    dsv_format  = .D32_FLOAT,
}

pipeline_create_graphics_pso :: proc(render_context: Render_Context, root_sig: Root_Signature, shaders: Compiled_Shader, options := PIPELINE_OPTIONS_DEFAULT) -> Pipeline_State {
    // Per-target blend for RT0; alpha-weighted so the source alpha modulates intensity.
    rt_blend := d3d12.RENDER_TARGET_BLEND_DESC { RenderTargetWriteMask = 0x0f }
    switch options.blend {
    case .Opaque:   // BlendEnable stays false
    case .Alpha:
        rt_blend.BlendEnable = true
        rt_blend.SrcBlend  = .SRC_ALPHA; rt_blend.DestBlend  = .INV_SRC_ALPHA; rt_blend.BlendOp      = .ADD
        rt_blend.SrcBlendAlpha = .ONE;   rt_blend.DestBlendAlpha = .INV_SRC_ALPHA; rt_blend.BlendOpAlpha = .ADD
    case .Additive:
        rt_blend.BlendEnable = true
        rt_blend.SrcBlend  = .SRC_ALPHA; rt_blend.DestBlend  = .ONE; rt_blend.BlendOp      = .ADD
        rt_blend.SrcBlendAlpha = .ONE;   rt_blend.DestBlendAlpha = .ONE; rt_blend.BlendOpAlpha = .ADD
    }

    stream := Pipeline_State_Stream {
        root_signature = {.ROOT_SIGNATURE, root_sig.handle},
        vs = {.VS, {pShaderBytecode = raw_data(shaders.vs_bytecode), BytecodeLength = len(shaders.vs_bytecode)}},
        ps = {.PS, {pShaderBytecode = raw_data(shaders.ps_bytecode), BytecodeLength = len(shaders.ps_bytecode)}},
        primitive_topology = {.PRIMITIVE_TOPOLOGY, options.topology},
        rasterizer = {.RASTERIZER, {
            FillMode = options.fill_mode,
            CullMode = options.cull_mode,
            FrontCounterClockwise = d3d12.BOOL(options.front_ccw),
            DepthBias = options.depth_bias,
            SlopeScaledDepthBias = options.slope_bias,
            DepthClipEnable = true,
        }},
        depth_stencil = {.DEPTH_STENCIL, {
            DepthEnable    = d3d12.BOOL(options.depth_test),
            DepthWriteMask = options.depth_write ? .ALL : .ZERO,
            DepthFunc      = options.depth_func,
        }},
        blend = {.BLEND, {
            RenderTarget = {0 = rt_blend},
        }},
        rtv_formats = {.RENDER_TARGET_FORMATS, {
            RTFormats = {0 = options.rtv_format},
            NumRenderTargets = options.rtv_format == .UNKNOWN ? 0 : 1,
        },},
        dsv_format = {.DEPTH_STENCIL_FORMAT, options.dsv_format},
    }

    stream_desc := d3d12.PIPELINE_STATE_STREAM_DESC {
        SizeInBytes = size_of(Pipeline_State_Stream),
        pPipelineStateSubobjectStream = &stream,
    }

    pso: Pipeline_State
    hr := render_context.device->CreatePipelineState(&stream_desc, d3d12.IPipelineState_UUID, (^rawptr)(&pso.handle))
    check_dx(hr, "Failed to create graphics PSO")

    return pso
}

pipeline_destroy_pso :: proc(pso: Pipeline_State) {
    pso.handle->Release()
}