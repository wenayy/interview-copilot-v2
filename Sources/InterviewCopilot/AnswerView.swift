import SwiftUI

/// Renders an answer for a quick glance instead of showing raw markdown:
/// bullets and code blocks are laid out, and **bold** key phrases are
/// highlighted so you can pick up the cues and say it in your own words.
struct AnswerView: View {
    let markdown: String

    static let highlight = Color(red: 1.0, green: 0.84, blue: 0.35)
    static let codeColor = Color(red: 0.62, green: 0.9, blue: 1.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(AnswerBlock.parse(markdown).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: AnswerBlock) -> some View {
        switch block {
        case .text(let s):
            Text(Self.inline(s))
                .font(.system(size: 13, weight: .medium))
        case .heading(let s):
            Text(Self.inline(s))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Self.highlight)
        case .bullet(let marker, let s, let level):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                Text(Self.inline(s))
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.leading, CGFloat(level) * 14)
        case .code(let s):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(s)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Self.codeColor)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.07))
            .cornerRadius(6)
        }
    }

    /// Inline markdown (bold, italic, `code`) with bold runs highlighted.
    static func inline(_ s: String) -> AttributedString {
        var a = (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        let styled = a.runs.compactMap { run -> (Range<AttributedString.Index>,
                                                 InlinePresentationIntent)? in
            guard let intent = run.inlinePresentationIntent else { return nil }
            return (run.range, intent)
        }
        for (range, intent) in styled {
            if intent.contains(.stronglyEmphasized) {
                a[range].foregroundColor = highlight
                a[range].font = .system(size: 13, weight: .bold)
            }
            if intent.contains(.code) {
                a[range].font = .system(size: 12, design: .monospaced)
                a[range].foregroundColor = codeColor
            }
        }
        return a
    }
}

/// The block-level pieces of an answer. Parsed on every streamed chunk, so an
/// unclosed ``` fence (mid-stream) just renders the rest as code.
enum AnswerBlock {
    case text(String)
    case heading(String)
    case bullet(marker: String, text: String, level: Int)
    case code(String)

    static func parse(_ md: String) -> [AnswerBlock] {
        var blocks: [AnswerBlock] = []
        var paragraph: [String] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty {
                blocks.append(.text(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        for line in md.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let open = code {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil { code?.append(line); continue }
            if trimmed.isEmpty { flush(); continue }
            if ["---", "***", "___"].contains(trimmed) { flush(); continue }

            if trimmed.range(of: #"^#{1,6}\s"#, options: .regularExpression) != nil {
                flush()
                blocks.append(.heading(String(trimmed.drop(while: { $0 == "#" }))
                    .trimmingCharacters(in: .whitespaces)))
                continue
            }
            if let r = trimmed.range(of: #"^([-*•+]|\d+[.)])\s+"#,
                                     options: .regularExpression) {
                flush()
                let raw = trimmed[r].trimmingCharacters(in: .whitespaces)
                let marker = raw.first?.isNumber == true ? raw : "•"
                let level = min(line.prefix(while: { $0 == " " }).count / 2, 3)
                blocks.append(.bullet(marker: marker,
                                      text: String(trimmed[r.upperBound...]),
                                      level: level))
                continue
            }
            paragraph.append(trimmed)
        }
        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}
