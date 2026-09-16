#if os(macOS)
import Darwin
import Foundation
import LuminaIPC

public final class SkyLightClient {
    public private(set) var available = false
    private var slsMainConnectionID: (@convention(c) () -> Int32)?
    private var slsManagedDisplayGetCurrentSpace: (@convention(c) (Int32, CFString) -> UInt64)?
    private var logged = false

    public init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        guard let handle else {
            logOnce("SkyLight dlopen failed; public space path only")
            return
        }
        if let sym = dlsym(handle, "SLSMainConnectionID") {
            slsMainConnectionID = unsafeBitCast(sym, to: (@convention(c) () -> Int32).self)
        }
        if let sym = dlsym(handle, "SLSManagedDisplayGetCurrentSpace") {
            slsManagedDisplayGetCurrentSpace = unsafeBitCast(sym, to: (@convention(c) (Int32, CFString) -> UInt64).self)
        }
        available = slsMainConnectionID != nil && slsManagedDisplayGetCurrentSpace != nil
        if !available {
            logOnce("SkyLight symbols missing; public space path only")
        }
    }

    public func currentSpaceId(displayUUID: String) -> UInt64? {
        guard let connFn = slsMainConnectionID, let get = slsManagedDisplayGetCurrentSpace else { return nil }
        return get(connFn(), displayUUID as CFString)
    }

    private func logOnce(_ message: String) {
        guard !logged else { return }
        logged = true
        LuminaLog(category: .agent).info(message)
    }
}
#endif
