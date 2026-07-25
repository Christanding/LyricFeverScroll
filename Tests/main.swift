import AppKit
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let parsed = LRCParser.parse("""
[offset:100]
[00:01.20][00:02.300]抓住命運衣袖
[00:05.00]Hello world
""")
expect(parsed.count == 3, "应解析一行多时间戳")
expect(abs(parsed[0].time - 1.3) < 0.001, "应应用 offset")
expect(parsed[0].text == "抓住命运衣袖", "应转换为简体中文")
expect(SimplifiedChinese.normalize("當妳的淚水") == "当你的泪水", "应规范台湾地区人称用字")
expect(SimplifiedChinese.normalize("噯眛地做不了決擇") == "暧昧地做不了抉择", "应修正常见歌词错字")
expect(
    SimplifiedChinese.normalize("台灣的軟體用滑鼠，搭計程車回家") == "台湾的软件用鼠标，搭出租车回家",
    "台湾词汇必须归一为大陆简体"
)
expect(SimplifiedChinese.normalize("我抬起了頭") == "我抬起了头", "不得把大陆用字转换成台湾异体字")
expect(SimplifiedChinese.normalize("我擡起了頭") == "我抬起了头", "残留异体字必须归一为大陆简体")
expect(SimplifiedChinese.normalize("越揹越沉重的殼") == "越背越沉重的壳", "台湾异体字必须归一为大陆简体")
expect(SimplifiedChinese.normalize("乙太網路") == "以太网", "新版台湾词汇必须归一为大陆用词")
expect(SimplifiedChinese.normalize("預設軟體") == "默认软件", "台湾常用词必须归一为大陆首选表达")
expect(LRCParser.currentIndex(in: parsed, at: 1.0) == nil, "首句前不应有当前歌词")
expect(LRCParser.currentIndex(in: parsed, at: 2.5) == 1, "应定位当前歌词")

let appleReplacementTTML = """
<tt xmlns="http://www.w3.org/ns/ttml"
    xmlns:itunes="http://music.apple.com/lyric-ttml-internal"
    xml:lang="zh-Hant">
  <head><metadata><itunes:iTunesMetadata><itunes:translations>
    <itunes:translation xml:lang="zh-Hans" type="replacement">
      <itunes:text for="L1"><span begin="1.25" end="1.50">当</span><span begin="1.50" end="2.00">你</span></itunes:text>
    </itunes:translation>
  </itunes:translations></itunes:iTunesMetadata></metadata></head>
  <body><div>
    <p begin="1.25" end="2.00" itunes:key="L1"><span begin="1.25" end="1.50">當</span><span begin="1.50" end="2.00">妳</span></p>
  </div></body>
</tt>
"""
let appleReplacementLines = AppleTTMLParser.parse(appleReplacementTTML)
expect(appleReplacementLines == [LyricLine(time: 1.25, text: "当你")], "必须优先使用 Apple 官方 zh-Hans replacement")
let wrappedAppleTTML = String(
    data: try! JSONSerialization.data(withJSONObject: ["zh-Hans-CN": appleReplacementTTML]),
    encoding: .utf8
)!
expect(
    AppleMusicCacheLyricsProvider.localizedTTML(from: wrappedAppleTTML) == appleReplacementTTML,
    "必须兼容 Music.app 用语言 JSON 包装 TTML 的缓存格式"
)

let appleCacheRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("AppleMusicCache-\(UUID().uuidString)", isDirectory: true)
let appleCacheDataDirectory = appleCacheRoot.appendingPathComponent("fsCachedData", isDirectory: true)
try! FileManager.default.createDirectory(at: appleCacheDataDirectory, withIntermediateDirectories: true)
let appleLyricRelationships: [String: Any] = [
    "syllable-lyrics": [
        "data": [["attributes": ["ttmlLocalizations": appleReplacementTTML]]]
    ]
]
let appleCatalogResponse: [String: Any] = [
    "data": [[
        "attributes": [
            "name": "缓存测试曲",
            "artistName": "测试歌手",
            "albumName": "测试专辑",
            "durationInMillis": 2_000
        ],
        "relationships": appleLyricRelationships
    ]]
]
let appleCatalogData = try! JSONSerialization.data(withJSONObject: appleCatalogResponse)
try! appleCatalogData.write(to: appleCacheDataDirectory.appendingPathComponent(UUID().uuidString))
let appleCacheTrack = MusicSnapshot(
    state: "playing",
    name: "缓存测试曲",
    artist: "测试歌手",
    album: "测试专辑",
    position: 0,
    duration: 2
)
let appleCacheProvider = AppleMusicCacheLyricsProvider(cacheRoot: appleCacheRoot)
let appleCachedLines = appleCacheProvider.lines(for: appleCacheTrack)
let wrongAppleVersion = MusicSnapshot(
    state: "playing",
    name: appleCacheTrack.name,
    artist: appleCacheTrack.artist,
    album: appleCacheTrack.album,
    position: 0,
    duration: 30
)
expect(appleCacheProvider.lines(for: wrongAppleVersion) == nil, "同名但时长不符的 Apple 歌词必须拒绝")
try! FileManager.default.removeItem(at: appleCacheRoot)
expect(appleCachedLines == appleReplacementLines, "必须从 Music.app 本机缓存匹配并解析官方歌词")

let durationlessCacheRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("AppleMusicDurationless-\(UUID().uuidString)", isDirectory: true)
let durationlessDataDirectory = durationlessCacheRoot
    .appendingPathComponent("fsCachedData", isDirectory: true)
try! FileManager.default.createDirectory(at: durationlessDataDirectory, withIntermediateDirectories: true)
let durationlessResponse: [String: Any] = [
    "data": [[
        "attributes": [
            "name": appleCacheTrack.name,
            "artistName": appleCacheTrack.artist,
            "albumName": appleCacheTrack.album
        ],
        "relationships": appleLyricRelationships
    ]]
]
try! JSONSerialization.data(withJSONObject: durationlessResponse).write(
    to: durationlessDataDirectory.appendingPathComponent(UUID().uuidString)
)
expect(
    AppleMusicCacheLyricsProvider(cacheRoot: durationlessCacheRoot).lines(for: appleCacheTrack) == nil,
    "Apple 歌词缺少时长时不得猜测同名版本"
)
try! FileManager.default.removeItem(at: durationlessCacheRoot)

let appleWatchRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("AppleMusicWatch-\(UUID().uuidString)", isDirectory: true)
let appleWatchDataDirectory = appleWatchRoot.appendingPathComponent("fsCachedData", isDirectory: true)
try! FileManager.default.createDirectory(at: appleWatchDataDirectory, withIntermediateDirectories: true)
let appleWatchResult = DispatchSemaphore(value: 0)
var watchedAppleLines: [LyricLine]?
let appleWatch = AppleMusicCacheLyricsProvider(cacheRoot: appleWatchRoot).watch(
    for: appleCacheTrack,
    timeout: 1
) { lines in
    watchedAppleLines = lines
    appleWatchResult.signal()
}
DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
    try! appleCatalogData.write(to: appleWatchDataDirectory.appendingPathComponent(UUID().uuidString))
}
expect(appleWatchResult.wait(timeout: .now() + 2) == .success, "Music.app 缓存写入必须触发事件驱动读取")
expect(watchedAppleLines == appleReplacementLines, "新写入的 Apple 官方歌词必须立即被采用")
appleWatch.cancel()

final class NoNetworkURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
let noNetworkConfiguration = URLSessionConfiguration.ephemeral
noNetworkConfiguration.protocolClasses = [NoNetworkURLProtocol.self]
let localFirstProvider = LyricsProvider(
    session: URLSession(configuration: noNetworkConfiguration),
    appleCacheProvider: AppleMusicCacheLyricsProvider(cacheRoot: appleWatchRoot)
)
var localFirstDocument: LyricsDocument?
let localFirstTask = localFirstProvider.load(for: appleCacheTrack, ignoringCache: true) { result in
    localFirstDocument = try? result.get()
}
DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
    try! appleCatalogData.write(
        to: appleWatchDataDirectory.appendingPathComponent(UUID().uuidString)
    )
}
let localFirstDeadline = Date().addingTimeInterval(2)
while localFirstDocument == nil, Date() < localFirstDeadline {
    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
}
expect(localFirstDocument?.provider == "Apple Music", "官方本地缓存必须优先于 LRCLIB 网络回退")
expect(localFirstDocument?.parsedLines == appleReplacementLines, "加载链必须保留 Apple TTML 的原始时间轴")
localFirstTask.cancel()
let appleDocument = LyricsDocument(
    source: "",
    referenceDuration: appleCacheTrack.duration,
    embeddedLines: appleReplacementLines,
    provider: "Apple Music"
)
expect(appleDocument.parsedLines == appleReplacementLines, "应直接使用 TTML 时间轴，不应转成有损 LRC")
expect(
    LyricsProvider.shouldUseCache(appleDocument, for: appleCacheTrack, ignoringCache: false),
    "已验证的 Apple TTML 必须本地缓存，以便再次播放时立即显示"
)
try! FileManager.default.removeItem(at: appleWatchRoot)

let delayedAppleRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("AppleMusicDelayed-\(UUID().uuidString)", isDirectory: true)
let delayedAppleDataDirectory = delayedAppleRoot
    .appendingPathComponent("fsCachedData", isDirectory: true)
try! FileManager.default.createDirectory(at: delayedAppleDataDirectory, withIntermediateDirectories: true)
let delayedAppleProvider = LyricsProvider(
    session: URLSession(configuration: noNetworkConfiguration),
    appleCacheProvider: AppleMusicCacheLyricsProvider(cacheRoot: delayedAppleRoot)
)
var delayedAppleResult: Result<LyricsDocument, Error>?
let delayedAppleTask = delayedAppleProvider.load(for: appleCacheTrack, ignoringCache: true) {
    delayedAppleResult = $0
}
DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
    try! appleCatalogData.write(
        to: delayedAppleDataDirectory.appendingPathComponent(UUID().uuidString)
    )
}
let delayedAppleDeadline = Date().addingTimeInterval(2)
while delayedAppleResult == nil, Date() < delayedAppleDeadline {
    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
}
expect(
    (try? delayedAppleResult?.get().provider) == "Apple Music",
    "LRCLIB 提前失败时仍必须等待已在到达的 Apple 官方歌词"
)
delayedAppleTask.cancel()
try! FileManager.default.removeItem(at: delayedAppleRoot)

let blankGap = LRCParser.parse("[00:01.00]第一句\n[00:02.00] \n[00:03.00]第二句")
expect(blankGap.count == 3 && blankGap[1].text.isEmpty, "带时间戳的空行必须清空上一句")
expect(LyricsProvider.lookupTitle("迷人的危险 (Live)") == "迷人的危险", "应为现场版回退基础歌名")

let unrelatedLyrics = LRCLIBRecord(
    trackName: "迷人的危险",
    artistName: "其他歌手",
    albumName: nil,
    duration: 203,
    syncedLyrics: "[00:01.00]错误歌词"
)
let liveTrack = MusicSnapshot(
    state: "playing",
    name: "迷人的危险 (Live)",
    artist: "Dance Flow",
    album: "Live",
    position: 0,
    duration: 203
)
expect(LyricsProvider.bestMatch(in: [unrelatedLyrics], for: liveTrack) == nil, "不得接受无关歌手的搜索结果")
let correctLiveLyrics = LRCLIBRecord(
    trackName: "迷人的危险",
    artistName: "Dance Flow",
    albumName: nil,
    duration: 205,
    syncedLyrics: "[00:01.00]正确歌词"
)
expect(LyricsProvider.bestMatch(in: [correctLiveLyrics], for: liveTrack) != nil, "必须保留可信的现场版回退结果")

let traditionalArtistLyrics = LRCLIBRecord(
    trackName: "空心",
    artistName: "光澤",
    albumName: "光澤",
    duration: 279,
    syncedLyrics: "[00:13.94]热爱曾是唯一的信仰"
)
let simplifiedArtistTrack = MusicSnapshot(
    state: "playing",
    name: "空心",
    artist: "光泽",
    album: "光泽",
    position: 0,
    duration: 279
)
expect(
    LyricsProvider.bestMatch(in: [traditionalArtistLyrics], for: simplifiedArtistTrack) != nil,
    "歌手名的繁简差异不得阻止正确歌词匹配"
)
let traditionalMetadataLyrics = LRCLIBRecord(
    trackName: "後來",
    artistName: "劉若英",
    albumName: nil,
    duration: 329,
    syncedLyrics: "[00:01.00]后来"
)
let simplifiedMetadataTrack = MusicSnapshot(
    state: "playing",
    name: "后来",
    artist: "刘若英",
    album: "",
    position: 0,
    duration: 329
)
expect(
    LyricsProvider.bestMatch(in: [traditionalMetadataLyrics], for: simplifiedMetadataTrack) != nil,
    "不同歌曲的歌名和歌手繁简差异也必须通用匹配"
)
expect(
    LyricsProvider.searchTitles(for: "后来") == ["后来", "後來"],
    "搜索失败后必须能用另一种繁简标题回退"
)

let wrongVersionCache = LyricsDocument(source: "[00:01.00]错误版本", referenceDuration: 180)
expect(
    !LyricsProvider.shouldUseCache(wrongVersionCache, for: liveTrack, ignoringCache: false),
    "时长差超过 5% 的缓存必须失效"
)
let validCache = LyricsDocument(source: "[00:01.00]正确版本", referenceDuration: 203)
expect(
    !LyricsProvider.shouldUseCache(validCache, for: liveTrack, ignoringCache: true),
    "手动重新加载必须绕过有效缓存"
)

let cacheTestDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("LyricFeverScroll-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: cacheTestDirectory, withIntermediateDirectories: true)
for index in 0..<4 {
    let url = cacheTestDirectory.appendingPathComponent("cache-\(index).json")
    try! Data("\(index)".utf8).write(to: url)
    try! FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: TimeInterval(index))],
        ofItemAtPath: url.path
    )
}
LyricsProvider.pruneCache(at: cacheTestDirectory, keeping: 2)
let remainingCacheFiles = try! FileManager.default.contentsOfDirectory(atPath: cacheTestDirectory.path).sorted()
try! FileManager.default.removeItem(at: cacheTestDirectory)
expect(remainingCacheFiles == ["cache-2.json", "cache-3.json"], "缓存必须只保留最新的指定数量")

let diagnostics = PlaybackDiagnostics(capacity: 2)
diagnostics.record("first")
diagnostics.record("second")
diagnostics.record("third")
expect(!diagnostics.report.contains("first") && diagnostics.report.contains("third"), "诊断环必须限制内存容量")
expect(SettingsStore.syncOffsetLabel(0.65) == "提前 0.65 秒", "同步偏移标签必须明确显示方向")
expect(SettingsStore.syncOffsetLabel(-0.25) == "延后 0.25 秒", "负偏移必须显示为延后")
var retryBackoff = RetryBackoff()
let retryDelays = (0..<7).map { _ in retryBackoff.nextDelay() }
expect(retryDelays == [1, 2, 4, 8, 16, 30, 30], "MediaRemote 重启必须指数退避并限制在 30 秒")
retryBackoff.reset()
expect(retryBackoff.nextDelay() == 1, "收到正常事件后必须重置重启退避")
let incompleteMediaEvent = MediaRemotePlaybackEvent(
    position: 0,
    duration: 0,
    isPlaying: true,
    title: "新歌",
    artist: "",
    album: ""
)
expect(!incompleteMediaEvent.hasTrackMetadata, "切歌的半成品媒体事件不得用于匹配歌词")
let durationlessMediaEvent = MediaRemotePlaybackEvent(
    position: 0,
    duration: 0,
    isPlaying: true,
    title: "新歌",
    artist: "歌手",
    album: "专辑"
)
expect(!durationlessMediaEvent.hasTrackMetadata, "时长尚未到达时必须等待完整曲目快照")

let fitted = AttributedLyricFormatter.fit(
    "抓住命运衣袖 在路口等我 This is a complete lyric line tonight",
    chineseFont: "KaiTi",
    latinFont: "Times New Roman",
    preferredSize: 13
)
expect(fitted.statusWidth <= 420, "状态栏宽度不得超过 420pt")
expect(fitted.attributedText.string.contains("complete lyric line"), "不得截断歌词")

let notchedScreenWidth = MenuBarLayout.lyricWidthLimit(
    itemRightEdge: 1_209,
    safeRegionMinX: 850
)
expect(notchedScreenWidth == 220, "刘海屏歌词不得伸入菜单栏非安全区域")
expect(
    MenuBarLayout.lyricWidthLimit(itemRightEdge: nil, safeRegionMinX: nil) == 220,
    "菜单栏歌词应使用固定宽度，避免其他图标移动"
)
let notchedScreenFitted = AttributedLyricFormatter.fit(
    "我的爱如潮水 爱如潮水将我向你推 紧紧跟随 爱如潮水它将你我包围",
    chineseFont: "KaiTi",
    latinFont: "Times New Roman",
    preferredSize: 13,
    maximumWidth: notchedScreenWidth
)
expect(notchedScreenFitted.statusWidth <= 220, "长歌词必须留在刘海右侧安全区")
expect(notchedScreenFitted.attributedText.size().width <= 202, "长歌词不得在固定槽内被裁切")
expect(notchedScreenFitted.attributedText.string.contains("爱如潮水它将你我包围"), "适配刘海时仍不得截断歌词")

let chineseFont = fitted.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
let englishLocation = (fitted.attributedText.string as NSString).range(of: "This").location
let englishFont = fitted.attributedText.attribute(.font, at: englishLocation, effectiveRange: nil) as? NSFont
let expectedChineseFamily = NSFont(name: "KaiTi", size: 13)?.familyName
    ?? NSFont.systemFont(ofSize: 13).familyName
let expectedEnglishFamily = NSFont(name: "Times New Roman", size: 13)?.familyName
    ?? NSFont.systemFont(ofSize: 13).familyName
expect(chineseFont?.familyName == expectedChineseFamily, "中文应使用楷体，不可用时应回退到系统字体")
expect(englishFont?.familyName == expectedEnglishFamily, "英文应使用 Times New Roman，不可用时应回退到系统字体")

let adjusted = LyricTimeline.adjusted(
    [LyricLine(time: 100, text: "测试")],
    referenceDuration: 205,
    playbackDuration: 203
)
expect(abs(adjusted[0].time - 99.024) < 0.01, "不同版本应按实际时长校正时间轴")

print("PASS: parser, Simplified Chinese, full-line fitting, mixed fonts")
