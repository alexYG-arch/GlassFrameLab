// Read-only native state for one known test window. Does not activate the application.
import AppKit

guard CommandLine.arguments.count == 2, let windowID = UInt32(CommandLine.arguments[1]) else {
    fputs("usage: window_state WINDOW_ID\n", stderr)
    exit(2)
}
let all = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
let visible = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
func matches(_ info: [String: Any]) -> Bool { (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }
let own = all.first(where: matches)
let result: [String: Any] = [
    "window_id": windowID,
    "exists": own != nil,
    "on_screen_in_current_space": visible.contains(where: matches),
    "layer": own?[kCGWindowLayer as String] ?? NSNull(),
    "bounds": own?[kCGWindowBounds as String] ?? NSNull(),
    "frontmost_application": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
]
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
