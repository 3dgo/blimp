package dx

import "core:log"
import "vendor:directx/dxgi"

check_dx :: proc(hr: dxgi.HRESULT, msg: string, location := #caller_location) {
    if hr < 0 do log.panicf("DirectX Failure: {:x}: {}", hr, msg, location = location)
}
