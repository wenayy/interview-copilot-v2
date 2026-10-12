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

/// Everything the copilot remembers for one session (one meeting), so
/// follow-ups ("optimize it", "what's the complexity?", "back to the first
/// problem") build on earlier answers instead of starting from scratch. Kept
/// until you start a New session; saved to disk so it survives a relaunch.
struct SessionMemory: Codable, Sendable {
    struct Exchange: Codable, Sendable {
        let question: String
        let answer: String
        /// On-device OCR of the Screen / Scroll capture this answered, if any.
        var screenText: String?
    }
    var startedAt = Date()
    /// Every exchange this session, oldest first.
    var exchanges: [Exchange] = []

    var isEmpty: Bool { exchanges.isEmpty }
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
            return "Answer in 2-4 short spoken sentences. Lead with the answer."
        case .detailed:
            return "Give a thorough spoken answer (5-8 sentences) with a concrete " +
                "example or reasoning, still natural to say out loud."
        case .star:
            return "This is likely a behavioral question. Answer using the STAR " +
                "structure (Situation, Task, Action, Result) in first person, " +
                "concise and natural — don't label the sections out loud."
        case .code:
            return "This is a technical/coding question. Give the concrete answer: " +
                "a short explanation of the approach, then a clean, correct code " +
                "solution in a fenced code block, then note time/space complexity."
        }
    }
}

protocol AIProvider: Sendable {
    /// Stream a suggested answer for the most recent interviewer question,
    /// given the running transcript, optional on-screen images (one screen
    /// grab, or the ordered frames of a scrolling screenshot), and answer style.
    func streamSuggestion(
        transcript: [TranscriptSegment],
        jobContext: String,
        screenshots: [Data],
        memory: SessionMemory,
        style: AnswerStyle,
        thinking: Bool
    ) -> AsyncThrowingStream<String, Error>
}

// MARK: - Shared prompt building

/// The system prompt is identical across providers — keep it in one place.
func copilotSystemPrompt(jobContext: String, style: AnswerStyle) -> String {
    """
    You are a real-time interview copilot. The user is in a live job \
    interview. You are given the running transcript (the interviewer's \
    questions and the user's replies), optionally a screenshot of the user's \
    screen (which may contain a coding task, a multiple-choice question, or a \
    shared document), plus optional context about the role and the user's \
    background.

    Produce an answer the user can use immediately — first person, natural \
    spoken language, no preamble, no "here's what you could say". Lead with \
    the answer. If a screenshot is provided, answer what it shows (read code, \
    questions, or diagrams from it). \(style.instruction)

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
    """
}

func copilotUserPrompt(transcript: [TranscriptSegment],
                       screenshotCount: Int,
                       memory: SessionMemory) -> String {
    let ask = questionPrompt(transcript: transcript, screenshotCount: screenshotCount)
    guard !memory.isEmpty else { return ask }
    return """
    \(sessionPrompt(memory))

    If my question is a follow-up to anything above — e.g. "optimize it", \
    "what's the complexity", "do it in another language", "why does that \
    work", "what about edge cases", "go back to the first problem", or it \
    refers to "that problem" / "the code" — answer in that context and build \
    on the earlier answer (same problem, same approach unless asked to change \
    it). If it's a new, unrelated question, ignore the session history.

    \(ask)
    """
}

/// How much session history goes into one request. The newest exchanges are
/// sent in full until this budget is used up; older ones are listed by their
/// question only, so a long interview keeps per-call cost and latency bounded.
private let sessionBudgetChars = 24_000
private let sessionAnswerChars = 4_000

private func sessionPrompt(_ memory: SessionMemory) -> String {
    func clip(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n)) + " …[truncated]" : s
    }
    func block(_ ex: SessionMemory.Exchange, _ number: Int) -> String {
        var lines = ["<exchange n=\"\(number)\">"]
        if let screen = ex.screenText, !screen.isEmpty {
            lines.append("<screen_text>\n\(screen)\n</screen_text>")
        }
        lines.append("Q: \(ex.question)")
        lines.append("A: \(ex.answer.isEmpty ? "(no answer)" : clip(ex.answer, sessionAnswerChars))")
        lines.append("</exchange>")
        return lines.joined(separator: "\n")
    }

    var full: [String] = []
    var used = 0
    var firstFull = memory.exchanges.count
    for i in memory.exchanges.indices.reversed() {
        let b = block(memory.exchanges[i], i + 1)
        if used + b.count > sessionBudgetChars, !full.isEmpty { break }
        full.insert(b, at: 0)
        used += b.count
        firstFull = i
    }

    var out = "This interview session so far (exchange 1 is the oldest; " +
        "screen_text is text read from my screen capture for that exchange):"
    if firstFull > 0 {
        let older = memory.exchanges[..<firstFull].enumerated().map {
            "#\($0.offset + 1): \(clip($0.element.question, 200))"
        }
        out += "\n\nEarlier questions (answers omitted):\n" + older.joined(separator: "\n")
    }
    return out + "\n\n" + full.joined(separator: "\n\n")
}

private func questionPrompt(transcript: [TranscriptSegment],
                            screenshotCount: Int) -> String {
    let convo = transcript.map { seg -> String in
        let who = seg.speaker == .interviewer ? "INTERVIEWER" : "ME"
        return "\(who): \(seg.text)"
    }.joined(separator: "\n")
    let convoBlock = convo.isEmpty ? "(no transcript yet)" : convo

    if screenshotCount > 1 {
        return """
        \(screenshotCount) screenshots are attached, in order. They are a \
        scrolling capture of ONE region of my screen, top to bottom — together \
        they show a single long question, task, or document. Consecutive \
        screenshots may overlap; treat overlapping parts as the same content, \
        not repeated text. ANSWER WHAT THE SCREENSHOTS SHOW, reading them as \
        one continuous page. Use the transcript below only as extra \
        background, not as the question.

        Transcript (background only):
        \(convoBlock)
        """
    }
    if screenshotCount == 1 {
        return """
        A screenshot of my screen is attached. It contains the actual question \
        or task (e.g. a coding problem, a multiple-choice question, or a \
        document). ANSWER WHAT IS IN THE SCREENSHOT — read the code, question, \
        or prompt directly from the image. Use the transcript below only as \
        extra background, not as the question.

        Transcript (background only):
        \(convoBlock)
        """
    }
    return """
    Here is the interview transcript so far:

    \(convoBlock)

    Give me the answer to the interviewer's most recent question.
    """
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
        transcript: [TranscriptSegment],
        jobContext: String,
        screenshots: [Data],
        memory: SessionMemory,
        style: AnswerStyle,
        thinking: Bool
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(transcript: transcript, jobContext: jobContext,
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
        transcript: [TranscriptSegment],
        jobContext: String,
        screenshots: [Data],
        memory: SessionMemory,
        style: AnswerStyle,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                         forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let system = copilotSystemPrompt(jobContext: jobContext, style: style)
        let userText = copilotUserPrompt(transcript: transcript, screenshotCount: screenshots.count, memory: memory)

        var content: [[String: Any]] = [["type": "text", "text": userText]]
        for (i, shot) in screenshots.enumerated() {
            content.insert(["type": "image", "source": [
                "type": "base64", "media_type": "image/png",
                "data": shot.base64EncodedString()]], at: i)
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": system,
            "messages": [
                ["role": "user", "content": content]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var detail = ""
            for try await line in bytes.lines { detail += line }
            throw NSError(
                domain: "AnthropicProvider", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey:
                    "HTTP \(http.statusCode): \(detail)"])
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
        transcript: [TranscriptSegment],
        jobContext: String,
        screenshots: [Data],
        memory: SessionMemory,
        style: AnswerStyle,
        thinking: Bool
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(transcript: transcript, jobContext: jobContext,
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
        transcript: [TranscriptSegment],
        jobContext: String,
        screenshots: [Data],
        memory: SessionMemory,
        style: AnswerStyle,
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
            [["type": "text", "text": copilotUserPrompt(transcript: transcript, screenshotCount: screenshots.count, memory: memory)]]
        for shot in screenshots {
            userContent.append(["type": "image_url", "image_url":
                ["url": "data:image/png;base64,\(shot.base64EncodedString())"]])
        }

        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": [
                ["role": "system",
                 "content": copilotSystemPrompt(jobContext: jobContext, style: style)],
                ["role": "user", "content": userContent]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var detail = ""
            for try await line in bytes.lines { detail += line }
            throw NSError(
                domain: "OpenAIProvider", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey:
                    "HTTP \(http.statusCode): \(detail)"])
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
        transcript: [TranscriptSegment],
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
                    try await run(transcript: transcript, jobContext: jobContext,
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
        transcript: [TranscriptSegment],
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
            [["type": "text", "text": copilotUserPrompt(transcript: transcript, screenshotCount: screenshots.count, memory: memory)]]
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
                 "content": copilotSystemPrompt(jobContext: jobContext, style: style)],
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
        transcript: [TranscriptSegment],
        jobContext: String,
        screenshots: [Data],
        memory: SessionMemory,
        style: AnswerStyle,
        thinking: Bool
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(transcript: transcript, jobContext: jobContext,
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
        transcript: [TranscriptSegment],
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
            [["text": copilotUserPrompt(transcript: transcript, screenshotCount: screenshots.count, memory: memory)]]
        for shot in screenshots {
            parts.append(["inline_data":
                ["mime_type": "image/png", "data": shot.base64EncodedString()]])
        }

        let body: [String: Any] = [
            "system_instruction": [
                "parts": [["text": copilotSystemPrompt(jobContext: jobContext,
                                                       style: style)]]
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
        transcript: [TranscriptSegment],
        jobContext: String,
        screenshots: [Data],
        memory: SessionMemory,
        style: AnswerStyle,
        thinking: Bool
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let last = transcript.last(where: { $0.speaker == .interviewer })?.text
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
