/// Telling RimeLingo's own input source apart from the others, for
/// `ascii_state/reset_on_return` (#25).
public enum InputSourceReturn {
    /// RimeLingo's bundle and its input modes (`com.leelib.inputmethod.rimelingo.hans`).
    public static let bundleID = "com.leelib.inputmethod.rimelingo"

    public static func isRimeLingo(_ inputSourceID: String) -> Bool {
        inputSourceID == bundleID || inputSourceID.hasPrefix(bundleID + ".")
    }
}
