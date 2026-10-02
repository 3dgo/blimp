package dx

import "core:sys/windows"
import "vendor:directx/d3d12"

Command_Queue_Options :: struct {
    type: d3d12.COMMAND_LIST_TYPE,
}

Command_Queue :: struct {
    handle: ^d3d12.ICommandQueue,

    using options: Command_Queue_Options,
}

command_queue_create :: proc(render_context: Render_Context, options: Command_Queue_Options) -> Command_Queue {
    queue: Command_Queue
    queue.options = options

    hr := render_context.device->CreateCommandQueue(&d3d12.COMMAND_QUEUE_DESC {
        Type = options.type,
        Priority = 0,
        Flags = {},
    }, d3d12.ICommandQueue_UUID, (^rawptr)(&queue.handle)); check_dx(hr, "Failed to create graphics command queue")
    return queue
}

command_queue_destroy :: proc(queue: Command_Queue) {
    queue.handle->Release()
}

command_queue_signal :: proc(queue: Command_Queue, fence: Fence, value: u64) {
    hr := queue.handle->Signal(fence.handle, value); check_dx(hr, "Failed to signal fence")
}

command_queue_wait :: proc(queue: Command_Queue, fence: Fence, value: u64) {
    hr := queue.handle->Wait(fence.handle, value); check_dx(hr, "Failed to queue wait on fence")
}

Command_Allocator_Options :: struct {
    type: d3d12.COMMAND_LIST_TYPE,
}

Command_Allocator :: struct {
    handle: ^d3d12.ICommandAllocator,

    using options: Command_Allocator_Options,
}

command_allocator_create :: proc(render_context: Render_Context, options: Command_Allocator_Options) -> Command_Allocator {
    cmd_allocator: Command_Allocator
    cmd_allocator.options = options

    hr := render_context.device->CreateCommandAllocator(options.type, d3d12.ICommandAllocator_UUID, (^rawptr)(&cmd_allocator.handle)); check_dx(hr, "Failed to create command allocator")
    return cmd_allocator
}

command_allocator_destroy :: proc(cmd_allocator: Command_Allocator) {
    cmd_allocator.handle->Release()
}

command_allocator_reset :: proc(cmd_allocator: ^Command_Allocator) {
    hr := cmd_allocator.handle->Reset(); check_dx(hr, "Failed to reset command")
}

Command_List_Options :: struct {
    type: d3d12.COMMAND_LIST_TYPE,
}

Command_List :: struct {
    handle: ^d3d12.IGraphicsCommandList7,

    using options: Command_List_Options,
}

command_list_create :: proc(render_context: Render_Context, cmd_allocator: Command_Allocator, options: Command_List_Options) -> Command_List {
    cmd_list: Command_List
    cmd_list.options = options
    hr := render_context.device->CreateCommandList(0, options.type, cmd_allocator.handle, nil, d3d12.IGraphicsCommandList7_UUID, (^rawptr)(&cmd_list.handle)); check_dx(hr, "Failed to create command list")
    return cmd_list
}

command_list_destroy :: proc(cmd_list: Command_List) {
    cmd_list.handle->Release()
}

command_list_execute :: proc(cmd_queue: Command_Queue, cmd_lists: []Command_List) {
    if len(cmd_lists) <= 0 do return

    lists := make([]^d3d12.ICommandList, len(cmd_lists), context.temp_allocator)
    for cmd_list, i in cmd_lists {
        lists[i] = (^d3d12.ICommandList)(cmd_list.handle)
    }
    cmd_queue.handle->ExecuteCommandLists(u32(len(lists)), raw_data(lists))
}

command_list_close :: proc(cmd_list: Command_List) {
    cmd_list.handle->Close()
}

command_list_reset :: proc(cmd_list: Command_List, cmd_alloc: Command_Allocator) {
    cmd_list.handle->Reset(cmd_alloc.handle, nil)
}

Command_Signature :: struct {
    handle: ^d3d12.ICommandSignature,
}

command_signature_create :: proc(render_context: Render_Context) -> Command_Signature {
    sig: Command_Signature

    desc := d3d12.COMMAND_SIGNATURE_DESC {
        ByteStride = size_of(d3d12.DRAW_INDEXED_ARGUMENTS),
        NumArgumentDescs = 1,
        pArgumentDescs = &{Type = .DRAW_INDEXED},
    }
    hr := render_context.device->CreateCommandSignature(&desc, nil, d3d12.ICommandSignature_UUID, (^rawptr)(&sig.handle))
    check_dx(hr, "Failed to create command signature")
    return sig
}

command_signature_destroy :: proc(sig: Command_Signature) {
    sig.handle->Release()
}

Fence :: struct {
    handle: ^d3d12.IFence
}

fence_create :: proc(render_context: Render_Context, init_val: u64) -> Fence {
    fence: Fence
    hr := render_context.device->CreateFence(init_val, {}, d3d12.IFence_UUID, (^rawptr)(&fence.handle))
    check_dx(hr, "Failed to create fence")
    return fence
}

fence_destroy :: proc(fence: Fence) {
    fence.handle->Release()
}

fence_wait :: proc(fence: Fence, value: u64) {
    if fence.handle->GetCompletedValue() < value {
        event := windows.CreateEventW(nil, false, false, nil)
        fence.handle->SetEventOnCompletion(value, event)
        windows.WaitForSingleObject(event, windows.INFINITE)
        windows.CloseHandle(event)
    }
}