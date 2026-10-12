import Foundation
import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics
import ScreenCaptureKit
import PDFKit
import UniformTypeIdentifiers

@MainActor
final class CopilotViewModel: ObservableObject {
    @Published var transcript: [TranscriptSegment] = []
    @Published var liveInterviewer: String = ""
    @Published var liveMe: String = ""
    @Published var suggestion: String = ""
    @Published var status: String = "Idle"
    @Published var isRunning = false
    // Free-form job/role notes (persisted).
    @Published var jobContext: String =
        UserDefaults.standard.string(forKey: "jobContext") ?? "" {
        didSet { UserDefaults.standard.set(jobContext, forKey: "jobContext") }
    }
    // Your résumé / background (persisted). Used only when a question calls for
    // it, so answers aren't forced to reference your résumé every time.
    @Published var profile: String =
        UserDefaults.standard.string(forKey: "profile") ?? "" {
        didSet { UserDefaults.standard.set(profile, forKey: "profile") }
    }
    @Published var answerStyle: AnswerStyle = .concise
    /// When on, a finalized interviewer question auto-fires an answer (uses your
    /// API key). Off = the key is used only when you click Answer/Screen. Either
    /// way, everything said still goes into session memory. Persisted.
    @Published var autoAnswer: Bool =
        (UserDefaults.standard.object(forKey: "autoAnswer") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoAnswer, forKey: "autoAnswer") }
    }
    /// How many API answer-requests this session (visible in the overlay).
    @Published var apiCalls = 0
    /// Flips true once system audio is actually flowing (capture works).
    @Published var audioHeard = false
    /// Mirror of settings.transcribeMic, editable live from the overlay.
    @Published var micEnabled = true
    /// Compact overlay mode — hides transcript, shows only answer + ask bar.
    @Published var compactMode = false
    /// Overlay opacity (0.15 = very transparent, 1.0 = fully opaque).
    @Published var overlayOpacity: Double =
        UserDefaults.standard.object(forKey: "overlayOpacity") as? Double ?? 0.82 {
        didSet { UserDefaults.standard.set(overlayOpacity, forKey: "overlayOpacity") }
    }
    /// Text typed into the "Ask a question" bar.
    @Published var questionText = ""
    /// Deeper reasoning before answering: DeepSeek thinking mode, or medium
    /// reasoning effort on GPT-5.x (off = fastest). Persisted.
    @Published var deepThink: Bool =
        (UserDefaults.standard.object(forKey: "deepThink") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(deepThink, forKey: "deepThink") }
    }
    /// The last couple of answers (newest first), so a new answer doesn't
    /// lose the one before it. `viewingPrevious` is an index into it while
    /// you're looking back; nil = showing the current answer.
    @Published private(set) var previousAnswers: [String] = []
    @Published private(set) var viewingPrevious: Int?
    private let keepPreviousAnswers = 2

    /// True from sending a request until its first words arrive, so the
    /// overlay can say "Thinking…" instead of looking idle.
    @Published var waitingForAnswer = false
    /// When off, the résumé/background is NOT sent — answers won't reference it.
    @Published var useResume: Bool =
        (UserDefaults.standard.object(forKey: "useResume") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(useResume, forKey: "useResume") }
    }

    /// This session's full timeline (both sides of the conversation, captured
    /// screen text, typed questions, answers), sent with every request.
    /// Persisted so a relaunch mid-meeting keeps it; cleared by New session.
    @Published private(set) var memory = SessionStore.load() {
        didSet { SessionStore.save(memory) }
    }

    /// Scrolling screenshot in progress (overlay shows Done / Cancel).
    @Published var scrollCapturing = false
    @Published var scrollFrames = 0

    /// Caps on what memory stores (the prompt applies its own budget).
    private let memoryScreenChars = 12_000
    private let memoryMaxEvents = 3_000

    private let capture = AudioCapture()
    private var interviewerEngine: SpeechEngine
    private var meEngine: SpeechEngine
    private let settings: AppSettings
    private var provider: AIProvider = EchoProvider()
    private var suggestionTask: Task<Void, Never>?
    private let regionPicker = RegionPicker()
    private var scrollSession: ScrollCaptureSession?

    init(settings: AppSettings) {
        self.settings = settings
        // Temporary engines; rebuilt from settings in makeEngines() below.
        interviewerEngine = Transcriber(name: "interviewer")
        meEngine = Transcriber(name: "me")
        micEnabled = settings.transcribeMic
        rebuildProvider()
        makeEngines()

        capture.onSystemAudio = { [weak self] buf in
            self?.interviewerEngine.append(buf)
        }
        capture.onMicAudio = { [weak self] buf in
            self?.meEngine.append(buf)
        }
        capture.onFirstSystemBuffer = { [weak self] in
            Task { @MainActor in
                self?.audioHeard = true
                self?.status = "Listening — audio ✓ (hidden from screen share)"
            }
        }
    }

    /// (Re)create the two speech engines from current settings and wire their
    /// callbacks. Called on init and before each Start, so a Settings change
    /// takes effect on the next Start.
    private func makeEngines() {
        interviewerEngine.stop()
        meEngine.stop()

        func make(_ name: String) -> SpeechEngine {
            if settings.transcription == .deepgram,
               !settings.trimmedDeepgramKey.isEmpty {
                return DeepgramEngine(apiKey: settings.trimmedDeepgramKey, name: name)
            }
            return Transcriber(name: name)
        }

        let iv = make("interviewer")
        iv.onResult = { [weak self] text, isFinal in
            Task { @MainActor in self?.handleInterviewer(text, isFinal: isFinal) }
        }
        iv.onError = { [weak self] msg in
            Task { @MainActor in self?.status = msg }
        }
        interviewerEngine = iv

        let me = make("me")
        me.onResult = { [weak self] text, isFinal in
            Task { @MainActor in self?.handleMe(text, isFinal: isFinal) }
        }
        me.onError = { [weak self] msg in
            Task { @MainActor in self?.status = msg }
        }
        meEngine = me
    }

    func toggle() {
        if isRunning { stop() } else { Task { await start() } }
    }

    /// Turn mic transcription on/off from the overlay — applies live if running.
    func setMic(_ on: Bool) {
        micEnabled = on
        settings.transcribeMic = on
        guard isRunning else { return }
        if on {
            meEngine.start()
            try? capture.startMic()
        } else {
            capture.stopMic()
            meEngine.stop()
            liveMe = ""
        }
    }

    /// Rebuild the AI backend from the current settings. Call after the user
    /// saves Settings.
    func rebuildProvider() {
        if let p = makeProvider(settings.provider) {
            provider = p
            status = "Using \(settings.provider.label) · \(settings.currentModel)"
        } else {
            provider = EchoProvider()
            status = "No \(settings.provider.shortLabel) API key set — open Settings"
        }
    }

    private func makeProvider(_ kind: AppSettings.ProviderKind) -> AIProvider? {
        let key = settings.key(for: kind)
        guard !key.isEmpty else { return nil }
        let model = settings.model(for: kind)
        switch kind {
        case .openai: return OpenAIProvider(apiKey: key, model: model)
        case .anthropic: return AnthropicProvider(apiKey: key, model: model)
        case .gemini: return GeminiProvider(apiKey: key, model: model)
        case .deepseek: return DeepSeekProvider(apiKey: key, model: model)
        }
    }

    // MARK: Provider switching (overlay)

    var providerKind: AppSettings.ProviderKind { settings.provider }
    var screenChoice: AppSettings.ScreenProvider { settings.screenProvider }

    /// Switch the answering AI from the overlay. Session memory carries over.
    func setProvider(_ kind: AppSettings.ProviderKind) {
        settings.provider = kind
        rebuildProvider()
    }

    func setScreenChoice(_ choice: AppSettings.ScreenProvider) {
        settings.screenProvider = choice
        let kind = screenProviderKind
        status = "Screen / Scroll → \(kind.shortLabel) · \(settings.model(for: kind))"
    }

    func hasKey(_ kind: AppSettings.ProviderKind) -> Bool { !settings.key(for: kind).isEmpty }
    func modelName(_ kind: AppSettings.ProviderKind) -> String { settings.model(for: kind) }

    /// What Auto resolves to: the answer provider, or GPT when that's DeepSeek
    /// (DeepSeek can't read images).
    var autoScreenKind: AppSettings.ProviderKind {
        settings.provider == .deepseek ? .openai : settings.provider
    }

    /// The AI that reads Screen / Scroll captures.
    var screenProviderKind: AppSettings.ProviderKind {
        settings.screenProvider.kind ?? autoScreenKind
    }

    /// True once Screen Recording is granted. Published so the UI can show a
    /// "grant + relaunch" prompt.
    @Published var needsScreenPermission = false

    func start() async {
        status = "Requesting permissions…"
        guard await Transcriber.requestAuthorization() else {
            status = "Speech recognition denied. Enable it in System Settings › Privacy."
            return
        }

        // Don't gate on CGPreflightScreenCaptureAccess() — it reports false
        // negatives for menu-bar apps on macOS 15. Just try to capture; the
        // ScreenCaptureKit call itself throws a specific error if we truly
        // lack Screen Recording permission.
        do {
            audioHeard = false
            makeEngines()               // pick up any transcription setting change
            interviewerEngine.start()
            try await capture.startSystemAudio()
            // Only listen to your mic if enabled (off = interviewer-only, ~half
            // the Deepgram cost, and it doesn't listen to you at all).
            if settings.transcribeMic {
                meEngine.start()
                try capture.startMic()
            }
            isRunning = true
            needsScreenPermission = false
            status = "Listening — waiting for audio…"
        } catch {
            NSLog("start() failed: \(error) [\((error as NSError).domain) " +
                  "\((error as NSError).code)]")
            stop()
            if Self.isScreenPermissionError(error) {
                _ = CGRequestScreenCaptureAccess() // adds us to the list / prompts
                needsScreenPermission = true
                status = "Screen Recording not active for this build. Grant it, " +
                    "then menu bar ▸ Relaunch app."
                openScreenRecordingSettings()
            } else {
                status = "Failed to start: \(error.localizedDescription)"
            }
        }
    }

    /// True when the error is ScreenCaptureKit refusing for lack of permission
    /// (SCStreamError `userDeclined` == -3801), vs. any other failure.
    private static func isScreenPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.code == -3801 { return true }
        if ns.domain.localizedCaseInsensitiveContains("ScreenCaptureKit") { return true }
        return false
    }

    func openScreenRecordingSettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func stop() {
        suggestionTask?.cancel()
        waitingForAnswer = false
        Task { await capture.stopSystemAudio() }
        capture.stopMic()
        interviewerEngine.stop()
        meEngine.stop()
        isRunning = false
        status = "Stopped"
    }

    // MARK: Transcript handling

    private func handleInterviewer(_ text: String, isFinal: Bool) {
        liveInterviewer = text
        guard isFinal, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        transcript.append(.init(speaker: .interviewer, text: text))
        record(.interviewer, text)
        liveInterviewer = ""
        // A finalized interviewer utterance is our cue to answer — but only if
        // auto-answer is on (otherwise nothing hits your API key automatically).
        if autoAnswer { requestSuggestion() }
    }

    private func handleMe(_ text: String, isFinal: Bool) {
        liveMe = text
        guard isFinal, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        transcript.append(.init(speaker: .me, text: text))
        record(.me, text)
        liveMe = ""
    }

    /// Manually re-request an answer (hotkey / Answer / Regenerate button).
    func requestSuggestion() { runSuggestion(screenshots: []) }

    /// Capture the current screen and answer what's shown on it (coding tasks,
    /// MCQs, shared docs). Bound to ⌥⌘S and the "Screen" button.
    func answerFromScreen() {
        suggestionTask?.cancel()
        startNewAnswer()
        status = "Reading screen…"
        suggestionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let png = try await ScreenGrabber.capturePNG()
                await MainActor.run { self.status = self.runningStatus() }
                await self.stream(screenshots: [png])
            } catch {
                await MainActor.run {
                    self.suggestion = "⚠️ Couldn't read screen: " +
                        "\(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Scrolling screenshot

    /// ⌃⌥L / the Scroll button: first press picks a region and starts
    /// capturing, second press finishes and sends the frames.
    func toggleScrollCapture() {
        if scrollCapturing { finishScrollCapture() } else { startScrollCapture() }
    }

    func startScrollCapture() {
        guard scrollSession == nil else { return }
        status = "Drag over the region to capture (Esc to cancel)"
        Task {
            guard let region = await regionPicker.pick() else {
                status = runningStatus()
                return
            }
            let session = ScrollCaptureSession(region: region)
            session.onFrame = { [weak self] n in
                self?.scrollFrames = n
                self?.status = "Scroll capture: \(n)/\(ScrollCaptureSession.maxFrames) " +
                    "frames — ⌃⌥L when done"
            }
            session.onAutoFinish = { [weak self] in self?.finishScrollCapture() }
            scrollSession = session
            scrollFrames = 0
            scrollCapturing = true
            status = "Scroll the region slowly, pausing briefly — ⌃⌥L when done"
            session.start()
        }
    }

    func finishScrollCapture() {
        guard let session = scrollSession else { return }
        let frames = session.stop()
        scrollSession = nil
        scrollCapturing = false
        guard !frames.isEmpty else {
            status = "Scroll capture got no frames — try again"
            return
        }
        status = "Read \(frames.count) frame(s) — answering…"
        runSuggestion(screenshots: frames)
    }

    func cancelScrollCapture() {
        _ = scrollSession?.stop()
        scrollSession = nil
        scrollCapturing = false
        status = runningStatus()
    }

    private func runSuggestion(screenshots: [Data]) {
        suggestionTask?.cancel()
        startNewAnswer()
        suggestionTask = Task { [weak self] in
            await self?.stream(screenshots: screenshots)
        }
    }

    private func stream(screenshots: [Data]) async {
        if !memory.hasInterviewerSpeech && screenshots.isEmpty {
            suggestion = "No question captured yet. Start listening and wait " +
                "for cyan Q: lines to appear, or use Screen for an " +
                "on-screen question."
            return
        }
        let ctx = combinedContext()
        let style = answerStyle
        let think = deepThink
        let mem = memory                  // timeline as of this request
        let sessionID = memory.id

        // Captures go to the chosen Screen AI (DeepSeek can't read images).
        var activeProvider = provider
        if !screenshots.isEmpty {
            let kind = screenProviderKind
            if kind != settings.provider {
                guard let p = makeProvider(kind) else {
                    suggestion = "Screen / Scroll answers use \(kind.shortLabel), but " +
                        "no \(kind.shortLabel) key is set. Add it in Settings or " +
                        "pick another Screen AI in the overlay."
                    return
                }
                activeProvider = p
                status = "Screen → \(kind.shortLabel) · \(settings.model(for: kind))"
            }
        }
        apiCalls += 1

        // Put the capture in the timeline now (so it sits before its answer),
        // and fill in its text once on-device OCR finishes. This runs even if
        // the answer is cancelled or fails, so follow-ups can still refer to it.
        if !screenshots.isEmpty {
            let captureID = record(.screen, "(reading screen text…)")
            Task { [weak self] in
                let text = await Task.detached(priority: .utility) {
                    ScreenOCR.text(from: screenshots)
                }.value
                self?.fillScreenText(captureID, text, session: sessionID)
            }
        }

        waitingForAnswer = true
        defer { if !Task.isCancelled { waitingForAnswer = false } }
        do {
            for try await delta in activeProvider.streamSuggestion(
                question: nil, jobContext: ctx,
                screenshots: screenshots, memory: mem, style: style, thinking: think) {
                if Task.isCancelled { return }
                waitingForAnswer = false
                suggestion += delta
            }
            if !Task.isCancelled { record(.answer, suggestion) }
        } catch {
            suggestion = "⚠️ \(error.localizedDescription)"
        }
    }

    /// Combine job notes + résumé into the context we send. Either can be empty.
    private func combinedContext() -> String {
        var parts: [String] = []
        let job = jobContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let prof = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !job.isEmpty { parts.append("Role / job notes:\n\(job)") }
        // Only include the résumé when the user has enabled it.
        if useResume && !prof.isEmpty {
            parts.append("Candidate résumé / background:\n\(prof)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Load a résumé file (PDF or text) into the profile field.
    func loadResumeFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf, .plainText, .text, .rtf]
        panel.level = .modalPanel
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let text = Self.extractText(from: url), !text.isEmpty {
            profile = text
            status = "Loaded résumé from \(url.lastPathComponent) " +
                "(\(text.count) chars)"
        } else {
            status = "Couldn't read text from \(url.lastPathComponent)."
        }
    }

    private static func extractText(from url: URL) -> String? {
        if url.pathExtension.lowercased() == "pdf" {
            return PDFDocument(url: url)?.string
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Ask a question

    /// Send a typed question to the AI.
    func askQuestion() {
        let q = questionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        questionText = ""
        askDirect(question: q, typed: true)
    }

    /// Grab your last spoken "Me:" lines and send as a question.
    func askLast() {
        var parts: [String] = []
        for seg in transcript.reversed() {
            if seg.speaker == .me {
                parts.insert(seg.text, at: 0)
                if parts.count >= 3 { break }
            } else {
                if !parts.isEmpty { break }
            }
        }
        let live = liveMe.trimmingCharacters(in: .whitespacesAndNewlines)
        if !live.isEmpty { parts.append(live) }

        let q = parts.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            suggestion = "Nothing captured from your mic yet. " +
                "Make sure Mic is on and say your question, then tap Ask Last."
            return
        }
        // Your spoken lines are already in the timeline, so don't record the
        // question again.
        askDirect(question: q, typed: false)
    }

    private func askDirect(question: String, typed: Bool) {
        suggestionTask?.cancel()
        startNewAnswer()
        apiCalls += 1
        let mem = memory                  // timeline before this question
        if typed { record(.asked, question) }
        suggestionTask = Task { [weak self] in
            guard let self else { return }
            let ctx = self.combinedContext()
            let style = self.answerStyle
            let think = self.deepThink
            self.waitingForAnswer = true
            defer { if !Task.isCancelled { self.waitingForAnswer = false } }
            do {
                for try await delta in self.provider.streamSuggestion(
                    question: question, jobContext: ctx, screenshots: [],
                    memory: mem, style: style, thinking: think) {
                    if Task.isCancelled { return }
                    self.waitingForAnswer = false
                    self.suggestion += delta
                }
                if !Task.isCancelled { self.record(.answer, self.suggestion) }
            } catch {
                self.suggestion = "⚠️ \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Session memory

    /// Start fresh for a new meeting: clears the session timeline (conversation,
    /// captured screen text, answers), the transcript, and the API counter. Your résumé and job
    /// notes are kept (edit them under Context for each meeting).
    func newSession() {
        suggestionTask?.cancel()          // an in-flight answer won't be saved
        if scrollCapturing { cancelScrollCapture() }
        memory = SessionMemory()
        transcript = []
        liveInterviewer = ""
        liveMe = ""
        suggestion = ""
        previousAnswers = []
        viewingPrevious = nil
        waitingForAnswer = false
        apiCalls = 0
        status = "New session — memory and transcript cleared"
    }

    /// Append to the session timeline. Returns the event's id.
    @discardableResult
    private func record(_ kind: SessionMemory.Event.Kind, _ text: String) -> UUID {
        let event = SessionMemory.Event(
            kind: kind, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !event.text.isEmpty else { return event.id }
        memory.events.append(event)
        if memory.events.count > memoryMaxEvents {
            memory.events.removeFirst(memory.events.count - memoryMaxEvents)
        }
        return event.id
    }

    /// Fill in a capture's OCR text — unless a New session started meanwhile.
    private func fillScreenText(_ id: UUID, _ text: String, session: UUID) {
        guard memory.id == session,
              let i = memory.events.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        memory.events[i].text = trimmed.isEmpty
            ? "(no readable text on the captured screen)"
            : String(trimmed.prefix(memoryScreenChars))
    }

    // MARK: - Previous answers

    /// Before a new answer starts: keep the current one in the history and
    /// jump back to showing the latest.
    private func startNewAnswer() {
        let current = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty, !current.hasPrefix("⚠️") {
            previousAnswers.insert(suggestion, at: 0)
            if previousAnswers.count > keepPreviousAnswers {
                previousAnswers.removeLast(previousAnswers.count - keepPreviousAnswers)
            }
        }
        suggestion = ""
        viewingPrevious = nil
    }

    /// The answer the overlay shows: the current one, or a previous one.
    var displayedAnswer: String {
        if let i = viewingPrevious, previousAnswers.indices.contains(i) {
            return previousAnswers[i]
        }
        return suggestion
    }

    /// Step back to an older answer (⌃⌥[).
    func showOlderAnswer() {
        let next = (viewingPrevious ?? -1) + 1
        if previousAnswers.indices.contains(next) { viewingPrevious = next }
    }

    /// Step forward toward the current answer (⌃⌥]).
    func showNewerAnswer() {
        guard let i = viewingPrevious else { return }
        viewingPrevious = i == 0 ? nil : i - 1
    }

    private func runningStatus() -> String {
        isRunning ? "Listening — hidden from screen share"
                  : "Using \(settings.provider.label) · \(settings.currentModel)"
    }
}
