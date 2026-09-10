import Foundation

enum APIKeyMasking {
    /// Masked API key for UI display: sk-••••abcd
    static func masked(_ key: String) -> String {
        guard key.count > 8 else { return key.isEmpty ? "（未设置）" : "••••" }
        return "\(key.prefix(2))••••\(key.suffix(4))"
    }
}
