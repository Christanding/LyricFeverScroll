import AppKit
import Foundation

final class PlaybackDiagnostics {
    static let shared = PlaybackDiagnostics()

    private let capacity: Int
    private var entries: [String] = []

    init(capacity: Int = 100) {
        self.capacity = max(1, capacity)
    }

    func record(_ message: String) {
        entries.append(String(format: "%.3f %@", ProcessInfo.processInfo.systemUptime, message))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    var report: String {
        entries.joined(separator: "\n")
    }
}

struct LyricLine: Codable, Equatable {
    let time: TimeInterval
    let text: String
}

enum SimplifiedChinese {
    private static let regionalVariants: [Character: Character] = [
        "妳": "你",
        "擡": "抬",
        "揹": "背"
    ]
    private static let phraseCorrections: [(source: String, target: String)] = [
        ("嗳眛", "暧昧"),
        ("暧眛", "暧昧"),
        ("决择", "抉择"),
        ("预设", "默认")
    ]

    static func normalize(_ source: String) -> String {
        let converter = MainlandChineseConverter.shared
        let dictionaryConverted = converter.isReady ? converter.convert(source) : source
        let simplified = dictionaryConverted.applyingTransform(
            StringTransform("Traditional-Simplified"),
            reverse: false
        ) ?? dictionaryConverted
        let regional = String(simplified.map { regionalVariants[$0] ?? $0 })
        return phraseCorrections.reduce(regional) { text, correction in
            text.replacingOccurrences(of: correction.source, with: correction.target)
        }
    }
}

enum LRCParser {
    private static let timestamp = try! NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?\]"#
    )

    static func parse(_ source: String, simplifyChinese: Bool = true) -> [LyricLine] {
        var lines: [LyricLine] = []
        var offset: TimeInterval = 0

        for rawLine in source.components(separatedBy: .newlines) {
            if rawLine.lowercased().hasPrefix("[offset:") {
                let value = rawLine.dropFirst(8).prefix { $0 != "]" }
                offset = (Double(value) ?? 0) / 1_000
                continue
            }

            let range = NSRange(rawLine.startIndex..., in: rawLine)
            let matches = timestamp.matches(in: rawLine, range: range)
            guard !matches.isEmpty else { continue }

            let lyric = timestamp.stringByReplacingMatches(
                in: rawLine,
                range: range,
                withTemplate: ""
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let displayText = simplifyChinese ? SimplifiedChinese.normalize(lyric) : lyric

            for match in matches {
                guard
                    let minuteRange = Range(match.range(at: 1), in: rawLine),
                    let secondRange = Range(match.range(at: 2), in: rawLine)
                else { continue }

                let minutes = Double(rawLine[minuteRange]) ?? 0
                let seconds = Double(rawLine[secondRange]) ?? 0
                var fraction = 0.0
                if let fractionRange = Range(match.range(at: 3), in: rawLine) {
                    let digits = rawLine[fractionRange]
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }

                lines.append(LyricLine(
                    time: max(0, minutes * 60 + seconds + fraction + offset),
                    text: displayText
                ))
            }
        }

        return lines.sorted {
            $0.time == $1.time ? $0.text < $1.text : $0.time < $1.time
        }
    }

    static func currentIndex(in lines: [LyricLine], at position: TimeInterval) -> Int? {
        guard !lines.isEmpty, position >= lines[0].time else { return nil }
        var lower = 0
        var upper = lines.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if lines[middle].time <= position {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower - 1
    }
}

struct MusicSnapshot: Equatable {
    let state: String
    let name: String
    let artist: String
    let album: String
    let position: TimeInterval
    let duration: TimeInterval

    var isPlaying: Bool { state == "playing" }
    var hasTrack: Bool { !name.isEmpty }
    var trackKey: String {
        [name, artist, album].joined(separator: "\u{1F}")
    }
}

enum AppleMusicError: LocalizedError {
    case script(String)
    case malformedReply

    var errorDescription: String? {
        switch self {
        case .script(let message): return message
        case .malformedReply: return "Apple Music 返回的数据无法识别"
        }
    }
}

final class AppleMusicClient {
    private let scriptSource = #"""
    set delimiterChar to ASCII character 31
    if application "Music" is not running then
        return "not running"
    end if
    tell application "Music"
        set stateText to player state as text
        if stateText is "stopped" then
            set AppleScript's text item delimiters to delimiterChar
            return {stateText, "", "", "", "0", "0"} as text
        end if
        set currentSong to current track
        set trackName to name of currentSong as text
        set trackArtist to artist of currentSong as text
        set trackAlbum to album of currentSong as text
        set trackDuration to duration of currentSong as text
        set trackPosition to player position as text
        set AppleScript's text item delimiters to delimiterChar
        return {stateText, trackName, trackArtist, trackAlbum, trackDuration, trackPosition} as text
    end tell
    """#

    func snapshot() throws -> MusicSnapshot {
        guard let script = NSAppleScript(source: scriptSource) else {
            throw AppleMusicError.malformedReply
        }
        var details: NSDictionary?
        let result = script.executeAndReturnError(&details)
        if let details {
            let message = details[NSAppleScript.errorMessage] as? String ?? "无法读取 Apple Music"
            throw AppleMusicError.script(message)
        }

        let reply = result.stringValue ?? ""
        if reply == "not running" || reply.isEmpty {
            return MusicSnapshot(
                state: "not running", name: "", artist: "", album: "",
                position: 0, duration: 0
            )
        }

        let fields = reply.components(separatedBy: "\u{1F}")
        guard fields.count >= 6 else { throw AppleMusicError.malformedReply }
        return MusicSnapshot(
            state: fields[0].lowercased(),
            name: fields[1],
            artist: fields[2],
            album: fields[3],
            position: Self.number(fields[5]),
            duration: Self.number(fields[4])
        )
    }

    private static func number(_ value: String) -> Double {
        Double(value.replacingOccurrences(of: ",", with: ".")) ?? 0
    }
}

struct LRCLIBRecord: Decodable {
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let syncedLyrics: String?
}

struct LyricsDocument: Codable, Equatable {
    let source: String
    let referenceDuration: TimeInterval?
    let embeddedLines: [LyricLine]?
    let provider: String?

    init(
        source: String,
        referenceDuration: TimeInterval?,
        embeddedLines: [LyricLine]? = nil,
        provider: String? = "LRCLIB"
    ) {
        self.source = source
        self.referenceDuration = referenceDuration
        self.embeddedLines = embeddedLines
        self.provider = provider
    }

    var parsedLines: [LyricLine] {
        embeddedLines ?? LRCParser.parse(source)
    }
}

enum LyricTimeline {
    static func adjusted(
        _ lines: [LyricLine],
        referenceDuration: TimeInterval?,
        playbackDuration: TimeInterval
    ) -> [LyricLine] {
        guard let referenceDuration,
              referenceDuration > 0,
              playbackDuration > 0,
              abs(referenceDuration - playbackDuration) / referenceDuration <= 0.05 else {
            return lines
        }
        let scale = playbackDuration / referenceDuration
        guard abs(scale - 1) >= 0.002 else { return lines }
        return lines.map { LyricLine(time: $0.time * scale, text: $0.text) }
    }
}

final class LyricsLoadTask {
    fileprivate var tasks: [URLSessionDataTask] = []
    fileprivate var delayedResult: DispatchWorkItem?
    fileprivate var appleCacheWatch: AppleMusicCacheWatch?
    fileprivate var completed = false
    fileprivate var failureCount = 0

    func cancel() {
        completed = true
        delayedResult?.cancel()
        appleCacheWatch?.cancel()
        tasks.forEach { $0.cancel() }
    }
}

final class LyricsProvider {
    typealias Completion = (Result<LyricsDocument, Error>) -> Void

    private static let cacheVersion = "v5"
    private static let maximumCacheFiles = 500
    private static let userAgentVersion = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "1.1.0"
    private let session: URLSession
    private let appleCacheProvider: AppleMusicCacheLyricsProvider
    private let cacheDirectory: URL
    private let cacheQueue = DispatchQueue(
        label: "personal.chris.LyricFeverScroll.cache",
        qos: .utility
    )

    init(
        session: URLSession = .shared,
        appleCacheProvider: AppleMusicCacheLyricsProvider = AppleMusicCacheLyricsProvider()
    ) {
        self.session = session
        self.appleCacheProvider = appleCacheProvider
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = base.appendingPathComponent(
            "personal.chris.LyricFeverScroll/Lyrics",
            isDirectory: true
        )
    }

    @discardableResult
    func load(
        for track: MusicSnapshot,
        ignoringCache: Bool = false,
        completion: @escaping Completion
    ) -> LyricsLoadTask {
        let cacheURL = cacheDirectory.appendingPathComponent(Self.cacheFileName(for: track))
        let loadTask = LyricsLoadTask()
        var appleFinished = false
        var networkError: Error?

        func finish(_ result: Result<LyricsDocument, Error>) {
            guard !loadTask.completed else { return }
            loadTask.completed = true
            loadTask.delayedResult?.cancel()
            loadTask.appleCacheWatch?.cancel()
            loadTask.tasks.forEach { $0.cancel() }
            completion(result)
        }

        func finishNetworkFailure(_ error: Error) {
            guard !loadTask.completed else { return }
            networkError = error
            if appleFinished { finish(.failure(error)) }
        }

        loadTask.appleCacheWatch = appleCacheProvider.watch(
            for: track,
            timeout: 5
        ) { lines in
            DispatchQueue.main.async {
                guard !loadTask.completed else { return }
                guard let lines, !lines.isEmpty else {
                    appleFinished = true
                    if let networkError { finish(.failure(networkError)) }
                    return
                }
                let document = LyricsDocument(
                    source: "",
                    referenceDuration: track.duration,
                    embeddedLines: lines,
                    provider: "Apple Music"
                )
                self.save(document, to: cacheURL)
                finish(.success(document))
            }
        }

        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(LyricsDocument.self, from: data),
           Self.shouldUseCache(cached, for: track, ignoringCache: ignoringCache) {
            let delayed = DispatchWorkItem { finish(.success(cached)) }
            loadTask.delayedResult = delayed
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: delayed)
            return loadTask
        }

        let searchURLs = Self.searchTitles(for: track.name).compactMap(Self.searchURL(for:))
        guard let exactURL = Self.exactURL(for: track),
              let searchURL = searchURLs.first else {
            DispatchQueue.main.async { finishNetworkFailure(LyricsError.invalidRequest) }
            return loadTask
        }
        let fallbackSearchURL = searchURLs.dropFirst().first

        func fail(_ error: Error) {
            guard !loadTask.completed else { return }
            loadTask.failureCount += 1
            if loadTask.failureCount >= loadTask.tasks.count {
                finishNetworkFailure(error)
            }
        }

        func acceptSearch(_ records: [LRCLIBRecord], provider: LyricsProvider?) -> Bool {
            guard let best = Self.bestMatch(in: records, for: track),
                  let lyrics = best.syncedLyrics, !lyrics.isEmpty else { return false }
            let document = LyricsDocument(source: lyrics, referenceDuration: best.duration)
            let delayed = DispatchWorkItem {
                guard !loadTask.completed else { return }
                provider?.save(document, to: cacheURL)
                finish(.success(document))
            }
            loadTask.delayedResult = delayed
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: delayed)
            return true
        }

        var fallbackStarted = false
        func startFallback(using provider: LyricsProvider?, after error: Error) {
            guard !fallbackStarted, let provider, let fallbackSearchURL else {
                fail(error)
                return
            }
            fallbackStarted = true
            let fallbackTask = provider.request(fallbackSearchURL) { [weak provider] (result: Result<[LRCLIBRecord], Error>) in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let records):
                        if !acceptSearch(records, provider: provider) { fail(LyricsError.notFound) }
                    case .failure(let error):
                        fail(error)
                    }
                }
            }
            loadTask.tasks.append(fallbackTask)
            fail(error)
            fallbackTask.resume()
        }

        let exactTask = request(exactURL) { [weak self] (result: Result<LRCLIBRecord, Error>) in
            DispatchQueue.main.async {
                switch result {
                case .success(let record):
                    guard let lyrics = record.syncedLyrics, !lyrics.isEmpty else {
                        fail(LyricsError.notFound)
                        return
                    }
                    let document = LyricsDocument(source: lyrics, referenceDuration: record.duration)
                    self?.save(document, to: cacheURL)
                    finish(.success(document))
                case .failure(let error):
                    fail(error)
                }
            }
        }

        let searchTask = request(searchURL) { [weak self] (result: Result<[LRCLIBRecord], Error>) in
            DispatchQueue.main.async {
                switch result {
                case .success(let records):
                    if !acceptSearch(records, provider: self) {
                        startFallback(using: self, after: LyricsError.notFound)
                    }
                case .failure(let error):
                    startFallback(using: self, after: error)
                }
            }
        }

        loadTask.tasks = [exactTask, searchTask]
        exactTask.resume()
        searchTask.resume()
        return loadTask
    }

    static func shouldUseCache(
        _ document: LyricsDocument,
        for track: MusicSnapshot,
        ignoringCache: Bool
    ) -> Bool {
        let hasLyrics = !document.source.isEmpty || document.embeddedLines?.isEmpty == false
        guard !ignoringCache, hasLyrics else { return false }
        guard let referenceDuration = document.referenceDuration,
              referenceDuration > 0,
              track.duration > 0 else {
            return true
        }
        return abs(referenceDuration - track.duration) / referenceDuration <= 0.05
    }

    static func cacheFileName(for track: MusicSnapshot) -> String {
        hash(cacheVersion + "|" + track.trackKey) + ".json"
    }

    @discardableResult
    private func request<T: Decodable>(
        _ url: URL,
        completion: @escaping (Result<T, Error>) -> Void
    ) -> URLSessionDataTask {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(
            "LyricFeverScroll/\(Self.userAgentVersion) (local macOS menu bar client)",
            forHTTPHeaderField: "User-Agent"
        )
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data else {
                completion(.failure(LyricsError.notFound))
                return
            }
            do {
                completion(.success(try JSONDecoder().decode(T.self, from: data)))
            } catch {
                completion(.failure(error))
            }
        }
        return task
    }

    private func save(_ document: LyricsDocument, to url: URL) {
        let directory = cacheDirectory
        cacheQueue.async {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                try JSONEncoder().encode(document).write(to: url, options: .atomic)
                Self.pruneCache(at: directory, keeping: Self.maximumCacheFiles)
            } catch {
                // A cache failure should never prevent lyric display.
            }
        }
    }

    static func pruneCache(at directory: URL, keeping maximumCount: Int) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: .skipsHiddenFiles
        ) else { return }

        let cacheFiles: [(url: URL, modified: Date)] = urls.compactMap { url in
            guard url.pathExtension == "json",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return (url, values.contentModificationDate ?? .distantPast)
        }.sorted {
            $0.modified == $1.modified
                ? $0.url.lastPathComponent < $1.url.lastPathComponent
                : $0.modified < $1.modified
        }

        let excess = max(0, cacheFiles.count - max(0, maximumCount))
        for file in cacheFiles.prefix(excess) {
            try? FileManager.default.removeItem(at: file.url)
        }
    }

    private static func exactURL(for track: MusicSnapshot) -> URL? {
        var components = URLComponents(string: "https://lrclib.net/api/get")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: track.name),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "album_name", value: track.album),
            URLQueryItem(name: "duration", value: String(Int(track.duration.rounded())))
        ]
        return components?.url
    }

    static func searchTitles(for title: String) -> [String] {
        let original = lookupTitle(title)
        let simplified = SimplifiedChinese.normalize(original)
        let traditional = simplified.applyingTransform(
            StringTransform("Traditional-Simplified"),
            reverse: true
        ) ?? simplified
        return [original, simplified, traditional].reduce(into: []) { titles, candidate in
            if !candidate.isEmpty, !titles.contains(candidate) { titles.append(candidate) }
        }
    }

    private static func searchURL(for title: String) -> URL? {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [URLQueryItem(name: "track_name", value: title)]
        return components?.url
    }

    static func bestMatch(in records: [LRCLIBRecord], for track: MusicSnapshot) -> LRCLIBRecord? {
        let targetTrack = normalized(lookupTitle(track.name))
        let targetArtist = normalized(track.artist)
        return records
            .filter {
                !($0.syncedLyrics ?? "").isEmpty
                    && isPlausibleMatch($0, targetTrack, targetArtist, track.duration)
            }
            .max { score($0, targetTrack, targetArtist, track.duration) < score($1, targetTrack, targetArtist, track.duration) }
    }

    private static func isPlausibleMatch(
        _ record: LRCLIBRecord,
        _ targetTrack: String,
        _ targetArtist: String,
        _ targetDuration: TimeInterval
    ) -> Bool {
        let recordTrack = normalized(record.trackName ?? "")
        let recordArtist = normalized(record.artistName ?? "")
        guard !targetTrack.isEmpty,
              recordTrack == targetTrack || recordTrack.contains(targetTrack) || targetTrack.contains(recordTrack),
              targetArtist.isEmpty
                || recordArtist == targetArtist
                || recordArtist.contains(targetArtist)
                || targetArtist.contains(recordArtist) else {
            return false
        }
        guard targetDuration > 0, let duration = record.duration, duration > 0 else { return true }
        return abs(duration - targetDuration) / duration <= 0.05
    }

    private static func score(
        _ record: LRCLIBRecord,
        _ targetTrack: String,
        _ targetArtist: String,
        _ targetDuration: TimeInterval
    ) -> Int {
        let recordTrack = normalized(record.trackName ?? "")
        let recordArtist = normalized(record.artistName ?? "")
        var value = recordTrack == targetTrack ? 8 : (recordTrack.contains(targetTrack) ? 3 : 0)
        value += recordArtist == targetArtist ? 6 : (recordArtist.contains(targetArtist) ? 2 : 0)
        if let duration = record.duration, abs(duration - targetDuration) <= 3 { value += 4 }
        return value
    }

    private static func normalized(_ value: String) -> String {
        SimplifiedChinese.normalize(value)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    static func lookupTitle(_ title: String) -> String {
        let patterns = [
            #"\s*[\(（\[].*?[\)）\]]\s*$"#,
            #"\s*[-–—]\s*(live|现场|remaster(?:ed)?|acoustic|伴奏|instrumental).*$"#
        ]
        return patterns.reduce(title) { value, pattern in
            value.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hash(_ source: String) -> String {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in source.utf8 {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        return String(value, radix: 16)
    }
}

enum LyricsError: LocalizedError {
    case invalidRequest
    case notFound

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "歌词请求无效"
        case .notFound: return "未找到同步歌词"
        }
    }
}

final class SettingsStore {
    static let shared = SettingsStore()
    static let defaultSyncOffset = 0.65
    static let minimumSyncOffset = -1.5
    static let maximumSyncOffset = 1.5

    private enum Key {
        static let chineseFont = "chineseFont"
        static let latinFont = "latinFont"
        static let fontSize = "fontSize"
        static let syncOffset = "syncOffset"
        static let welcomeShown = "welcomeShown"
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.chineseFont: "KaiTi",
            Key.latinFont: "Times New Roman",
            Key.fontSize: 13.0,
            Key.syncOffset: Self.defaultSyncOffset,
            Key.welcomeShown: false
        ])
    }

    var chineseFont: String {
        get { defaults.string(forKey: Key.chineseFont) ?? "KaiTi" }
        set { defaults.set(newValue, forKey: Key.chineseFont) }
    }

    var latinFont: String {
        get { defaults.string(forKey: Key.latinFont) ?? "Times New Roman" }
        set { defaults.set(newValue, forKey: Key.latinFont) }
    }

    var fontSize: CGFloat {
        get { CGFloat(defaults.double(forKey: Key.fontSize)) }
        set { defaults.set(Double(newValue), forKey: Key.fontSize) }
    }

    var syncOffset: Double {
        get { Self.clampedSyncOffset(defaults.double(forKey: Key.syncOffset)) }
        set { defaults.set(Self.clampedSyncOffset(newValue), forKey: Key.syncOffset) }
    }

    var welcomeShown: Bool {
        get { defaults.bool(forKey: Key.welcomeShown) }
        set { defaults.set(newValue, forKey: Key.welcomeShown) }
    }

    func restoreDefaults() {
        chineseFont = "KaiTi"
        latinFont = "Times New Roman"
        fontSize = 13
        syncOffset = Self.defaultSyncOffset
    }

    static func syncOffsetLabel(_ value: Double) -> String {
        let value = clampedSyncOffset(value)
        if abs(value) < 0.005 { return "同步" }
        return String(format: value > 0 ? "提前 %.2f 秒" : "延后 %.2f 秒", abs(value))
    }

    private static func clampedSyncOffset(_ value: Double) -> Double {
        min(max(value, minimumSyncOffset), maximumSyncOffset)
    }
}

struct FittedLyric {
    let attributedText: NSAttributedString
    let statusWidth: CGFloat
    let effectiveFontSize: CGFloat
}

enum AttributedLyricFormatter {
    static let maximumWidth: CGFloat = 420
    private static let horizontalPadding: CGFloat = 18
    private static let minimumFontSize: CGFloat = 6.5

    static func fit(
        _ text: String,
        chineseFont: String,
        latinFont: String,
        preferredSize: CGFloat,
        maximumWidth: CGFloat = maximumWidth
    ) -> FittedLyric {
        let available = maximumWidth - horizontalPadding
        var size = min(max(preferredSize, minimumFontSize), 16)
        var attributed = make(text, chineseFont: chineseFont, latinFont: latinFont, size: size)
        let initialWidth = attributed.size().width

        if initialWidth > available {
            size = max(minimumFontSize, floor(size * available / initialWidth * 10) / 10)
            attributed = make(text, chineseFont: chineseFont, latinFont: latinFont, size: size)
            while attributed.size().width > available, size > minimumFontSize {
                size = max(minimumFontSize, size - 0.2)
                attributed = make(text, chineseFont: chineseFont, latinFont: latinFont, size: size)
            }
        }

        let width = min(maximumWidth, max(38, ceil(attributed.size().width + horizontalPadding)))
        return FittedLyric(
            attributedText: attributed,
            statusWidth: width,
            effectiveFontSize: size
        )
    }

    static func make(
        _ text: String,
        chineseFont: String,
        latinFont: String,
        size: CGFloat
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byClipping
        result.addAttributes([
            .paragraphStyle: paragraph,
            .foregroundColor: NSColor.labelColor
        ], range: NSRange(location: 0, length: result.length))

        for characterRange in text.indices.map({ $0..<text.index(after: $0) }) {
            let character = text[characterRange]
            let fontName = isChinese(character) ? chineseFont : latinFont
            let font = NSFont(name: fontName, size: size) ?? NSFont.systemFont(ofSize: size)
            result.addAttribute(.font, value: font, range: NSRange(characterRange, in: text))
        }
        return result
    }

    private static func isChinese(_ character: Substring) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x2E80...0x2FFF,
                 0x3000...0x303F,
                 0x3400...0x4DBF,
                 0x4E00...0x9FFF,
                 0xF900...0xFAFF,
                 0xFF00...0xFFEF,
                 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }
}

enum MenuBarLayout {
    private static let edgeClearance: CGFloat = 8

    static func lyricWidthLimit(
        itemRightEdge: CGFloat?,
        safeRegionMinX: CGFloat?
    ) -> CGFloat {
        guard let itemRightEdge,
              let safeRegionMinX,
              itemRightEdge > safeRegionMinX else {
            return AttributedLyricFormatter.maximumWidth
        }
        return min(
            AttributedLyricFormatter.maximumWidth,
            max(38, floor(itemRightEdge - safeRegionMinX - edgeClearance))
        )
    }
}
