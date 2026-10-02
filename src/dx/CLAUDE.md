# dx — DirectX 12 Backend

## Backend

- **Direct3D 12** with **Shader Model 6.6** minimum. No fallback to D3D11 or older SM.

## Core Features in Use

| Feature | Purpose |
|---|---|
| **GPU Virtual Address** (`GetGPUVirtualAddress`) | Buffer VAs passed via root CBV or root constants; no descriptor table binding for buffers |
| **Shader-Visible Descriptor Heap** (`CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED`) | Single shader-visible heap; resources indexed by `ResourceDescriptorHeap[idx]` in Slang/HLSL (SM 6.6 bindless) |
| **Enhanced Barriers** (`ID3D12GraphicsCommandList7::Barrier`) | All barriers use `BUFFER_BARRIER` / `TEXTURE_BARRIER` structs; no legacy `ResourceBarrier` transitions |
| **OMSetRenderTargets** | Render targets set dynamically each frame; no render-pass objects (DX12 never had them) |
| **Root Signature 1.1** (`VERSIONED_ROOT_SIGNATURE_DESC`) | Descriptor volatility hints for driver optimisation; combined with `CBV_SRV_UAV_HEAP_DIRECTLY_INDEXED` and `SAMPLER_HEAP_DIRECTLY_INDEXED` flags |

## Rendering Architecture

Scene geometry is drawn using **2–3 `ExecuteIndirect` calls** maximum. A compute cull pass builds the indirect argument buffer each frame; the CPU never issues per-object or per-material draw calls.

- Instance data (transform, geometry index) is stored in a bindless buffer and indexed by `SV_InstanceID`
- Per-frame globals (view-proj, time, resolution, camera position) live in a single root CBV updated once per frame

## Forbidden Patterns

Do **not** introduce any of the following — they are replaced by the features above:

- Descriptor tables (`D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE`) — use heap direct indexing via `ResourceDescriptorHeap[]` instead
- Legacy `ResourceBarrier` with `D3D12_RESOURCE_BARRIER_TYPE_TRANSITION` — use Enhanced Barriers (`Barrier()` on `IGraphicsCommandList7`)
- Root descriptor ranges for SRVs/UAVs — resources are accessed through the bindless heap, not table ranges
- Command list interfaces older than `IGraphicsCommandList7` — required for Enhanced Barriers

## Shaders

- **Slang** targeting **DXIL** (SM 6.6+). No hand-written HLSL or DXBC.

## Memory

Resources are created with `CreateCommittedResource`. Raw `ID3D12Heap` / `CreatePlacedResource` may be introduced later via **D3D12 Memory Allocator (D3D12MA)** if fine-grained control is needed — do not call `CreateHeap` directly before that is in place.
