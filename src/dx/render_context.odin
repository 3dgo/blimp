package dx

import "core:log"
import "vendor:directx/d3d12"
import "vendor:directx/dxgi"

Render_Context :: struct {
    factory: ^dxgi.IFactory6,
    adapter: ^dxgi.IAdapter4,
    // Waiting for Odin DX update, Use newer Idevice so I can use CreateCommittedResource3 to work with ehanced barrier
    device: ^d3d12.IDevice9,
    debug: ^d3d12.IDebug3,
    info_queue: ^d3d12.IInfoQueue1,
}

render_context_create :: proc() -> Render_Context {
    render_context: Render_Context
    hr: d3d12.HRESULT
    when ODIN_DEBUG {
        hr = d3d12.GetDebugInterface(d3d12.IDebug3_UUID, (^rawptr)(&render_context.debug)); check_dx(hr, "Failed to get debug layer 3")
        render_context.debug->EnableDebugLayer()
        render_context.debug->SetEnableGPUBasedValidation(true)
    }

    flags: dxgi.CREATE_FACTORY
    when ODIN_DEBUG { flags += {.DEBUG} }
    hr = dxgi.CreateDXGIFactory2(flags, dxgi.IFactory6_UUID, (^rawptr)(&render_context.factory)); check_dx(hr, "Failed to create DXGI Factory")

    hr = render_context.factory->EnumAdapterByGpuPreference(0, .HIGH_PERFORMANCE, dxgi.IAdapter4_UUID, (^rawptr)(&render_context.adapter)); check_dx(hr, "Failed to enumerate adapter")
    hr = d3d12.CreateDevice(render_context.adapter, ._12_2, d3d12.IDevice9_UUID, (^rawptr)(&render_context.device)); check_dx(hr, "Failed to create D3D12 device")

    support_options: d3d12.FEATURE_DATA_OPTIONS
    render_context.device->CheckFeatureSupport(.OPTIONS, &support_options, size_of(support_options))
    if(support_options.ResourceBindingTier < ._3) {
        log.panic("GPU does not support Resource Binding Tier 3 — bindless unavailable")
    }

    when ODIN_DEBUG {
        hr = render_context.device->QueryInterface(d3d12.IInfoQueue1_UUID, (^rawptr)(&render_context.info_queue)); check_dx(hr, "Failed to query info queue interface")
        render_context.info_queue->SetBreakOnSeverity(.CORRUPTION, true)
        render_context.info_queue->SetBreakOnSeverity(.ERROR, true)
    }

    return render_context
}

render_context_destroy :: proc(render_context: Render_Context) {
    when ODIN_DEBUG {
        render_context.info_queue->Release()
    }
    render_context.device->Release()
    render_context.adapter->Release()
    render_context.factory->Release()
    when ODIN_DEBUG {
        render_context.debug->Release()
    }
}

render_context_register_debug_callback :: proc(render_context: Render_Context, callback: d3d12.PFN_MESSAGE_CALLBACK) {
    when ODIN_DEBUG {
        cookie: u32
        render_context.info_queue->RegisterMessageCallback(callback, {}, nil, &cookie)
    }
}