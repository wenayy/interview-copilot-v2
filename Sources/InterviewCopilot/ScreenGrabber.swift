import Foundation
import ScreenCaptureKit
import CoreImage
import AppKit

/// Captures a single still frame of the main display as PNG data, for the
/// vision path. The overlay window is automatically excluded because it uses
/// `sharingType = .none`, so screenshots never contain the copilot itself.
enum ScreenGrabber {
    static func capturePNG() async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "ScreenGrabber", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No display available."])
        }
        let filter = SCContentFilter(display: display,
                                     excludingApplications: [],
                                     exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        // Downscale large displays a bit to keep the upload/token cost sane.
        let maxW = 1600
        if display.width > maxW {
            let scale = Double(maxW) / Double(display.width)
            config.width = maxW
            config.height = Int(Double(display.height) * scale)
        }

        let cg = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)
        return try png(from: cg)
    }

    /// One grab of a selected region: the PNG for the model, plus a tiny
    /// grayscale thumbnail used to tell whether the content has moved.
    struct RegionShot: Sendable {
        let png: Data
        let fingerprint: [UInt8]
    }

    /// Captures just `region` (for the scrolling screenshot), downscaled to at
    /// most 1600px wide.
    static func captureRegion(_ region: ScreenRegion) async throws -> RegionShot {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: {
            $0.displayID == region.displayID }) ?? content.displays.first else {
            throw NSError(domain: "ScreenGrabber", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No display available."])
        }
        let filter = SCContentFilter(display: display,
                                     excludingApplications: [],
                                     exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = region.sourceRect
        config.showsCursor = false
        var w = region.sourceRect.width * region.scale
        var h = region.sourceRect.height * region.scale
        let maxW: CGFloat = 1600
        if w > maxW { h *= maxW / w; w = maxW }
        config.width = Int(w)
        config.height = Int(h)

        let cg = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)
        return RegionShot(png: try png(from: cg), fingerprint: fingerprint(cg))
    }

    /// 32x32 grayscale thumbnail.
    private static func fingerprint(_ cg: CGImage) -> [UInt8] {
        let side = 32
        var px = [UInt8](repeating: 0, count: side * side)
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return px
    }

    /// Mean absolute pixel difference (0–255) between two fingerprints.
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 255 }
        var total = 0
        for i in a.indices { total += abs(Int(a[i]) - Int(b[i])) }
        return Double(total) / Double(a.count)
    }

    private static func png(from cg: CGImage) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ScreenGrabber", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode PNG."])
        }
        return data
    }
}
