import CoreServices
import Foundation

private let appleMusicCacheEventCallback: FSEventStreamCallback = {
    _, context, eventCount, rawPaths, _, _ in
    guard let context else { return }
    let pathPointers = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
    let urls = (0..<eventCount).compactMap { index -> URL? in
        guard let path = pathPointers[index] else { return nil }
        return URL(fileURLWithPath: String(cString: path))
    }
    Unmanaged<AppleMusicCacheWatch>.fromOpaque(context)
        .takeUnretainedValue()
        .cacheChanged(urls)
}

final class AppleMusicCacheLyricsProvider {
    private let cacheRoot: URL
    private let fileManager: FileManager
    private let watchQueue = DispatchQueue(
        label: "personal.chris.LyricFeverScroll.apple-cache",
        qos: .utility
    )

    init(
        cacheRoot: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.cacheRoot = cacheRoot ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.apple.Music", isDirectory: true)
    }

    func lines(for track: MusicSnapshot) -> [LyricLine]? {
        guard track.hasTrack else { return nil }

        let recent = recentCandidateURLs()
        let recentSet = Set(recent)
        let indexed = indexedCandidateURLs().filter { !recentSet.contains($0) }
        return lines(for: track, candidateURLs: recent + indexed)
    }

    fileprivate func indexedLines(for track: MusicSnapshot) -> [LyricLine]? {
        lines(for: track, candidateURLs: indexedCandidateURLs())
    }

    fileprivate func lines(
        for track: MusicSnapshot,
        candidateURLs: [URL]
    ) -> [LyricLine]? {
        guard track.hasTrack else { return nil }

        var matches: [(score: Int, order: Int, ttml: String)] = []
        for (order, url) in candidateURLs.enumerated() {
            guard
                let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                let response = try? JSONDecoder().decode(AppleCatalogResponse.self, from: data)
            else { continue }

            for song in response.data {
                guard
                    let score = Self.matchScore(song.attributes, track: track),
                    let rawTTML = song.relationships?.syllableLyrics?.data.first?
                        .attributes.ttmlLocalizations,
                    let ttml = Self.localizedTTML(from: rawTTML)
                else { continue }
                if score >= 160 {
                    let parsed = AppleTTMLParser.parse(ttml)
                    if parsed.contains(where: { !$0.text.isEmpty }) { return parsed }
                }
                matches.append((score, order, ttml))
            }
        }

        for match in matches.sorted(by: {
            $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score
        }) {
            let parsed = AppleTTMLParser.parse(match.ttml)
            if parsed.contains(where: { !$0.text.isEmpty }) { return parsed }
        }
        return nil
    }

    func watch(
        for track: MusicSnapshot,
        timeout: TimeInterval,
        completion: @escaping ([LyricLine]?) -> Void
    ) -> AppleMusicCacheWatch {
        let task = AppleMusicCacheWatch(queue: watchQueue, completion: completion)
        let dataDirectory = cacheRoot.appendingPathComponent("fsCachedData", isDirectory: true)
        let deadline = DispatchWorkItem { [weak task] in task?.finish(with: nil) }
        task.timeoutWork = deadline
        watchQueue.async { [task, self] in
            task.start(
                dataDirectory: dataDirectory,
                provider: self,
                track: track
            )
        }
        watchQueue.asyncAfter(deadline: .now() + max(0, timeout), execute: deadline)
        return task
    }

    private func recentCandidateURLs() -> [URL] {
        let dataDirectory = cacheRoot.appendingPathComponent("fsCachedData", isDirectory: true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let files = (try? fileManager.contentsOfDirectory(
            at: dataDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.compactMap { url -> (URL, Date)? in
            guard
                let values = try? url.resourceValues(forKeys: keys),
                values.isRegularFile == true
            else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.1 > $1.1 }.prefix(240).map(\.0)
    }

    private func indexedCandidateURLs() -> [URL] {
        let dataDirectory = cacheRoot.appendingPathComponent("fsCachedData", isDirectory: true)
        return indexedFileNames().map { dataDirectory.appendingPathComponent($0) }
    }

    private func indexedFileNames() -> [String] {
        let database = cacheRoot.appendingPathComponent("Cache.db")
        guard fileManager.isReadableFile(atPath: database.path) else { return [] }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly",
            "-cmd",
            ".timeout 200",
            database.path,
            "SELECT CAST(d.receiver_data AS TEXT) "
                + "FROM cfurl_cache_response r "
                + "JOIN cfurl_cache_receiver_data d USING(entry_ID) "
                + "WHERE d.isDataOnFS=1 AND r.request_key LIKE '%syllable-lyrics%' "
                + "ORDER BY r.time_stamp DESC LIMIT 240;"
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        guard let source = String(data: data, encoding: .utf8) else { return [] }
        return source.split(whereSeparator: \.isNewline).compactMap { line in
            let name = String(line)
            return UUID(uuidString: name) == nil ? nil : name
        }
    }

    private static func matchScore(
        _ song: AppleCatalogSong.Attributes,
        track: MusicSnapshot
    ) -> Int? {
        let songTitle = normalized(song.name)
        let trackTitle = normalized(track.name)
        let baseSongTitle = normalized(baseTitle(song.name))
        let baseTrackTitle = normalized(baseTitle(track.name))

        var score: Int
        if songTitle == trackTitle {
            score = 80
        } else if !baseSongTitle.isEmpty, baseSongTitle == baseTrackTitle {
            score = 55
        } else {
            return nil
        }

        let songArtist = normalized(song.artistName)
        let trackArtist = normalized(track.artist)
        if songArtist == trackArtist {
            score += 45
        } else if !songArtist.isEmpty,
                  !trackArtist.isEmpty,
                  (songArtist.contains(trackArtist) || trackArtist.contains(songArtist)) {
            score += 20
        } else {
            return nil
        }

        if track.duration > 0 {
            guard let milliseconds = song.durationInMillis, milliseconds > 0 else { return nil }
            let difference = abs(Double(milliseconds) / 1_000 - track.duration)
            guard difference <= 3 else { return nil }
            score += difference <= 1 ? 35 : 25
        }

        if !track.album.isEmpty, normalized(song.albumName ?? "") == normalized(track.album) {
            score += 10
        }
        return score >= 100 ? score : nil
    }

    static func localizedTTML(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") { return trimmed }
        guard
            let data = trimmed.data(using: .utf8),
            let localizations = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }

        if let mainlandSimplified = localizations["zh-Hans-CN"] {
            return mainlandSimplified
        }
        if let simplified = localizations.keys.sorted().first(where: { $0.hasPrefix("zh-Hans") }) {
            return localizations[simplified]
        }
        for language in Locale.preferredLanguages {
            if let exact = localizations[language] { return exact }
            let base = language.split(separator: "-").first.map(String.init) ?? language
            if let match = localizations.keys.sorted().first(where: { $0.hasPrefix(base) }) {
                return localizations[match]
            }
        }
        return localizations.sorted { $0.key < $1.key }.first?.value
    }

    private static func normalized(_ source: String) -> String {
        let folded = SimplifiedChinese.normalize(source).folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        return String(folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    private static func baseTitle(_ source: String) -> String {
        source.replacingOccurrences(
            of: #"\s*[\(\[\uff08\u3010].*?[\)\]\uff09\u3011]\s*$"#,
            with: "",
            options: .regularExpression
        )
    }
}

final class AppleMusicCacheWatch {
    fileprivate let queue: DispatchQueue
    fileprivate var timeoutWork: DispatchWorkItem?
    fileprivate var retryWork: DispatchWorkItem?

    private var completion: (([LyricLine]?) -> Void)?
    private var eventStream: FSEventStreamRef?
    private var provider: AppleMusicCacheLyricsProvider?
    private var track: MusicSnapshot?
    private var keepAlive: AppleMusicCacheWatch?
    private var finished = false

    fileprivate init(
        queue: DispatchQueue,
        completion: @escaping ([LyricLine]?) -> Void
    ) {
        self.queue = queue
        self.completion = completion
    }

    func cancel() {
        queue.async { [weak self] in self?.finish(with: nil, notify: false) }
    }

    fileprivate func start(
        dataDirectory: URL,
        provider: AppleMusicCacheLyricsProvider,
        track: MusicSnapshot
    ) {
        guard !finished else { return }
        self.provider = provider
        self.track = track
        keepAlive = self

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            appleMusicCacheEventCallback,
            &context,
            [dataDirectory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.02,
            flags
        ) else {
            finish(with: nil)
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            finish(with: nil)
            return
        }
        eventStream = stream
        if let lines = provider.indexedLines(for: track) {
            finish(with: lines)
        }
    }

    fileprivate func cacheChanged(_ urls: [URL]) {
        guard !finished, let provider, let track else { return }
        let candidates = urls.filter { UUID(uuidString: $0.lastPathComponent) != nil }
        guard !candidates.isEmpty else { return }
        attempt(provider: provider, track: track, candidateURLs: candidates)
        scheduleRetry(provider: provider, track: track, candidateURLs: candidates)
    }

    fileprivate func attempt(
        provider: AppleMusicCacheLyricsProvider,
        track: MusicSnapshot,
        candidateURLs: [URL]
    ) {
        guard !finished else { return }
        if let lines = provider.lines(for: track, candidateURLs: candidateURLs) {
            finish(with: lines)
        }
    }

    fileprivate func scheduleRetry(
        provider: AppleMusicCacheLyricsProvider,
        track: MusicSnapshot,
        candidateURLs: [URL]
    ) {
        guard !finished else { return }
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self, provider] in
            guard let self else { return }
            self.attempt(
                provider: provider,
                track: track,
                candidateURLs: candidateURLs
            )
        }
        retryWork = work
        queue.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    fileprivate func finish(with lines: [LyricLine]?, notify: Bool = true) {
        guard !finished else { return }
        finished = true
        timeoutWork?.cancel()
        retryWork?.cancel()
        if let eventStream {
            FSEventStreamStop(eventStream)
            FSEventStreamInvalidate(eventStream)
            FSEventStreamRelease(eventStream)
            self.eventStream = nil
        }
        provider = nil
        track = nil
        let callback = completion
        completion = nil
        if notify { callback?(lines) }
        keepAlive = nil
    }
}

private struct AppleCatalogResponse: Decodable {
    let data: [AppleCatalogSong]
}

private struct AppleCatalogSong: Decodable {
    struct Attributes: Decodable {
        let name: String
        let artistName: String
        let albumName: String?
        let durationInMillis: Int?
    }

    struct Relationships: Decodable {
        let syllableLyrics: LyricRelationship?

        private enum CodingKeys: String, CodingKey {
            case syllableLyrics = "syllable-lyrics"
        }
    }

    struct LyricRelationship: Decodable {
        let data: [LyricResource]
    }

    struct LyricResource: Decodable {
        struct Attributes: Decodable {
            let ttmlLocalizations: String?
        }

        let attributes: Attributes
    }

    let attributes: Attributes
    let relationships: Relationships?
}

enum AppleTTMLParser {
    static func parse(_ source: String) -> [LyricLine] {
        guard let data = source.data(using: .utf8) else { return [] }
        let delegate = AppleTTMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return [] }
        return delegate.lines()
    }
}

private final class AppleTTMLParserDelegate: NSObject, XMLParserDelegate {
    private struct RawLine {
        let time: TimeInterval
        let key: String?
        let text: String
    }

    private var rawLines: [RawLine] = []
    private var replacements: [String: String] = [:]
    private var inBody = false
    private var inSimplifiedReplacement = false
    private var lineTime: TimeInterval?
    private var lineKey: String?
    private var lineText = ""
    private var replacementKey: String?
    private var replacementText = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch localName(qName ?? elementName) {
        case "body":
            inBody = true
        case "p" where inBody:
            lineTime = Self.time(attribute("begin", in: attributeDict))
            lineKey = attribute("key", in: attributeDict)
            lineText = ""
        case "translation":
            let language = attribute("lang", in: attributeDict) ?? ""
            inSimplifiedReplacement = language.hasPrefix("zh-Hans")
                && attribute("type", in: attributeDict) == "replacement"
        case "text" where inSimplifiedReplacement:
            replacementKey = attribute("for", in: attributeDict)
            replacementText = ""
        case "br":
            append(" ")
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch localName(qName ?? elementName) {
        case "p" where inBody:
            if let lineTime {
                rawLines.append(RawLine(time: lineTime, key: lineKey, text: lineText))
            }
            lineTime = nil
            lineKey = nil
            lineText = ""
        case "body":
            inBody = false
        case "text" where inSimplifiedReplacement:
            if let replacementKey {
                replacements[replacementKey] = replacementText
            }
            replacementKey = nil
            replacementText = ""
        case "translation":
            inSimplifiedReplacement = false
        default:
            break
        }
    }

    func lines() -> [LyricLine] {
        rawLines.map { line in
            let text = line.key.flatMap { replacements[$0] } ?? line.text
            return LyricLine(time: line.time, text: SimplifiedChinese.normalize(Self.cleaned(text)))
        }.sorted { $0.time < $1.time }
    }

    private func append(_ string: String) {
        if replacementKey != nil {
            replacementText += string
        } else if lineTime != nil {
            lineText += string
        }
    }

    private func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    private func attribute(_ name: String, in attributes: [String: String]) -> String? {
        attributes[name] ?? attributes.first {
            $0.key.split(separator: ":").last.map(String.init) == name
        }?.value
    }

    private static func cleaned(_ source: String) -> String {
        source.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func time(_ source: String?) -> TimeInterval? {
        guard let source else { return nil }
        if source.hasSuffix("ms"), let milliseconds = Double(source.dropLast(2)) {
            return milliseconds / 1_000
        }
        if source.hasSuffix("s"), let seconds = Double(source.dropLast()) {
            return seconds
        }
        let components = source.split(separator: ":")
        guard !components.isEmpty, components.count <= 3 else { return nil }
        let values = components.compactMap { Double($0) }
        guard values.count == components.count else { return nil }
        return values.reversed().enumerated().reduce(0) {
            $0 + $1.element * pow(60, Double($1.offset))
        }
    }
}
