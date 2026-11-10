import AppKit
import SwiftUI
import Foundation
@preconcurrency import Vision

struct DetectedLink: Identifiable, Equatable, Sendable {
    var url: URL
    var label: String
    var kind: Kind
    enum Kind: String { case link, qr }
    var id: String { "\(kind.rawValue)|\(label)" }
}

enum LinkQRDetector {
    /// URLs found in plain text via NSDataDetector.
    static func links(in text: String) -> [DetectedLink] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var out: [DetectedLink] = []
        var seen = Set<String>()
        detector.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match, let url = match.url else { return }
            let key = url.absoluteString
            guard seen.insert(key).inserted else { return }
            out.append(DetectedLink(url: url, label: key, kind: .link))
        }
        return out
    }

    /// QR / barcode payloads from image. URL-like payloads become `.qr` links.
    nonisolated static func barcodes(in image: CGImage) async -> [DetectedLink] {
        await withCheckedContinuation { cont in
            let req = VNDetectBarcodesRequest()
            req.symbologies = [.qr, .aztec, .pdf417, .dataMatrix]
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([req])
                var out: [DetectedLink] = []
                var seen = Set<String>()
                for ob in req.results ?? [] {
                    guard let raw = ob.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !raw.isEmpty else { continue }
                    guard seen.insert(raw).inserted else { continue }
                    if let url = URL(string: raw), let scheme = url.scheme,
                       ["http", "https", "mailto", "tel"].contains(scheme.lowercased()) {
                        out.append(DetectedLink(url: url, label: raw, kind: .qr))
                    } else if let url = URL(string: "https://\(raw)"), raw.contains(".") {
                        out.append(DetectedLink(url: url, label: raw, kind: .qr))
                    } else {
                        // Non-URL QR payload: expose via custom scheme-less copy helper using about:blank placeholder
                        // Store as data URL isn't ideal — use a fake https host only for Identifiable open;
                        // UI will copy payload instead when not a real URL.
                        if let dataURL = URL(string: "qr-payload://\(raw.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? "x")") {
                            out.append(DetectedLink(url: dataURL, label: raw, kind: .qr))
                        }
                    }
                }
                cont.resume(returning: out)
            } catch {
                cont.resume(returning: [])
            }
        }
    }

    static func open(_ link: DetectedLink) {
        if link.url.scheme == "qr-payload" {
            copy(link)
            return
        }
        NSWorkspace.shared.open(link.url)
    }

    static func copy(_ link: DetectedLink) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(link.label, forType: .string)
    }
}

struct DetectedLinksBar: View {
    let links: [DetectedLink]
    var body: some View {
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(links) { link in
                    HStack(spacing: 8) {
                        KIconView(link.kind == .qr ? .qr : .link, size: 13)
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 16)
                        Text(link.label)
                            .font(Theme.TypeScale.label)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        if link.url.scheme != "qr-payload" {
                            IconButton(icon: .open, help: L("打开"), size: 11) {
                                LinkQRDetector.open(link)
                            }
                        }
                        IconButton(icon: .copy, help: L("复制"), size: 11) {
                            LinkQRDetector.copy(link)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .card()
        }
    }
}
