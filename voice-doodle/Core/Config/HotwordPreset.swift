import Foundation

/// Parses bundled hotwords_preset.txt — first-launch seed for config.json.
enum HotwordPreset {
    static func bundledURL() -> URL? {
        Bundle.main.url(forResource: "hotwords_preset", withExtension: "txt")
    }

    static func load(from url: URL? = bundledURL()) -> [String] {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        var words: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let word = line.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty, !word.hasPrefix("#") else { continue }
            guard seen.insert(word).inserted else { continue }
            words.append(word)
        }
        return words
    }
}
