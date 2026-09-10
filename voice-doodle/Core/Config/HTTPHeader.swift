import Foundation

nonisolated struct HTTPHeader: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var value: String
}
