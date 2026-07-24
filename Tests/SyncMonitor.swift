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
let cacheBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
let cacheURL = cacheBase
    .appendingPathComponent("personal.chris.LyricFeverScroll/Lyrics")
    .appendingPathComponent(LyricsProvider.cacheFileName(for: initial))
guard let cacheData = try? Data(contentsOf: cacheURL),
      let document = try? JSONDecoder().decode(LyricsDocument.self, from: cacheData) else {
    fputs("No lyric cache for \(initial.name)\n", stderr)
    exit(3)
}

let lines = LyricTimeline.adjusted(
    LRCParser.parse(document.source),
    referenceDuration: document.referenceDuration,
    playbackDuration: initial.duration
)
let music = SBApplication(bundleIdentifier: "com.apple.Music")!
let statusReader = StatusReader()
let syncOffset = SettingsStore.shared.syncOffset
let started = ProcessInfo.processInfo.systemUptime
var samples = 0
var mismatch: (started: TimeInterval, position: TimeInterval, expected: String, observed: String)?
var longestMismatch: TimeInterval = 0
var misses: [(TimeInterval, String, String)] = []
var lastExpected = ""

func finishMismatch(at now: TimeInterval) {
    guard let mismatch else { return }
    let duration = now - mismatch.started
    longestMismatch = max(longestMismatch, duration)
    if duration >= 0.3 {
        misses.append((mismatch.position, mismatch.expected, mismatch.observed))
    }
}

while ProcessInfo.processInfo.systemUptime - started < monitorDuration {
    autoreleasepool {
        let position = (music.value(forKey: "playerPosition") as? NSNumber)?.doubleValue ?? 0
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
    print(String(format: "MISMATCH %.3f expected=%@ observed=%@", miss.0, miss.1, miss.2))
}
}
}
