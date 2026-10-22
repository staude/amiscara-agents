// Prints the window number of a process's frontmost on-screen window,
// for `screencapture -l` (#199).  window-id <pid> [title substring]
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 2, let pid = Int32(args[1]) else {
    FileHandle.standardError.write("usage: window-id <pid> [title]\n".data(using: .utf8)!)
    exit(2)
}
let title = args.count > 2 ? args[2] : nil
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let matching = windows.filter { window in
    (window[kCGWindowOwnerPID as String] as? Int32) == pid
        && (window[kCGWindowLayer as String] as? Int) == 0
        && (title.map { ((window[kCGWindowName as String] as? String) ?? "").contains($0) } ?? true)
}
// The list runs front to back.
guard let front = matching.first, let number = front[kCGWindowNumber as String] as? Int else { exit(1) }
print(number)
