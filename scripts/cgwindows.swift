import CoreGraphics
import Foundation

// Independent OS-truth window dump for the harness. Not part of Lumina:
// reads CGWindowListCopyWindowInfo directly so assertions do not trust the
// agent's model or its AX reads.
//
// usage: cgwindows [pid ...]
// Prints a JSON array of layer-0 windows with real border coordinates.

let pids = Set(CommandLine.arguments.dropFirst().compactMap { Int32($0) })
let info = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
var rows: [[String: Any]] = []
for row in info {
    guard let pid = (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
    if !pids.isEmpty, !pids.contains(pid) { continue }
    let layer = (row[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
    guard layer == 0 else { continue }
    guard let id = (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
    guard let bounds = row[kCGWindowBounds as String] as? [String: Any] else { continue }
    let x = (bounds["X"] as? NSNumber)?.doubleValue ?? 0
    let y = (bounds["Y"] as? NSNumber)?.doubleValue ?? 0
    let w = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
    let h = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
    guard w >= 8, h >= 8 else { continue }
    let onscreen = (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
    rows.append([
        "cgWindowId": id,
        "pid": pid,
        "x": x,
        "y": y,
        "w": w,
        "h": h,
        "onscreen": onscreen,
    ])
}
let data = try! JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
