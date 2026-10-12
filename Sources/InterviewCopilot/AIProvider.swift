import Foundation

/// A single turn of the interview transcript that we send to the model.
struct TranscriptSegment: Sendable {
    enum Speaker: String, Sendable {
        case interviewer   // captured from system audio (the other person)
        case me            // captured from the microphone
    }
    let speaker: Speaker
    let text: String
}

/// The whole session (one meeting) as a timeline: everything the interviewer
/// and you said, the text of every screen capture, every question you typed,
/// and every answer — whether or not Auto answered it. Answers are grounded in
/// what actually happened instead of guessed. Kept until New session; saved to
/// disk so it survives a relaunch.
struct SessionMemory: Codable, Sendable {
    struct Event: Codable, Sendable {
        enum Kind: String, Codable, Sendable {
            case interviewer   // the interviewer's speech (system audio)
            case me            // your speech (mic)
            case asked         // a question you typed to the copilot
            case screen        // on-device OCR of a Screen / Scroll capture
            case answer        // the copilot's answer
        }
        var id = UUID()
        let kind: Kind
        var text: String
    }
    var id = UUID()
    /// Oldest first.
    var events: [Event] = []

    var isEmpty: Bool { events.isEmpty }
    var answerCount: Int { events.filter { $0.kind == .answer }.count }
    var hasInterviewerSpeech: Bool { events.contains { $0.kind == .interviewer } }
}

/// Swappable AI backend. Implement this to point the app at a different
/// provider, a proxy server, or a local model — the rest of the app only
/// depends on this protocol.
/// How the answer should be shaped.
enum AnswerStyle: String, CaseIterable, Identifiable, Sendable {
    case concise, detailed, star, code
    var id: String { rawValue }
    var label: String {
        switch self {
        case .concise: return "Concise"
        case .detailed: return "Detailed"
        case .star: return "STAR"
        case .code: return "Code"
        }
    }
    var instruction: String {
        switch self {
        case .concise:
            return "Keep it short: the bold one-line answer plus 2-3 bullets."
        case .detailed:
            return "Go deeper: the bold one-line answer plus 4-6 bullets, " +
                "including a concrete example or the reasoning behind it."
        case .star:
            return "This is likely a behavioral question. Use STAR as four " +
                "bullets — **Situation**, **Task**, **Action**, **Result** — one " +
                "short first-person line each, with the concrete details " +
                "(project, numbers, outcome) in bold."
        case .code:
            return "This is a technical/coding question. A bold one-line " +
                "approach, 2-4 bullets on the key idea and edge cases, then a " +
                "clean, correct solution in a fenced code block, then " +
                "**Time:** and **Space:** complexity on one line."
        }
    }
}

protocol AIProvider: Sendable {
    /// Stream a suggested answer — to `question` if given, otherwise to the
    /// interviewer's most recent question in the session timeline — given the
    /// session memory, optional on-screen images (one screen
    /// grab, or the ordered frames of a scrolling screenshot), and answer style.
    func streamSuggestion(
        question: String?,
        jobContext: String,
        screenshots: [Data],
        memory: SessionMemory,
        style: AnswerStyle,
        thinking: Bool
    ) -> AsyncThrowingStream<String, Error>
}

// MARK: - Shared prompt building

/// The system prompt is identical across providers — keep it in one place.
func copilotSystemPrompt(jobContext: String) -> String {
    """
    You are a real-time interview copilot. The user is in a live job \
    interview. You are given a timeline of the whole session so far (what the \
    interviewer and the user said, text from screen captures, and your \
    earlier answers), optionally a screenshot of the user's \
    screen (which may contain a coding task, a multiple-choice question, or a \
    shared document), plus optional context about the role and the user's \
    background.

    The user glances at your answer mid-conversation and says it in their own \
    words, so write glanceable talking points, not a script to read aloud:
    • First line: the core answer in one short sentence, in bold.
    • Then short bullets (about 12 words max). Start each with a **bold key \
    phrase** the user can build on, and bold the important terms \
    (technologies, numbers, names) so they stand out at a glance.
    • First person, natural words the user could actually say. No preamble, \
    no "here's what you could say", no headings, no long paragraphs.
    • Code goes in a fenced code block, with the explanation as bullets.
    If a screenshot is provided, answer what it shows (read code, questions, \
    or diagrams from it).

    Background you can draw on (role/job notes and the candidate's résumé):
    \(jobContext.isEmpty ? "(none provided)" : jobContext)

    Decide per question which mode to use:
    • If the question is about the candidate's projects, experience, or résumé \
    ("tell me about a project", "what did you build", "why you", "your \
    strengths", or it references something on the résumé) → ground the answer \
    in the résumé: name the specific project, the tech used, your role, and the \
    concrete outcome/impact. Vary which experience you cite across questions; \
    don't reuse the same project every time.
    • If the question is technical, conceptual, or a coding problem (how X \
    works, design/algorithm questions, "explain Y") → give a strong, correct, \
    well-structured expert answer that actually teaches the concept — clear \
    reasoning, the key idea, and a concrete example or code where useful. Do \
    NOT force the résumé in here; answer it as an expert would.

    When in doubt, prefer a genuinely helpful, accurate answer over name-dropping \
    the résumé.

    Ground rules — accuracy over invention:
    • Personal facts (employers, projects, titles, team sizes, metrics, dates, \
    tech used) must come from the background above or from what the user \
    actually said in this session. Never invent them. If nothing fits, give a \
    strong answer without made-up specifics.
    • Stay consistent with your earlier answers and what the user said this \
    session (same project details, same numbers, same code) unless asked to \
    change.
    • Only treat something as "said earlier" if it is in the session timeline.
    • The speech is transcribed automatically and may contain errors — infer \
    the most likely intended question and answer that.
    • Code must be correct and complete: handle edge cases and check the logic \
    before answering.
    """
}

/// The user message, split so providers can cache the session history (it
/// only grows) separately from this request's task.
struct CopilotPrompt: Sendable {
    let history: String
    let task: String
    var text: String { history.isEmpty ? task : history + "\n\n" + task }
}

func copilotUserPrompt(question: String?, style: AnswerStyle, screenshotCount: Int,
                       memory: SessionMemory) -> CopilotPrompt {
    let followUp = "If it follows up on something in the session timeline " +
        "(\"optimize it\", \"that problem\", \"the code\", \"go back to the first " +
        "one\"), build on that context."
    let task: String
    if screenshotCount > 1 {
        task = """
        \(screenshotCount) screenshots are attached, in order. They are a \
        scrolling capture of ONE region of my screen, top to bottom — together \
        they show a single long question, task, or document. Consecutive \
        screenshots may overlap; treat overlapping parts as the same content, \
        not repeated text. ANSWER WHAT THE SCREENSHOTS SHOW, reading them as \
        one continuous page. Use the session timeline only as background (e.g. \
        constraints the interviewer added out loud).
        """
    } else if screenshotCount == 1 {
        task = """
        A screenshot of my screen is attached. It contains the actual question \
        or task (e.g. a coding problem, a multiple-choice question, or a \
        document). ANSWER WHAT IS IN THE SCREENSHOT — read the code, question, \
        or prompt directly from the image. Use the session timeline only as \
        background (e.g. constraints the interviewer added out loud).
        """
    } else if let question {
        task = "My question now: \(question)\n\nAnswer it. \(followUp)"
    } else {
        task = "Answer the interviewer's most recent question (the last " +
            "INTERVIEWER line in the timeline). \(followUp)"
    }
    // The answer style goes last (not in the system prompt) so switching it
    // mid-session doesn't invalidate the providers' cached prefix.
    return CopilotPrompt(history: memory.isEmpty ? "" : sessionTimeline(memory),
                         task: task + "\n\nAnswer style: " + style.instruction)
}

/// How much history one request carries (~15k tokens). The newest events go
/// in full; past the budget, older events are condensed to just the questions
/// asked, so a long interview keeps cost and latency bounded.
private let historyBudgetChars = 60_000
private let condensedBudgetChars = 8_000
private let historyAnswerChars = 4_000

private func sessionTimeline(_ memory: SessionMemory) -> String {
    func clip(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n)) + " …[truncated]" : s
    }
    func line(_ e: SessionMemory.Event) -> String {
        switch e.kind {
        case .interviewer: return "INTERVIEWER: \(e.text)"
        case .me: return "ME: \(e.text)"
        case .asked: return "ME (typed to you, not said aloud): \(e.text)"
        case .screen: return "<screen_capture>\n\(e.text)\n</screen_capture>"
        case .answer: return "<your_answer>\n\(clip(e.text, historyAnswerChars))\n</your_answer>"
        }
    }

    var full: [String] = []
    var used = 0
    var firstFull = memory.events.count
    for i in memory.events.indices.reversed() {
        let l = line(memory.events[i])
        if used + l.count > historyBudgetChars, !full.isEmpty { break }
        full.insert(l, at: 0)
        used += l.count
        firstFull = i
    }

    var out = "<session_timeline>\nEverything so far in this interview session, " +
        "oldest first: what the interviewer and I said (speech-to-text, may " +
        "contain errors), text read from my screen captures, questions I typed " +
        "to you, and your earlier answers."
    if firstFull > 0 {
        var condensed: [String] = []
        var size = 0
        for e in memory.events[..<firstFull].reversed()
            where e.kind == .interviewer || e.kind == .asked {
            let l = "- " + clip(e.text, 200)
            if size + l.count > condensedBudgetChars { break }
            condensed.insert(l, at: 0)
            size += l.count
        }
        out += "\n\n(Earlier part of the session, condensed to the questions " +
            "asked:)\n" + condensed.joined(separator: "\n") +
            "\n\n(Full detail from here on:)"
    }
    return out + "\n\n" + full.joined(separator: "\n") + "\n</session_timeline>"
}

// MARK: - Anthropic implementation

/// Talks directly to the Claude Messages API with streaming.
///
/// The API key is read from `ANTHROPIC_API_KEY` (or set explicitly). If you'd
/// rather hide the key, implement a `ProxyProvider` that hits your own server
/// and swap it in `CopilotViewModel` — nothing else changes.
struct AnthropicProvider: AIProvider {
    var apiKey: String
    /// Fast model keeps latency low for live suggestions. Swap to
    /// `claude-opus-4-8` for maximum quality if latency is acceptable.
    var model: String = "claude-sonnet-4-6"
    /// The Messages API requires a cap. It's set high so long answers (full
    /// code solutions) never get cut off; you're only billed for what the
    /// model actually writes, and the answer style keeps short answers short.
    var maxTokens: Int = 64_000

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func streamSuggestion(
        question: String?,
        jobContext: String,
        screenshots: [Data],
        memory: SessionMemory,
        style: AnswerStyle,
        thinking: Bool
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(question: question, jobContext: jobContext,
                                  screenshots: screenshots, memory: memory, style: style,
                                  thinking: thinking, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        question: String?,
        jobContext: String,
        screenshots: [Data],
        memory: SessionMemory,
        style: AnswerStyle,
        thinking: Bool,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                         forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let system = copilotSystemPrompt(jobContext: jobContext)
        let prompt = copilotUserPrompt(question: question, style: style,
                                       screenshotCount: screenshots.count,
                                       memory: memory)

        // History first and cached: the timeline only grows, so each follow-up
        // re-reads the earlier part at a fraction of the price. Then any
        // screenshots, then this request's task.
        var content: [[String: Any]] = []
        if !prompt.history.isEmpty {
            content.append(["type": "text", "text": prompt.history,
                            "cache_control": ["type": "ephemeral"]])
        }
        for shot in screenshots {
            content.append(["type": "image", "source": [
                "type": "base64", "media_type": "image/png",
                "data": shot.base64EncodedString()]])
        }
        content.append(["type": "text", "text": prompt.task])

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": system,
            "messages": [
                ["role": "user", "content": content]
            ],
            // Think on = adaptive thinking at high effort (best for hard and
            // coding questions); off = low effort, fastest. Newer models (e.g.
            // Opus 5.5) always reason, so effort is the real control.
            "output_config": ["effort": thinking ? "high" : "low"]
        ]
        if thinking { body["thinking"] = ["type": "adaptive"] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var detail = ""
            for try await line in bytes.lines { detail += line }
            // Older models don't take effort / adaptive thinking — retry once
            // without them.
            guard http.statusCode == 400,
                  detail.contains("effort") || detail.contains("thinking") else {
                throw NSError(
                    domain: "AnthropicProvider", code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey:
                        "HTTP \(http.statusCode): \(detail)"])
            }
            body.removeValue(forKey: "output_config")
            body.removeValue(forKey: "thinking")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let retry = response as? HTTPURLResponse, retry.statusCode != 200 {
                detail = ""
                for try await line in bytes.lines { detail += line }
                throw NSError(
                    domain: "AnthropicProvider", code: retry.statusCode,
                    userInfo: [NSLocalizedDescriptionKey:
                        "HTTP \(retry.statusCode): \(detail)"])
            }
        }

        // Parse the SSE stream: lines like `data: {json}`.
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let json = line.dropFirst("data:".count)
                .trimmingCharacters(in: .whitespaces)
            guard let data = json.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }

            switch type {
            case "content_block_delta":
                if let delta = obj["delta"] as? [String: Any],
                   let text = delta["text"] as? String {
                    continuation.yield(text)
                }
            case "message_stop":
                continuation.finish()
                return
            case "error":
                let msg = (obj["error"] as? [String: Any])?["message"]
                    as? String ?? "unknown error"
                throw NSError(domain: "AnthropicProvider", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: msg])
            default:
                break
            }
        }
        continuation.finish()
    }
}

// MARK: - OpenAI implementation

/// Talks to the OpenAI Chat Completions API with streaming.
///
/// The API key is read from `OPENAI_API_KEY` or set via Settings. Same shape as
/// `AnthropicProvider` — pick whichever you have a key for.
struct OpenAIProvider: AIProvider {
    var apiKey: String
    /// Fast, cheap model keeps latency low for live suggestions. Swap to
    /// `gpt-4o` or another model in Settings for higher quality.
    var model: String = "gpt-4o-mini"

    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    func streamSuggestion(
        question: String?,
        jobContext: String,
        screenshots: [Data],
        memory: SessionMemory,
        style: AnswerStyle,
        thinking: Bool
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(question: question, jobContext: jobContext,
                                  screenshots: screenshots, memory: memory, style: style,
                                  thinking: thinking, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// GPT-5.x and o-series are reasoning models. Think on = "medium" (more
    /// accurate on hard / coding questions, a few seconds slower); off =
    /// "none" (fastest). Other models don't accept the parameter.
    private var isReasoningModel: Bool {
        let m = model.lowercased()
        return (m.hasPrefix("gpt-5") && !m.contains("chat"))
            || m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4")
    }

    private func run(
        question: String?,
        jobContext: String,
        screenshots: [Data],
        memory: SessionMemory,
        style: AnswerStyle,
        thinking: Bool,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        // No output cap: the model's own maximum applies, so long code answers
        // aren't cut off (reasoning models also spend part of any cap on hidden
        // reasoning). Newer models only accept the default temperature, so we
        // don't send one.
        var userContent: [[String: Any]] =
            [["type": "text", "text": copilotUserPrompt(question: question, style: style, screenshotCount: screenshots.count, memory: memory).text]]
        for shot in screenshots {
            userContent.append(["type": "image_url", "image_url":
                ["url": "data:image/png;base64,\(shot.base64EncodedString())"]])
        }

        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": [
                ["role": "system",
                 "content": copilotSystemPrompt(jobContext: jobContext)],
                ["role": "user", "content": userContent]
            ]
        ]
        if isReasoningModel {
            body["reasoning_effort"] = thinking ? "medium" : "none"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var detail = ""
            for try await line in bytes.lines { detail += line }
            // Not every reasoning model accepts every effort level (e.g. older
            // ones lack "none") — retry once with the model's default.
            if http.statusCode == 400, body["reasoning_effort"] != nil,
               detail.contains("reasoning_effort") {
                body.removeValue(forKey: "reasoning_effort")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                (bytes, response) = try await URLSession.shared.bytes(for: request)
                detail = ""
                if let retry = response as? HTTPURLResponse, retry.statusCode != 200 {
                    for try await line in bytes.lines { detail += line }
                    throw NSError(
                        domain: "OpenAIProvider", code: retry.statusCode,
                        userInfo: [NSLocalizedDescriptionKey:
                            "HTTP \(retry.statusCode): \(detail)"])
                }
            } else {
                throw NSError(
                    domain: "OpenAIProvider", code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey:
                        "HTTP \(http.statusCode): \(detail)"])
            }
        }

        // Parse the SSE stream: `data: {json}` lines, terminated by `data: [DONE]`.
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count)
                .trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { continuation.finish(); return }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            else { continue }

            if let choices = obj["choices"] as? [[String: Any]],
               let delta = choices.first?["delta"] as? [String: Any],
               let text = delta["content"] as? String {
                continuation.yield(text)
            }
            if let err = obj["error"] as? [String: Any] {
                let msg = err["message"] as? String ?? "unknown error"
                throw NSError(domain: "OpenAIProvider", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: msg])
            }
        }
        continuation.finish()
    }
}

// MARK: - DeepSeek implementation

/// Talks to the DeepSeek API (OpenAI-compatible) with streaming.
/// Very cheap and fast — key from platform.deepseek.com.
struct DeepSeekProvider: AIProvider {
    var apiKey: String
    var model: String = "deepseek-v4-flash"

    private let endpoint = URL(string: "https://api.deepseek.com/v1/chat/completions")!

    func streamSuggestion(
        question: String?,
        jobContext: String,
        screenshots: [Data],
        memory: SessionMemory,
        style: AnswerStyle,
        thinking: Bool
    ) -> AsyncThrowingStream<String, Error> {
        let think = thinking
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(question: question, jobContext: jobContext,
                                  screenshots: screenshots, memory: memory, style: style,
                                  thinking: think, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        question: String?,
        jobContext: String,
        screenshots: [Data],
        memory: SessionMemory,
        style: AnswerStyle,
        thinking: Bool,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        var userContent: [[String: Any]] =
            [["type": "text", "text": copilotUserPrompt(question: question, style: style, screenshotCount: screenshots.count, memory: memory).text]]
        for shot in screenshots {
            userContent.append(["type": "image_url", "image_url":
                ["url": "data:image/png;base64,\(shot.base64EncodedString())"]])
        }

        // No `max_tokens`: the model's default limit applies, so long answers
        // aren't cut off.
        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "thinking": ["type": thinking ? "enabled" : "disabled"],
            "messages": [
                ["role": "system",
                 "content": copilotSystemPrompt(jobContext: jobContext)],
                ["role": "user", "content": userContent]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var detail = ""
            for try await line in bytes.lines { detail += line }
            throw NSError(
                domain: "DeepSeekProvider", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey:
                    "HTTP \(http.statusCode): \(detail)"])
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count)
                .trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { continuation.finish(); return }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            else { continue }

            if let choices = obj["choices"] as? [[String: Any]],
               let delta = choices.first?["delta"] as? [String: Any],
               let text = delta["content"] as? String {
                continuation.yield(text)
            }
            if let err = obj["error"] as? [String: Any] {
                let msg = err["message"] as? String ?? "unknown error"
                throw NSError(domain: "DeepSeekProvider", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: msg])
            }
        }
        continuation.finish()
    }
}

// MARK: - Google Gemini implementation

/// Talks to the Google Gemini API (Generative Language) with streaming. The
/// free tier works with a key from https://aistudio.google.com/apikey.
struct GeminiProvider: AIProvider {
    var apiKey: String
    /// `gemini-2.0-flash` is fast and available on the free tier.
    var model: String = "gemini-2.0-flash"

    func streamSuggestion(
        question: String?,
        jobContext: String,
        screenshots: [Data],
        memory: SessionMemory,
        style: AnswerStyle,
        thinking: Bool
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(question: question, jobContext: jobContext,
                                  screenshots: screenshots, memory: memory, style: style,
                                  continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        question: String?,
        jobContext: String,
        screenshots: [Data],
        memory: SessionMemory,
        style: AnswerStyle,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        // Streaming SSE endpoint. Key goes in the query string.
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/" +
            "\(model):streamGenerateContent?alt=sse&key=\(key)"
        guard let url = URL(string: urlStr) else {
            throw NSError(domain: "GeminiProvider", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "Invalid model name."])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var parts: [[String: Any]] =
            [["text": copilotUserPrompt(question: question, style: style, screenshotCount: screenshots.count, memory: memory).text]]
        for shot in screenshots {
            parts.append(["inline_data":
                ["mime_type": "image/png", "data": shot.base64EncodedString()]])
        }

        let body: [String: Any] = [
            "system_instruction": [
                "parts": [["text": copilotSystemPrompt(jobContext: jobContext)]]
            ],
            // No `maxOutputTokens`: the model's own maximum applies (2.5
            // "thinking" models would otherwise burn the cap before answering).
            "contents": [
                ["role": "user", "parts": parts]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var detail = ""
            for try await line in bytes.lines { detail += line }
            throw NSError(
                domain: "GeminiProvider", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey:
                    "HTTP \(http.statusCode): \(detail)"])
        }

        // SSE: `data: {json}` chunks, each with candidates[].content.parts[].text.
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count)
                .trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            else { continue }

            if let candidates = obj["candidates"] as? [[String: Any]],
               let content = candidates.first?["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]] {
                for part in parts {
                    if let text = part["text"] as? String {
                        continuation.yield(text)
                    }
                }
            }
            if let err = obj["error"] as? [String: Any] {
                let msg = err["message"] as? String ?? "unknown error"
                throw NSError(domain: "GeminiProvider", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: msg])
            }
        }
        continuation.finish()
    }
}

// MARK: - Placeholder / offline provider

/// Used when no API key is configured, so the app still runs and you can see
/// the transcript + overlay working before wiring up a real backend.
struct EchoProvider: AIProvider {
    func streamSuggestion(
        question: String?,
        jobContext: String,
        screenshots: [Data],
        memory: SessionMemory,
        style: AnswerStyle,
        thinking: Bool
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let last = (question ?? memory.events.last(where: { $0.kind == .interviewer })?.text)
                ?? "…"
            let msg = "[No AI backend configured — add an OpenAI or Anthropic " +
                "key in Settings.]\nHeard question: \"\(last)\""
            for word in msg.split(separator: " ") {
                continuation.yield(String(word) + " ")
            }
            continuation.finish()
        }
    }
}
