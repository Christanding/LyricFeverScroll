import Foundation

struct MediaRemotePlaybackEvent {
    let position: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let title: String
    let artist: String
    let album: String
}

struct RetryBackoff {
    private var delay: TimeInterval = 1

    mutating func nextDelay() -> TimeInterval {
        defer { delay = min(delay * 2, 30) }
        return delay
    }

    mutating func reset() {
        delay = 1
    }
}

final class MediaRemotePositionStream {
    typealias Handler = (MediaRemotePlaybackEvent) -> Void

    private var process: Process?
    private var outputPipe: Pipe?
    private var buffer = Data()
    private var shouldRun = false
    private var handler: Handler?
    private var retryBackoff = RetryBackoff()
    private var restartWorkItem: DispatchWorkItem?

    func start(handler: @escaping Handler) {
        self.handler = handler
        retryBackoff.reset()
        shouldRun = true
        launch()
    }

    func stop() {
        shouldRun = false
        restartWorkItem?.cancel()
        restartWorkItem = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        outputPipe = nil
        buffer.removeAll(keepingCapacity: false)
    }

    private func launch() {
        guard shouldRun, process == nil else { return }
        let contents = Bundle.main.bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let script = contents.appendingPathComponent("Resources/MediaRemoteAdapter/run.pl")
        let library = contents.appendingPathComponent(
            "Frameworks/MediaRemoteAdapter.framework/MediaRemoteAdapter"
        )
        guard FileManager.default.isReadableFile(atPath: script.path),
              FileManager.default.isReadableFile(atPath: library.path) else { return }

        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = [
            script.path,
            "--id", "com.apple.Music",
            library.path,
            "loop"
        ]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.outputPipe = nil
                self.buffer.removeAll(keepingCapacity: false)
                self.scheduleRestart()
            }
        }

        do {
            try task.run()
            process = task
            outputPipe = pipe
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            scheduleRestart()
        }
    }

    private func scheduleRestart() {
        guard shouldRun, restartWorkItem == nil else { return }
        let delay = retryBackoff.nextDelay()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWorkItem = nil
            self.launch()
        }
        restartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        let newline = Data([0x0A])
        while let range = buffer.range(of: newline) {
            let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            if let event = Self.decode(line) {
                DispatchQueue.main.async { [weak self] in
                    self?.retryBackoff.reset()
                    self?.handler?(event)
                }
            }
        }
    }

    private static func decode(_ data: Data) -> MediaRemotePlaybackEvent? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let payload = root["payload"] as? [String: Any],
            let elapsedMicros = (payload["elapsedTimeMicros"] as? NSNumber)?.doubleValue,
            let timestampMicros = (payload["timestampEpochMicros"] as? NSNumber)?.doubleValue
        else { return nil }

        let isPlaying = (payload["isPlaying"] as? NSNumber)?.boolValue ?? false
        let rate = (payload["playbackRate"] as? NSNumber)?.doubleValue ?? (isPlaying ? 1 : 0)
        let elapsed = elapsedMicros / 1_000_000
        let timestamp = timestampMicros / 1_000_000
        let position = elapsed + max(0, Date().timeIntervalSince1970 - timestamp) * rate
        return MediaRemotePlaybackEvent(
            position: position,
            duration: ((payload["durationMicros"] as? NSNumber)?.doubleValue ?? 0) / 1_000_000,
            isPlaying: isPlaying,
            title: payload["title"] as? String ?? "",
            artist: payload["artist"] as? String ?? "",
            album: payload["album"] as? String ?? ""
        )
    }
}
