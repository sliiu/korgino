import Foundation

/// OCR: part of AppConfig.
extension AppConfig {
    /// OCR 是否已配好可启用。Apple Vision / AI 视觉不需单独密钥，恒为就绪。
    func ocrReady(_ p: OCRProviderID) -> Bool {
        switch p {
        case .appleVision, .aiVision:
            return true
        case .baidu, .baiduAccurate:
            let id = ocrBaiduSync ? baiduAppID : ocrBaiduAppID
            let secret = ocrBaiduSync ? baiduSecret : ocrBaiduSecret
            return !blank(id) && !blank(secret)
        case .youdao:
            let id = ocrYoudaoSync ? youdaoAppKey : ocrYoudaoAppKey
            let secret = ocrYoudaoSync ? youdaoSecret : ocrYoudaoSecret
            return !blank(id) && !blank(secret)
        case .tencent:
            return !blank(tencentSecretID) && !blank(tencentSecretKey)
        case .googleVision:
            return !blank(ocrGoogleSync ? googleCloudKey : ocrGoogleKey)
        case .azure:
            return !blank(azureVisionEndpoint) && !blank(azureVisionKey)
        case .ocrSpace:
            return !blank(ocrSpaceKey)
        }
    }

    func isOCROn(_ p: OCRProviderID) -> Bool { ocrEnabled.contains(p.rawValue) }

    func orderedOCRProviders() -> [OCRProviderID] {
        var ids = ocrOrder.filter { ocrEnabled.contains($0) }
        for provider in OCRProviderID.allCases where ocrEnabled.contains(provider.rawValue) && !ids.contains(provider.rawValue) {
            ids.append(provider.rawValue)
        }
        if ids.isEmpty { ids = [OCRProviderID.appleVision.rawValue] }
        return ids.compactMap(OCRProviderID.init(rawValue:))
    }

    func moveOCR(from: String, to: String) {
        var ids = orderedOCRProviders().map(\.rawValue)
        guard let i = ids.firstIndex(of: from), let j = ids.firstIndex(of: to), i != j else { return }
        let item = ids.remove(at: i)
        ids.insert(item, at: j)
        ocrOrder = ids
    }

    func setOCROn(_ p: OCRProviderID, _ on: Bool) {
        if !on, ocrEnabled.count <= 1, ocrEnabled.contains(p.rawValue) { return }
        if on {
            ocrEnabled.insert(p.rawValue)
            if !ocrOrder.contains(p.rawValue) { ocrOrder.append(p.rawValue) }
        } else {
            ocrEnabled.remove(p.rawValue)
            ocrOrder.removeAll { $0 == p.rawValue }
        }
    }

    func setOCRDefault(_ p: OCRProviderID) {
        if !ocrEnabled.contains(p.rawValue) { ocrEnabled.insert(p.rawValue) }
        var ids = orderedOCRProviders().map(\.rawValue).filter { $0 != p.rawValue }
        ids.insert(p.rawValue, at: 0)
        ocrOrder = ids
    }
}
