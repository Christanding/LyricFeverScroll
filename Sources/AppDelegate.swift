import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let playbackReconciliationInterval: TimeInterval = 15

    private let music = AppleMusicClient()
    private let mediaRemote = MediaRemotePositionStream()
    private let lyricsProvider = LyricsProvider()
    private let settings = SettingsStore.shared
    private let diagnostics = PlaybackDiagnostics.shared
    private let musicQueue = DispatchQueue(
        label: "personal.chris.LyricFeverScroll.music",
        qos: .userInitiated
    )

    private var statusItem: NSStatusItem!
    private var reservedStatusWidth: CGFloat?
    private var trackMenuItem: NSMenuItem!
    private var launchAtLoginMenuItem: NSMenuItem!
    private var settingsWindow: SettingsWindowController!
    private var reconciliationTimer: Timer?
    private var lyricTimer: Timer?
    private var lyricsTask: LyricsLoadTask?
    private var loadingTrackKey: String?
    private var loadedTrackKey: String?
    private var lyricsLoadGeneration = 0
    private var musicRefreshGeneration = 0

    private var snapshot: MusicSnapshot?
    private var lines: [LyricLine] = []
    private var currentLineIndex: Int?
    private var anchorPosition: TimeInterval = 0
    private var anchorUptime: TimeInterval = 0
    private var displayedText = ""
    private var consecutiveMusicFailures = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createStatusItem()
        settingsWindow = SettingsWindowController { [weak self] in
            self?.renderCurrentText()
            self?.updateCurrentLyric()
        }

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(musicPlayerChanged(_:)),
            name: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        reconciliationTimer = Timer.scheduledTimer(
            timeInterval: Self.playbackReconciliationInterval,
            target: self,
            selector: #selector(reconcilePlayback),
            userInfo: nil,
            repeats: true
        )
        reconciliationTimer?.tolerance = 2
        mediaRemote.start { [weak self] event in
            self?.mediaRemoteChanged(event)
        }
        diagnostics.record("app.started")
        refreshFromMusic(forceLyrics: true)

        if !settings.welcomeShown {
            settings.welcomeShown = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.settingsWindow.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        reconciliationTimer?.invalidate()
        mediaRemote.stop()
        lyricTimer?.invalidate()
        lyricsTask?.cancel()
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: 140)
        statusItem.autosaveName = "LyricFeverScroll.Leftmost"
        if let button = statusItem.button {
            button.title = "歌词…"
            button.toolTip = "Lyric Fever Scroll"
            button.setAccessibilityLabel("当前歌词")
        }

        let menu = NSMenu()
        trackMenuItem = NSMenuItem(title: "正在连接 Apple Music…", action: nil, keyEquivalent: "")
        trackMenuItem.isEnabled = false
        menu.addItem(trackMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "字体与显示设置…",
            action: #selector(openSettings),
            keyEquivalent: ","
        ))
        launchAtLoginMenuItem = NSMenuItem(
            title: "登录时自动启动",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        menu.addItem(launchAtLoginMenuItem)
        menu.addItem(NSMenuItem(
            title: "重新加载歌词",
            action: #selector(reloadLyrics),
            keyEquivalent: "r"
        ))
        menu.addItem(NSMenuItem(
            title: "复制诊断信息",
            action: #selector(copyDiagnostics),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "退出 Lyric Fever Scroll",
            action: #selector(quit),
            keyEquivalent: "q"
        ))
        menu.items.forEach { $0.target = self }
        menu.delegate = self
        statusItem.menu = menu
        updateLaunchAtLoginMenuItem()
        display("歌词…")
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateLaunchAtLoginMenuItem()
    }

    @objc private func musicPlayerChanged(_ notification: Notification) {
        refreshFromMusic(forceLyrics: false)
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        diagnostics.record("workspace.did-wake")
        refreshFromMusic(forceLyrics: false)
    }

    @objc private func reconcilePlayback() {
        refreshFromMusic(forceLyrics: false)
    }

    private func refreshFromMusic(forceLyrics: Bool) {
        musicRefreshGeneration += 1
        let generation = musicRefreshGeneration
        musicQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.music.snapshot() }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.musicRefreshGeneration == generation else { return }
                self.applyMusicResult(result, forceLyrics: forceLyrics)
            }
        }
    }

    private func applyMusicResult(
        _ result: Result<MusicSnapshot, Error>,
        forceLyrics: Bool
    ) {
        switch result {
        case .success(let newSnapshot):
            if consecutiveMusicFailures > 0 {
                diagnostics.record("music.recovered failures=\(consecutiveMusicFailures)")
                consecutiveMusicFailures = 0
            }
            let oldKey = snapshot?.trackKey
            snapshot = newSnapshot
            anchorPosition = newSnapshot.position
            anchorUptime = ProcessInfo.processInfo.systemUptime

            if newSnapshot.hasTrack {
                trackMenuItem.title = "\(newSnapshot.name) — \(newSnapshot.artist)"
            } else {
                trackMenuItem.title = "Apple Music 未播放"
            }

            guard newSnapshot.hasTrack else {
                lyricsTask?.cancel()
                lyricsTask = nil
                lyricsLoadGeneration += 1
                loadingTrackKey = nil
                lines = []
                loadedTrackKey = nil
                currentLineIndex = nil
                lyricTimer?.invalidate()
                display(newSnapshot.state == "not running" ? "打开 Apple Music 后显示歌词" : "Apple Music 未播放")
                return
            }

            if forceLyrics || oldKey != newSnapshot.trackKey {
                loadLyrics(for: newSnapshot)
            } else {
                updateCurrentLyric()
            }
        case .failure(let error):
            consecutiveMusicFailures += 1
            diagnostics.record(
                "music.snapshot-failed count=\(consecutiveMusicFailures) error=\(error.localizedDescription)"
            )
            guard snapshot == nil else {
                if consecutiveMusicFailures >= 3 {
                    trackMenuItem.title = "Apple Music 状态校准暂不可用，歌词继续"
                }
                return
            }
            trackMenuItem.title = "需要 Apple Music 权限"
            lyricTimer?.invalidate()
            display("请授权 Apple Music")
        }
    }

    private func mediaRemoteChanged(_ event: MediaRemotePlaybackEvent) {
        guard event.hasTrackMetadata else {
            refreshFromMusic(forceLyrics: false)
            return
        }
        musicRefreshGeneration += 1
        let oldKey = snapshot?.trackKey
        let newSnapshot = MusicSnapshot(
            state: event.isPlaying ? "playing" : "paused",
            name: event.title,
            artist: event.artist,
            album: event.album,
            position: event.position,
            duration: event.duration
        )
        snapshot = newSnapshot
        anchorPosition = event.position
        anchorUptime = ProcessInfo.processInfo.systemUptime
        trackMenuItem.title = "\(event.title) — \(event.artist)"

        if oldKey != newSnapshot.trackKey {
            diagnostics.record("track.changed title=\(event.title) artist=\(event.artist)")
            loadLyrics(for: newSnapshot)
        } else {
            updateCurrentLyric()
        }
    }

    private func loadLyrics(for track: MusicSnapshot, ignoringCache: Bool = false) {
        let alreadyLoaded = loadedTrackKey == track.trackKey && !lines.isEmpty
        guard ignoringCache || (loadingTrackKey != track.trackKey && !alreadyLoaded) else {
            diagnostics.record("lyrics.load-deduplicated title=\(track.name)")
            return
        }
        lyricsTask?.cancel()
        lyricsLoadGeneration += 1
        let generation = lyricsLoadGeneration
        loadingTrackKey = track.trackKey
        lines = []
        currentLineIndex = nil
        lyricTimer?.invalidate()
        display("正在获取歌词…")
        diagnostics.record("lyrics.loading title=\(track.name) bypass-cache=\(ignoringCache)")
        let expectedKey = track.trackKey
        lyricsTask = lyricsProvider.load(for: track, ignoringCache: ignoringCache) { [weak self] result in
            guard let self, self.lyricsLoadGeneration == generation else { return }
            self.loadingTrackKey = nil
            self.lyricsTask = nil
            guard self.snapshot?.trackKey == expectedKey else { return }
            switch result {
            case .success(let document):
                self.lines = LyricTimeline.adjusted(
                    document.parsedLines,
                    referenceDuration: document.referenceDuration,
                    playbackDuration: track.duration
                )
                self.loadedTrackKey = expectedKey
                if self.lines.allSatisfy({ $0.text.isEmpty }) {
                    self.diagnostics.record("lyrics.empty title=\(track.name)")
                    self.display("未找到同步歌词")
                } else {
                    self.diagnostics.record(
                        "lyrics.loaded title=\(track.name) provider=\(document.provider ?? "unknown") lines=\(self.lines.count)"
                    )
                    self.updateCurrentLyric()
                }
            case .failure(let error):
                self.lines = []
                self.diagnostics.record("lyrics.failed title=\(track.name) error=\(error.localizedDescription)")
                self.display("未找到同步歌词")
            }
        }
    }

    private func estimatedPosition() -> TimeInterval {
        let elapsed = snapshot?.isPlaying == true
            ? max(0, ProcessInfo.processInfo.systemUptime - anchorUptime)
            : 0
        return anchorPosition + elapsed + settings.syncOffset
    }

    private func updateCurrentLyric() {
        lyricTimer?.invalidate()
        guard !lines.isEmpty else { return }
        let position = estimatedPosition()
        let index = LRCParser.currentIndex(in: lines, at: position)

        if index != currentLineIndex {
            currentLineIndex = index
            if let index {
                display(lines[index].text.isEmpty ? "♪" : lines[index].text)
            } else if let track = snapshot {
                display("♪ \(track.name)")
            }
        }

        guard snapshot?.isPlaying == true else { return }
        let nextIndex = (index ?? -1) + 1
        guard lines.indices.contains(nextIndex) else { return }
        let delay = max(0.03, lines[nextIndex].time - position)
        let expectedUptime = ProcessInfo.processInfo.systemUptime + delay
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            let lateness = ProcessInfo.processInfo.systemUptime - expectedUptime
            if lateness >= 0.25 {
                self?.diagnostics.record(String(format: "timer.late seconds=%.3f", lateness))
            }
            self?.updateCurrentLyric()
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        lyricTimer = timer
    }

    private func display(_ text: String) {
        displayedText = text
        renderCurrentText()
    }

    private func renderCurrentText() {
        guard !displayedText.isEmpty else { return }
        let statusWindow = statusItem.button?.window
        let maximumWidth = reservedStatusWidth ?? MenuBarLayout.lyricWidthLimit(
            itemRightEdge: statusWindow?.frame.maxX,
            safeRegionMinX: statusWindow?.screen?.auxiliaryTopRightArea?.minX
        )
        reservedStatusWidth = maximumWidth
        let fitted = AttributedLyricFormatter.fit(
            displayedText,
            chineseFont: settings.chineseFont,
            latinFont: settings.latinFont,
            preferredSize: settings.fontSize,
            maximumWidth: maximumWidth
        )
        statusItem.length = maximumWidth
        statusItem.button?.attributedTitle = fitted.attributedText
        statusItem.button?.toolTip = displayedText
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            case .notRegistered, .notFound:
                try service.register()
            @unknown default:
                return
            }
        } catch {
            diagnostics.record("login-item.failed error=\(error.localizedDescription)")
            SMAppService.openSystemSettingsLoginItems()
        }
        updateLaunchAtLoginMenuItem()
    }

    private func updateLaunchAtLoginMenuItem() {
        let status = SMAppService.mainApp.status
        launchAtLoginMenuItem.state = status == .enabled ? .on : .off
        launchAtLoginMenuItem.title = status == .requiresApproval
            ? "登录时自动启动（需批准）"
            : "登录时自动启动"
    }

    @objc private func reloadLyrics() {
        guard let snapshot, snapshot.hasTrack else {
            refreshFromMusic(forceLyrics: true)
            return
        }
        loadLyrics(for: snapshot, ignoringCache: true)
    }

    @objc private func copyDiagnostics() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(diagnostics.report, forType: .string)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
