import Foundation
import AVFoundation

/// Streaming speech-to-text via Deepgram's realtime WebSocket API. Much more
/// accurate than Apple's recognizer for interview audio. Feeds 16 kHz mono
/// linear16 PCM and receives interim + final transcripts.
///
/// The socket is kept alive with periodic KeepAlive frames, and an *unexpected*
/// drop (Wi-Fi blip, server timeout) is recovered automatically with backoff —
/// so a momentary network glitch mid-interview doesn't silently stop
/// transcription. An intentional `stop()` is never reconnected.
final class DeepgramEngine: NSObject, SpeechEngine, @unchecked Sendable {
    var onResult: ((String, Bool) -> Void)?
    var onError: ((String) -> Void)?

    private let apiKey: String
    private let name: String
    private let model: String
    private lazy var session = URLSession(configuration: .default)

    /// All mutable state below is confined to this serial queue, because
    /// URLSession's WebSocket callbacks arrive on an arbitrary background queue.
    private let queue: DispatchQueue
    private var task: URLSessionWebSocketTask?
    private var isStopping = false
    private var reconnectAttempts = 0
    private var keepAlive: DispatchSourceTimer?

    /// Finalized segments of the current utterance (Deepgram sends them
    /// incrementally; we join them for a clean live + final transcript). Kept
    /// across a reconnect so an in-progress sentence isn't lost.
    private var utterance = ""

    // Reconnect policy.
    private let maxReconnectAttempts = 10
    private let baseReconnectDelay: TimeInterval = 1       // 1s, 2s, 4s …
    private let maxReconnectDelay: TimeInterval = 30
    private let keepAliveInterval: TimeInterval = 4

    init(apiKey: String, name: String, model: String = "nova-3") {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = name
        self.model = model
        self.queue = DispatchQueue(label: "deepgram.\(name)")
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStopping = false
            self.reconnectAttempts = 0
            self.utterance = ""
            self.openConnection(reason: "initial")
        }
    }

    // MARK: - Connection lifecycle (queue-confined)

    private func openConnection(reason: String) {
        var comps = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        comps.queryItems = [
            .init(name: "model", value: model),
            .init(name: "encoding", value: "linear16"),
            .init(name: "sample_rate", value: "16000"),
            .init(name: "channels", value: "1"),
            .init(name: "interim_results", value: "true"),
            .init(name: "punctuate", value: "true"),
            .init(name: "smart_format", value: "true"),
            .init(name: "endpointing", value: "300"),
        ]
        guard let url = comps.url else {
            onError?("Deepgram: bad URL"); return
        }
        var req = URLRequest(url: url)
        req.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let t = session.webSocketTask(with: req)
        task = t
        t.resume()
        NSLog("[\(name)] Deepgram socket opening (\(reason))")
        startKeepAlive()
        receive(on: t)
    }

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                // Ignore callbacks from a socket we've already replaced/closed.
                guard self.task === t else { return }
                switch result {
                case .failure(let error):
                    let ns = error as NSError
                    // Cancelled on stop() / reconnect teardown is expected.
                    if ns.code == NSURLErrorCancelled || self.isStopping { return }
                    NSLog("[\(self.name)] Deepgram recv error: \(ns.code) \(ns.localizedDescription)")
                    self.scheduleReconnect(because: ns.localizedDescription)
                case .success(let message):
                    // Data is flowing: this connection is healthy.
                    self.reconnectAttempts = 0
                    switch message {
                    case .string(let s): self.handle(s)
                    case .data(let d):
                        if let s = String(data: d, encoding: .utf8) { self.handle(s) }
                    @unknown default: break
                    }
                    self.receive(on: t)   // keep listening
                }
            }
        }
    }

    /// Tear down the current socket and, unless we're stopping or out of tries,
    /// reopen after an exponential backoff.
    private func scheduleReconnect(because reason: String) {
        stopKeepAlive()
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        guard !isStopping else { return }

        guard reconnectAttempts < maxReconnectAttempts else {
            NSLog("[\(name)] Deepgram giving up after \(maxReconnectAttempts) reconnects")
            onError?("Deepgram: connection lost — \(reason). Press Stop then Start to retry.")
            return
        }
        reconnectAttempts += 1
        let delay = min(maxReconnectDelay,
                        baseReconnectDelay * pow(2, Double(reconnectAttempts - 1)))
        NSLog("[\(name)] Deepgram reconnecting in \(delay)s (attempt \(reconnectAttempts)/\(maxReconnectAttempts))")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isStopping, self.task == nil else { return }
            self.openConnection(reason: "reconnect \(self.reconnectAttempts)")
        }
    }

    private func startKeepAlive() {
        stopKeepAlive()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + keepAliveInterval, repeating: keepAliveInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let t = self.task, !self.isStopping else { return }
            t.send(.string("{\"type\":\"KeepAlive\"}")) { _ in }
        }
        timer.resume()
        keepAlive = timer
    }

    private func stopKeepAlive() {
        keepAlive?.cancel()
        keepAlive = nil
    }

    // MARK: - Transcript parsing

    private func handle(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else { return }

        if let err = obj["error"] as? String ??
            (obj["error"] as? [String: Any])?["message"] as? String {
            onError?("Deepgram: \(err)")
            return
        }

        guard let channel = obj["channel"] as? [String: Any],
              let alts = channel["alternatives"] as? [[String: Any]],
              let text = alts.first?["transcript"] as? String,
              !text.isEmpty else { return }

        let isFinal = (obj["is_final"] as? Bool) ?? false
        let speechFinal = (obj["speech_final"] as? Bool) ?? false

        if speechFinal {
            // End of utterance → emit the whole thing as final and reset.
            let full = (utterance + " " + text).trimmingCharacters(in: .whitespaces)
            utterance = ""
            onResult?(full, true)
        } else if isFinal {
            // A finalized segment mid-utterance → accumulate, show as live.
            utterance = (utterance + " " + text).trimmingCharacters(in: .whitespaces)
            onResult?(utterance, false)
        } else {
            // Interim words → live display over the accumulated final segments.
            let live = (utterance + " " + text).trimmingCharacters(in: .whitespaces)
            onResult?(live, false)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        // Convert 16 kHz mono float32 → little-endian Int16 PCM bytes.
        guard let ch = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        let src = ch[0]
        var pcm = Data(count: n * 2)
        pcm.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: Int16.self)
            for i in 0..<n {
                let v = max(-1.0, min(1.0, src[i]))
                dst[i] = Int16(v * 32767).littleEndian
            }
        }
        let frame = pcm   // immutable copy for the concurrent send
        queue.async { [weak self] in
            // While reconnecting there's no socket; drop the chunk rather than
            // crash. A few hundred ms of audio is lost, not the whole session.
            self?.task?.send(.data(frame)) { error in
                if let error { NSLog("Deepgram send error: \(error.localizedDescription)") }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStopping = true
            self.stopKeepAlive()
            if let t = self.task {
                // Tell Deepgram to flush + close, then tear down.
                t.send(.string("{\"type\":\"CloseStream\"}")) { _ in }
                t.cancel(with: .goingAway, reason: nil)
            }
            self.task = nil
            self.utterance = ""
        }
    }
}
