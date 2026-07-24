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

let diagnostics = PlaybackDiagnostics(capacity: 2)
diagnostics.record("first")
diagnostics.record("second")
diagnostics.record("third")
expect(!diagnostics.report.contains("first") && diagnostics.report.contains("third"), "诊断环必须限制内存容量")
expect(SettingsStore.syncOffsetLabel(0.65) == "提前 0.65 秒", "同步偏移标签必须明确显示方向")
expect(SettingsStore.syncOffsetLabel(-0.25) == "延后 0.25 秒", "负偏移必须显示为延后")

let fitted = AttributedLyricFormatter.fit(
    "抓住命运衣袖 在路口等我 This is a complete lyric line tonight",
    chineseFont: "KaiTi",
    latinFont: "Times New Roman",
    preferredSize: 13
)
expect(fitted.statusWidth <= 420, "状态栏宽度不得超过 420pt")
expect(fitted.attributedText.string.contains("complete lyric line"), "不得截断歌词")

let chineseFont = fitted.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
let englishLocation = (fitted.attributedText.string as NSString).range(of: "This").location
let englishFont = fitted.attributedText.attribute(.font, at: englishLocation, effectiveRange: nil) as? NSFont
expect(chineseFont?.familyName == "KaiTi", "中文应使用楷体")
expect(englishFont?.familyName == "Times New Roman", "英文应使用 Times New Roman")

let adjusted = LyricTimeline.adjusted(
    [LyricLine(time: 100, text: "测试")],
    referenceDuration: 205,
    playbackDuration: 203
)
expect(abs(adjusted[0].time - 99.024) < 0.01, "不同版本应按实际时长校正时间轴")

print("PASS: parser, Simplified Chinese, full-line fitting, mixed fonts")
