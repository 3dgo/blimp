package dx

import "base:runtime"
import "core:log"
import "vendor:directx/d3d12"

Root_Signature_Builder :: struct {
    allocator: runtime.Allocator,
    constants: d3d12.ROOT_CONSTANTS,
    cbvs: [dynamic]d3d12.ROOT_DESCRIPTOR1,
}

Root_Signature :: struct {
    handle : ^d3d12.IRootSignature,
}

root_signature_builder_create :: proc(allocator: runtime.Allocator) -> Root_Signature_Builder {
    builder: Root_Signature_Builder
    builder.allocator = allocator
    builder.cbvs = make([dynamic]d3d12.ROOT_DESCRIPTOR1, builder.allocator)
    return builder
}

root_signature_builder_destroy :: proc(builder: Root_Signature_Builder) {
    delete(builder.cbvs)
}

/*root_signature_builder_set_constants :: proc(builder: ^Root_Signature_Builder, shader_register: u32, register_space: u32, constants_count: u32) {
    builder.constants.ShaderRegister = shader_register
    builder.constants.RegisterSpace = register_space
    builder.constants.Num32BitValues = constants_count
}*/

root_signature_builder_add_cbv :: proc(builder: ^Root_Signature_Builder, shader_register: u32, register_space: u32, flags: d3d12.ROOT_DESCRIPTOR_FLAGS)  {
    cbv := d3d12.ROOT_DESCRIPTOR1 {
        ShaderRegister = shader_register,
        RegisterSpace = register_space,
        Flags = flags,
    }
    append(&builder.cbvs, cbv)
}

root_signature_build :: proc(render_context: Render_Context, builder: Root_Signature_Builder) -> Root_Signature {
    root_sig: Root_Signature

    root_params := make([dynamic]d3d12.ROOT_PARAMETER1, allocator=context.temp_allocator)
    if builder.constants.Num32BitValues > 0 {
        constants_param := d3d12.ROOT_PARAMETER1 {
            ParameterType = ._32BIT_CONSTANTS,
            Constants = builder.constants,
            ShaderVisibility = .ALL,
        }
        append(&root_params, constants_param)
    }

    for cbv in builder.cbvs {
        cbv_param := d3d12.ROOT_PARAMETER1 {
            ParameterType = .CBV,
            Descriptor = cbv,
            ShaderVisibility = .ALL,
        }
        append(&root_params, cbv_param)
    }

    desc := d3d12.VERSIONED_ROOT_SIGNATURE_DESC {
        Version = ._1_1,
        Desc_1_1 = {
            NumParameters = u32(len(root_params)),
            pParameters = raw_data(root_params),
            NumStaticSamplers = 0,
            Flags = {
                .DENY_HULL_SHADER_ROOT_ACCESS, .DENY_DOMAIN_SHADER_ROOT_ACCESS, .DENY_GEOMETRY_SHADER_ROOT_ACCESS,
                .CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED, .SAMPLER_HEAP_DIRECTLY_INDEXED,
            }
        },
    }

    blob: ^d3d12.IBlob
    error_blob: ^d3d12.IBlob
    hr := d3d12.SerializeVersionedRootSignature(&desc, &blob, &error_blob);

    if error_blob != nil {
        log.errorf("Root Signature Serialization Error: {}", cstring(error_blob->GetBufferPointer()))
    }
    check_dx(hr, "Failed to serialize root signature")

    hr = render_context.device->CreateRootSignature(0, blob->GetBufferPointer(), blob->GetBufferSize(),
        d3d12.IRootSignature_UUID, (^rawptr)(&root_sig.handle)); check_dx(hr, "Failed to create root signature")
    
    blob->Release()
    if error_blob != nil do error_blob->Release()

    return root_sig
}

root_signature_destroy :: proc(root_sig: Root_Signature) {
    root_sig.handle->Release()
}