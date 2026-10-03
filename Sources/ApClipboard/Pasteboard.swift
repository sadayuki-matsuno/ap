import AppKit
import ApCore

/// Writes one NSPasteboardItem holding every type. Another process can clear the pasteboard between our
/// clearContents and writeObjects (parallel `| ap` calls do exactly that), which makes writeObjects fail,
/// so retry a few times with a short backoff. A nil uuid writes plain text that is not a clip
public func writePasteboard(content: String, uuid: String?, concealed: Bool) -> Bool {
    let pasteboard = NSPasteboard.general
    // AppKit NSLogs every failed attempt to stderr ("_setData:forType: returns false"); keep that out of the
    // caller's output while retrying. Our own error message is printed after stderr is restored
    let savedStandardError = dup(STDERR_FILENO)
    let devNull = open("/dev/null", O_WRONLY)
    if savedStandardError >= 0, devNull >= 0 { dup2(devNull, STDERR_FILENO) }
    defer {
        if savedStandardError >= 0 { dup2(savedStandardError, STDERR_FILENO); close(savedStandardError) }
        if devNull >= 0 { close(devNull) }
    }
    for attempt in 0..<8 {
        if attempt > 0 { usleep(useconds_t(5_000 << min(attempt - 1, 4))) }
        let item = NSPasteboardItem()
        guard item.setString(content, forType: .string) else { return false }
        if let uuid, !item.setString(uuid, forType: NSPasteboard.PasteboardType(PasteboardTypes.clipId)) {
            return false
        }
        if concealed {
            _ = item.setData(Data(), forType: NSPasteboard.PasteboardType(PasteboardTypes.concealed))
        }
        pasteboard.clearContents()
        if pasteboard.writeObjects([item]) { return true }
    }
    return false
}

/// The `dev.ap.clip-id` of what is on the general pasteboard now (nil when it was not written by ap)
public func pasteboardClipId() -> String? {
    NSPasteboard.general.string(forType: NSPasteboard.PasteboardType(PasteboardTypes.clipId))
}
