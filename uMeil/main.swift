import AppKit

// The app is AppKit-first and has no storyboard or nib, so the entry point
// wires up the application and its delegate by hand. `delegate` is a global
// because NSApplication only holds its delegate weakly.
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
