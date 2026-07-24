import Foundation

final class MainlandChineseConverter {
    static let shared = MainlandChineseConverter()

    private struct Stage {
        let mappings: [String: String]
        let maximumKeyLength: Int

        func convert(_ source: String) -> String {
            guard !mappings.isEmpty else { return source }
            let characters = Array(source)
            var output = ""
            output.reserveCapacity(source.count)
            var index = 0

            while index < characters.count {
                let available = min(maximumKeyLength, characters.count - index)
                var match: (text: String, length: Int)?
                if available > 0 {
                    for length in stride(from: available, through: 1, by: -1) {
                        let key = String(characters[index..<(index + length)])
                        if let replacement = mappings[key] {
                            match = (replacement, length)
                            break
                        }
                    }
                }

                if let match {
                    output.append(match.text)
                    index += match.length
                } else {
                    output.append(characters[index])
                    index += 1
                }
            }
            return output
        }
    }

    private let taiwanToTraditional: Stage
    private let traditionalToSimplified: Stage
    let isReady: Bool

    private init() {
        guard let directory = Self.dictionaryDirectory() else {
            taiwanToTraditional = Stage(mappings: [:], maximumKeyLength: 0)
            traditionalToSimplified = Stage(mappings: [:], maximumKeyLength: 0)
            isReady = false
            return
        }

        var secondStage: [String: String] = [:]
        Self.loadDirect("TSPhrases", from: directory, into: &secondStage)
        Self.loadDirect("TSCharacters", from: directory, into: &secondStage)

        var firstStage: [String: String] = [:]
        Self.loadDirect("TWPhrasesRev", from: directory, into: &firstStage)
        Self.loadDirect("TWVariantsRevPhrases", from: directory, into: &firstStage)
        Self.loadReversed(
            "TWVariants",
            from: directory,
            allowedSources: Set(secondStage.keys),
            into: &firstStage
        )

        taiwanToTraditional = Self.stage(firstStage)
        traditionalToSimplified = Self.stage(secondStage)
        isReady = !firstStage.isEmpty && !secondStage.isEmpty
    }

    func convert(_ source: String) -> String {
        traditionalToSimplified.convert(taiwanToTraditional.convert(source))
    }

    private static func dictionaryDirectory() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("OpenCC", isDirectory: true),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/OpenCC", isDirectory: true)
        ].compactMap { $0 }
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("TSCharacters.txt").path)
        }
    }

    private static func stage(_ mappings: [String: String]) -> Stage {
        Stage(
            mappings: mappings,
            maximumKeyLength: mappings.keys.map(\.count).max() ?? 0
        )
    }

    private static func loadDirect(
        _ name: String,
        from directory: URL,
        into mappings: inout [String: String]
    ) {
        for (source, targets) in entries(name, from: directory) {
            guard let target = targets.first else { continue }
            if mappings[source] == nil { mappings[source] = target }
        }
    }

    private static func loadReversed(
        _ name: String,
        from directory: URL,
        allowedSources: Set<String>? = nil,
        into mappings: inout [String: String]
    ) {
        for (source, targets) in entries(name, from: directory) {
            guard allowedSources?.contains(source) ?? true else { continue }
            for target in targets where mappings[target] == nil {
                mappings[target] = source
            }
        }
    }

    private static func entries(_ name: String, from directory: URL) -> [(String, [String])] {
        let url = directory.appendingPathComponent(name).appendingPathExtension("txt")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return content.split(whereSeparator: { $0.isNewline }).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard fields.count == 2 else { return nil }
            return (fields[0], fields[1].split(separator: " ").map(String.init))
        }
    }
}
