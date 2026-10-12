import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var vm: CopilotViewModel
    @State private var showContext = false
    @State private var showKeys = false
    @State private var confirmNewSession = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            controls

            if vm.scrollCapturing {
                scrollCaptureBar
            }

            if showKeys {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Shortcuts.all, id: \.keys) { s in
                        HStack(spacing: 8) {
                            Text(s.keys)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(.cyan)
                                .frame(width: 44, alignment: .leading)
                            Text(s.label)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06))
                .cornerRadius(6)
            }

            if showContext {
                VStack(alignment: .leading, spacing: 6) {
                    Text("JOB / ROLE NOTES")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                    contextEditor($vm.jobContext,
                                  placeholder: "Job description, target role, company…",
                                  height: 48)

                    HStack {
                        Text("RÉSUMÉ / BACKGROUND")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.4))
                        Spacer()
                        Button("Load file…") { vm.loadResumeFile() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.cyan)
                    }
                    contextEditor($vm.profile,
                                  placeholder: "Paste résumé bullets or load a PDF/txt. " +
                                    "Used only when a question is about your experience.",
                                  height: 56)
                }
            }

            // Live transcript tail — hidden in compact mode
            if !vm.compactMode {
                transcriptView
                Divider().overlay(.white.opacity(0.15))
            }

            // Suggested answer
            ScrollView {
                Group {
                    if vm.suggestion.isEmpty {
                        Text(vm.waitingForAnswer
                             ? "Thinking…"
                             : "Suggested answers appear here when the interviewer asks a question.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.35))
                    } else {
                        AnswerView(markdown: vm.suggestion)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            Divider().overlay(.white.opacity(0.15))
            askQuestionBar
        }
        .padding(12)
        .frame(minWidth: 360, minHeight: vm.compactMode ? 220 : 340)
        .background(Color.black.opacity(vm.overlayOpacity))
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(vm.isRunning ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(vm.status)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
            Spacer()
            if vm.apiCalls > 0 {
                Text("API: \(vm.apiCalls)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.6))
                    .cornerRadius(4)
            }
            Button(vm.compactMode ? "Full" : "Mini") {
                vm.compactMode.toggle()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.yellow)
            .help("Toggle compact mode (⌃⌥C)")
            Slider(value: $vm.overlayOpacity, in: 0.15...1.0, step: 0.05)
                .frame(width: 50)
                .help("Overlay opacity — slide left to see through")
            Button(showKeys ? "⌨︎✕" : "⌨︎") { showKeys.toggle() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
                .help("Show keyboard shortcuts")
            Button(showContext ? "Hide ctx" : "Context") { showContext.toggle() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
            Button(vm.isRunning ? "Stop" : "Start") { vm.toggle() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(vm.isRunning ? .red : .green)
        }
    }

    // Answer-style picker + toggles on one row, Screen / Scroll / Answer
    // actions on their own row so nothing gets clipped at overlay width.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            aiRow
            optionsRow
            actionsRow
        }
    }

    /// Which AI answers, and which reads Screen / Scroll captures.
    private var aiRow: some View {
        HStack(spacing: 6) {
            rowLabel("AI")
            Picker("", selection: Binding(get: { vm.providerKind },
                                          set: { vm.setProvider($0) })) {
                ForEach(AppSettings.ProviderKind.allCases) { k in
                    Text(k.shortLabel + (vm.hasKey(k) ? "" : " (no key)")).tag(k)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(.system(size: 11))
            .fixedSize()
            .help("Answers: \(vm.providerKind.shortLabel) · " +
                  "\(vm.modelName(vm.providerKind)). Memory carries over when you switch.")

            rowLabel("Screen")
                .padding(.leading, 6)
            Picker("", selection: Binding(get: { vm.screenChoice },
                                          set: { vm.setScreenChoice($0) })) {
                ForEach(AppSettings.ScreenProvider.allCases) { c in
                    if let k = c.kind {
                        Text(k.shortLabel + (vm.hasKey(k) ? "" : " (no key)")).tag(c)
                    } else {
                        Text("Auto (\(vm.autoScreenKind.shortLabel))").tag(c)
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(.system(size: 11))
            .fixedSize()
            .help("Screen / Scroll captures: \(vm.screenProviderKind.shortLabel) · " +
                  "\(vm.modelName(vm.screenProviderKind)). DeepSeek can't read images.")
            Spacer(minLength: 0)
        }
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.45))
    }

    private var optionsRow: some View {
        HStack(spacing: 10) {
            Picker("", selection: $vm.answerStyle) {
                ForEach(AnswerStyle.allCases) { s in Text(s.label).tag(s) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(.system(size: 11))
            .fixedSize()

            Toggle("Auto", isOn: $vm.autoAnswer)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .help("Auto-answer each question (uses your API key automatically)")

            Toggle("Mic", isOn: Binding(get: { vm.micEnabled },
                                        set: { vm.setMic($0) }))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .help("Transcribe your mic for follow-up context. Off = " +
                      "interviewer only, ~half the Deepgram cost, doesn't hear you.")

            Toggle("Résumé", isOn: $vm.useResume)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .help("Use your résumé/background in answers. Off = never " +
                      "reference it (answers stay generic/technical).")

            Toggle("Think", isOn: $vm.deepThink)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .help("Deeper reasoning before answering (GPT, Claude, DeepSeek) " +
                      "— more accurate on hard and coding questions, a few " +
                      "seconds slower. Off = fastest.")

            Spacer(minLength: 0)
        }
    }

    private var actionsRow: some View {
        HStack(spacing: 6) {
            actionButton("Screen", systemImage: "camera.viewfinder", .orange,
                         help: "Answer what's on screen (⌃⌥S)") {
                vm.answerFromScreen()
            }
            actionButton(vm.scrollCapturing ? "Done" : "Scroll",
                         systemImage: "scroll", .pink,
                         help: "Scrolling screenshot: select a region, scroll " +
                               "it, then Done (⌃⌥L)") {
                vm.toggleScrollCapture()
            }
            actionButton("Answer", systemImage: "sparkles", .cyan,
                         help: "Answer the interviewer's latest question (⌃⌥A)") {
                vm.requestSuggestion()
            }
            Spacer(minLength: 0)
            sessionButton
        }
    }

    /// Shows how many answers this session remembers; clicking starts a New
    /// session. Takes two clicks so a stray click can't wipe a meeting.
    private var sessionButton: some View {
        let n = vm.memory.answerCount
        return actionButton(confirmNewSession ? "Clear all?" : (n > 0 ? "\(n) · New" : "New"),
                            systemImage: "brain",
                            confirmNewSession ? .red : .gray,
                            help: "This session remembers the whole conversation, " +
                                  "every screen capture and \(n) answer(s). Click to " +
                                  "start a New session (clears memory + transcript; " +
                                  "keeps résumé and job notes).") {
            if confirmNewSession {
                vm.newSession()
                confirmNewSession = false
            } else {
                confirmNewSession = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    confirmNewSession = false
                }
            }
        }
    }

    private func actionButton(_ title: String, systemImage: String, _ color: Color,
                              help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .cornerRadius(5)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var scrollCaptureBar: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.red).frame(width: 7, height: 7)
            Text("Capturing · \(vm.scrollFrames)/\(ScrollCaptureSession.maxFrames)")
                .font(.system(size: 11, weight: .semibold))
            Text("scroll slowly, pause briefly")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            Button("Cancel") { vm.cancelScrollCapture() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
            Button("Done") { vm.finishScrollCapture() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.pink)
        }
        .padding(6)
        .background(Color.red.opacity(0.12))
        .cornerRadius(6)
    }

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(vm.transcript.suffix(6).enumerated()),
                            id: \.offset) { _, seg in
                        line(seg.speaker == .interviewer ? "Q" : "Me",
                             seg.text,
                             seg.speaker == .interviewer ? .cyan : .green)
                    }
                    if !vm.liveInterviewer.isEmpty {
                        line("Q", vm.liveInterviewer + "…", .cyan.opacity(0.6))
                    }
                    if !vm.liveMe.isEmpty {
                        line("Me", vm.liveMe + "…", .green.opacity(0.6))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 90)
            .onChange(of: vm.transcript.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom") }
            }
        }
    }

    private var askQuestionBar: some View {
        HStack(spacing: 6) {
            Button { vm.askLast() } label: {
                HStack(spacing: 3) {
                    Image(systemName: "text.bubble.fill")
                        .font(.system(size: 11))
                    Text("Ask Last")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(.purple)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color.purple.opacity(0.12))
                .cornerRadius(5)
            }
            .buttonStyle(.plain)
            .help("Ask AI about what you just said (⌃⌥Q)")

            TextField("Type a question…", text: $vm.questionText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.08))
                .cornerRadius(6)
                .onSubmit { vm.askQuestion() }

            Button { vm.askQuestion() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(vm.questionText.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty
                        ? .white.opacity(0.25) : .cyan)
            }
            .buttonStyle(.plain)
            .disabled(vm.questionText.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty)
            .help("Send question (Enter)")
        }
    }

    private func contextEditor(_ text: Binding<String>, placeholder: String,
                               height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.system(size: 11))
            .frame(height: height)
            .scrollContentBackground(.hidden)
            .background(Color.white.opacity(0.06))
            .cornerRadius(6)
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
    }

    private func line(_ tag: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(tag)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 22, alignment: .leading)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}
