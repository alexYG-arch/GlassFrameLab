// Read-only diagnostic for the explicitly measured local test region.
import AppKit
let region = CGRect(x: 64, y: 157, width: 472, height: 122)
let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
let overlaps: [[String: Any]] = info.compactMap { item in
    guard let bounds = item[kCGWindowBounds as String] as? [String: Any],
          let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.intersects(region) else { return nil }
    return ["owner": item[kCGWindowOwnerName as String] ?? "", "pid": item[kCGWindowOwnerPID as String] ?? 0,
            "window": item[kCGWindowNumber as String] ?? 0, "layer": item[kCGWindowLayer as String] ?? 0,
            "bounds": bounds]
}
let result: [String: Any] = ["frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown", "overlaps_front_to_back": overlaps]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]))
