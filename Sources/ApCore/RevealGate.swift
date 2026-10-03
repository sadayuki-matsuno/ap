/// Decides when holding Control may reveal a concealed clip in the picker. Only a Control press made while the panel
/// is open, with no other modifier, arms it; carrying Control over from the Control-Command-P hotkey, adding another
/// modifier, or typing a key during the hold (Control-A in the search field) cancels it until Control is pressed again
public struct RevealGate: Sendable {
    private var controlDown: Bool
    public private(set) var isArmed = false

    /// `controlDown`: whether Control is already held when the panel opens
    public init(controlDown: Bool) {
        self.controlDown = controlDown
    }

    /// Returns true when Control was just pressed alone (the caller reveals after a short delay if still armed)
    public mutating func modifiersChanged(control: Bool, others: Bool) -> Bool {
        let pressedNow = control && !controlDown
        controlDown = control
        guard control, !others else {
            isArmed = false
            return false
        }
        if pressedNow { isArmed = true }
        return pressedNow
    }

    public mutating func keyPressed() {
        isArmed = false
    }
}
