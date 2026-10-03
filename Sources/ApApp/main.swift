import AppKit
import ApCore

// Honors AP_DB_PATH / AP_CLAUDE_PROJECTS_DIR like the CLI (`open -n build/Ap.app --env AP_DB_PATH=...`)
let store: ClipStore
do {
    store = try ClipStore(path: ClipStore.defaultPath())
} catch {
    let alert = NSAlert()
    alert.messageText = String(localized: "Ap could not open its database")
    alert.informativeText = "\(ClipStore.defaultPath())\n\(error)"
    alert.runModal()
    exit(1)
}
let delegate = AppDelegate(store: store)
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()
