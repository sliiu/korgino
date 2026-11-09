import AppKit

extension CloudOCR {
    static func pngData(_ image: CGImage) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw TErr(L("无法编码截图"))
        }
        return data
    }

    static func recognizeText(cgImage: CGImage, provider: OCRProviderID) async throws -> String {
        if provider == .appleVision {
            return try await OCRCapture.recognize(cgImage)
        }
        return try await recognizeText(png: try pngData(cgImage), provider: provider)
    }
}
