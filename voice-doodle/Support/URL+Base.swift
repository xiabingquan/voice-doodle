import Foundation

extension URL {
    /// Base-URL parser shared by config normalization and client URL
    /// building: strips trailing slashes then parses.
    init?(vdBase string: String) {
        var s = string
        while s.hasSuffix("/") { s.removeLast() }
        self.init(string: s)
    }
}
