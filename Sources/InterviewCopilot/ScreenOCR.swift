import Foundation
import Vision
import ImageIO

/// On-device text recognition (Apple Vision) for captured screens. Free and
/// local. The text goes into session memory so follow-up questions — even to
/// a text-only model like DeepSeek — still know what was on screen.
enum ScreenOCR {
    /// Text of the frames, in order. Lines a scrolling frame repeats from the
    /// previous frame's overlap are dropped.
    static func text(from pngs: [Data]) -> String {
        var lines: [String] = []
        for png in pngs {
            let next = recognize(png)
            var overlap = 0
            for k in stride(from: min(lines.count, next.count), to: 0, by: -1)
                where Array(lines.suffix(k)) == Array(next.prefix(k)) {
                overlap = k
                break
            }
            lines += next.dropFirst(overlap)
        }
        return lines.joined(separator: "\n")
    }

    private static func recognize(_ png: Data) -> [String] {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false   // keep code / identifiers as-is
        try? VNImageRequestHandler(cgImage: cg).perform([request])

        // Reading order: top to bottom (Vision's y axis points up). Pieces
        // whose vertical centers are within half a line height share a row and
        // are joined left to right.
        let pieces = (request.results ?? []).sorted {
            $0.boundingBox.midY > $1.boundingBox.midY }
        var rows: [(midY: CGFloat, height: CGFloat, items: [VNRecognizedTextObservation])] = []
        for o in pieces {
            let box = o.boundingBox
            if let last = rows.last,
               abs(last.midY - box.midY) < min(last.height, box.height) / 2 {
                rows[rows.count - 1].items.append(o)
            } else {
                rows.append((box.midY, box.height, [o]))
            }
        }
        return rows.map { row in
            row.items.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ")
        }
    }
}
