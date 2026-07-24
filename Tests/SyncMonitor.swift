import AppKit
import Foundation
import ScriptingBridge

private final class StatusReader {
    private let script = NSAppleScript(source: #"""
    tell application "System Events"
        tell process "Lyric Fever Scroll"
            return name of menu bar item 1 of menu bar 1
        end tell
    end tell
    """#)

    func title() -> String? {
        var error: NSDictionary?
        return script?.executeAndReturnError(&error).stringValue
    }
}

@main
enum SyncMonitor {
static func main() throws {
guard let durationArgument = CommandLine.arguments.dropFirst().first,
      let monitorDuration = TimeInterval(durationArgument),
      !NSRunningApplication.runningApplications(
        withBundleIdentifier: "personal.chris.LyricFeverScroll"
      ).isEmpty else {
    fputs("Usage: sync-monitor <seconds>; app must be running\n", stderr)
    exit(2)
}

let musicClient = AppleMusicClient()
let initial = try musicClient.snapshot()
let lines: [LyricLine]
let lyricSource: String
if let appleLines = AppleMusicCacheLyricsProvider().lines(for: initial) {
    lines = appleLines
    lyricSource = "Apple Music"
} else {
    let cacheBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    let cacheURL = cacheBase
        .appendingPathComponent("personal.chris.LyricFeverScroll/Lyrics")
        .appendingPathComponent(LyricsProvider.cacheFileName(for: initial))
    guard let cacheData = try? Data(contentsOf: cacheURL),
          let document = try? JSONDecoder().decode(LyricsDocument.self, from: cacheData) else {
        fputs("No lyric cache for \(initial.name)\n", stderr)
        exit(3)
    }
    lines = LyricTimeline.adjusted(
        document.parsedLines,
        referenceDuration: document.referenceDuration,
        playbackDuration: initial.duration
    )
    lyricSource = document.provider ?? "LRCLIB"
}
print("SOURCE \(lyricSource) lines=\(lines.count) track=\(initial.name)")
let music = SBApplication(bundleIdentifier: "com.apple.Music")!
let statusReader = StatusReader()
let appDefaults = UserDefaults(suiteName: "personal.chris.LyricFeverScroll")
let storedSyncOffset = (appDefaults?.object(forKey: "syncOffset") as? NSNumber)?.doubleValue
let syncOffset = min(
    max(storedSyncOffset ?? SettingsStore.defaultSyncOffset, SettingsStore.minimumSyncOffset),
    SettingsStore.maximumSyncOffset
)
print(String(format: "OFFSET %+.3fs", syncOffset))
let started = ProcessInfo.processInfo.systemUptime
var samples = 0
var mismatch: (started: TimeInterval, position: TimeInterval, expected: String, observed: String)?
var longestMismatch: TimeInterval = 0
var misses: [(startedAt: TimeInterval, endedAt: TimeInterval, duration: TimeInterval, expected: String, observed: String)] = []
var lastExpected = ""
var lastPosition = initial.position

func finishMismatch(at now: TimeInterval) {
    guard let mismatch else { return }
    let duration = now - mismatch.started
    longestMismatch = max(longestMismatch, duration)
    if duration >= 0.3 {
        misses.append((mismatch.position, lastPosition, duration, mismatch.expected, mismatch.observed))
    }
}

while ProcessInfo.processInfo.systemUptime - started < monitorDuration {
    autoreleasepool {
        let position = (music.value(forKey: "playerPosition") as? NSNumber)?.doubleValue ?? 0
        lastPosition = position
        let index = LRCParser.currentIndex(in: lines, at: position + syncOffset)
        let expected: String
        if let index {
            expected = lines[index].text.isEmpty ? "♪" : lines[index].text
        } else {
            expected = "♪ \(initial.name)"
        }
        let observed = statusReader.title() ?? "<unavailable>"
        let now = ProcessInfo.processInfo.systemUptime
        samples += 1

        if expected != lastExpected {
            print(String(format: "LINE %.3f %@", position, expected))
            lastExpected = expected
        }

        if observed == expected {
            finishMismatch(at: now)
            mismatch = nil
        } else if mismatch == nil {
            mismatch = (now, position, expected, observed)
        }
    }
    Thread.sleep(forTimeInterval: 0.1)
}

finishMismatch(at: ProcessInfo.processInfo.systemUptime)
print(String(format: "SUMMARY samples=%d longestMismatch=%.3fs materialMismatches=%d", samples, longestMismatch, misses.count))
for miss in misses.prefix(10) {
    print(String(
        format: "MISMATCH %.3f–%.3f duration=%.3fs expected=%@ observed=%@",
        miss.startedAt,
        miss.endedAt,
        miss.duration,
        miss.expected,
        miss.observed
    ))
}
}
}
