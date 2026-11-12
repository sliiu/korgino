import Foundation

/// 密钥读取：后台预读 → 回主线程回填。
///
/// 读钥匙串会卡在系统授权框上等用户点。以前这 18 次同步读都在 `AppConfig.init` 的主线程里，
/// 所以冷启动要等所有密钥读完才画得出窗口（重装后实测 71.7 秒 ~ 无限）。
/// 现在 `init` 只做 preference 里的活，密钥交给这里：后台读，读完回主线程赋值。
extension AppConfig {
    /// 所有要从钥匙串读的账号。用户自己加的档也算上——它们的密码在 `ai.<id>` 这类账号里。
    static func secretAccounts(defaults d: UserDefaults) -> [String] {
        var accounts = [
            "googleCloud", "deepl", "microsoft", "baiduSecret", "youdaoSecret", "caiyun",
            "libreTranslate", "ocrBaiduSecret", "ocrYoudaoSecret", "ocrGoogleKey",
            "tencentSecretKey", "azureVision", "ocrSpace", "proxyPassword",
            // 老安装迁移用的两个旧账号，读完就是这一轮的事。
            "asrOpenAI", "asrGroq",
            // 许可证也要读，否则启动时 Pro 状态是错的。
            "directLicense",
        ]
        if let data = d.data(forKey: ConfigKeys.aiProfiles),
           let list = try? JSONDecoder().decode([AIProfile].self, from: data) {
            accounts += list.map(\.keychainAccount)
        }
        if let data = d.data(forKey: ConfigKeys.asrProfiles),
           let list = try? JSONDecoder().decode([ASRProfile].self, from: data) {
            accounts += list.map(\.keychainAccount)
        }
        if let data = d.data(forKey: ConfigKeys.ttsProfiles),
           let list = try? JSONDecoder().decode([TTSProfile].self, from: data) {
            accounts += list.map(\.keychainAccount)
        }
        return accounts
    }

    /// `init` 末尾调用。界面这时已经能画了，读在后台走。
    func startSecretsLoad() {
        guard !secretsLoading else { return }
        secretsLoading = true
        loadSecrets(accounts: Self.secretAccounts(defaults: .standard), retryLeft: 1)
    }

    /// 后台读一批账号，回主线程回填。没读到的再试一次——
    /// 钥匙串刚解锁、授权框被误关都会这样，一次失败不该让配置永久停在半空。
    private func loadSecrets(accounts: [String], retryLeft: Int) {
        let t0 = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let failed = Keychain.prime(accounts)
            let ms = Date().timeIntervalSince(t0) * 1000
            DispatchQueue.main.async {
                self.applySecrets(failed: failed)
                SecretsHost.afterApply?(ms, accounts.count, failed)
                guard !failed.isEmpty, retryLeft > 0 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self.loadSecrets(accounts: failed, retryLeft: retryLeft - 1)
                }
            }
        }
    }

    /// 密钥到手了：填值，再把所有「按密钥算」的默认值和开关补算一遍。
    /// 顺序有讲究：填完值再算，算完才设 `secretsReady`，请求才会放行。
    ///
    /// `failed` 是这一轮没读成的账号。读失败和「确实没有」看起来都是空值，
    /// 但下面这些判断都会把空值当成用户没配、然后写进偏好：
    /// 供应商被关掉、预设被删、一次性开关被打上。所以有失败就只填值，判断留到下一轮。
    func applySecrets(failed: [String]) {
        googleCloudKey = Keychain.get("googleCloud") ?? ""
        deeplKey = Keychain.get("deepl") ?? ""
        microsoftKey = Keychain.get("microsoft") ?? ""
        baiduSecret = Keychain.get("baiduSecret") ?? ""
        youdaoSecret = Keychain.get("youdaoSecret") ?? ""
        caiyunToken = Keychain.get("caiyun") ?? ""
        libreTranslateKey = Keychain.get("libreTranslate") ?? ""
        ocrBaiduSecret = Keychain.get("ocrBaiduSecret") ?? ""
        ocrYoudaoSecret = Keychain.get("ocrYoudaoSecret") ?? ""
        ocrGoogleKey = Keychain.get("ocrGoogleKey") ?? ""
        tencentSecretKey = Keychain.get("tencentSecretKey") ?? ""
        azureVisionKey = Keychain.get("azureVision") ?? ""
        ocrSpaceKey = Keychain.get("ocrSpace") ?? ""
        proxyPassword = Keychain.get("proxyPassword") ?? ""

        let readsClean = failed.isEmpty

        // 首次启动时按真实密钥决定开哪几家词典。
        if dictDefaultsPending, readsClean {
            dictDefaultsPending = false
            let on = freshDictionaryDefaults()
            dictEnabled = on
            if !on.contains(dictProvider.rawValue) {
                dictProvider = DictionaryProviderID.allCases.first { on.contains($0.rawValue) } ?? .freeDictionary
            }
        }

        // 老安装的 ASR 档迁移。现在密钥是真的了，判断才作数。
        if asrLegacyPending, readsClean {
            asrLegacyPending = false
            let asr = Self.loadASRState(.standard)
            asrAppleEnabled = asr.apple
            asrProfiles = asr.profiles
            asrSelection = asr.selection
        }

        guard readsClean else {
            // 只填值。剩下的一律等重试成功那轮再说。
            secretsReady = true
            return
        }

        // 预设清理是一次性开关，密钥空着跑会删掉有密钥的档。
        let pruned = LegacyMigrate.pruneUnusedPresetsIfNeeded(profiles: aiProfiles)
        if pruned.count != aiProfiles.count {
            aiProfiles = pruned
            let unified = enabledProviders.union(activeSimultaneous)
            enabledProviders = unified.isEmpty ? [ProviderID.googleFree.rawValue] : unified
            for i in aiProfiles.indices {
                if aiProfiles[i].enabled { activeSimultaneous.insert("ai:\(aiProfiles[i].id)") }
            }
        }

        seedFeatureDefaultsIfNeeded()
        enforceReadyInvariant()
        secretsReady = true
    }

    /// 首次启动时该勾哪几家词典：翻译那边开着、密钥又齐的，才算可用。
    private func freshDictionaryDefaults() -> Set<String> {
        var on: Set<String> = [DictionaryProviderID.freeDictionary.rawValue]
        let sim = activeSimultaneous
        func filled(_ s: String) -> Bool { !blank(s) }
        if sim.contains(ProviderID.youdao.rawValue), !blank(youdaoAppKey), filled(youdaoSecret) {
            on.insert(DictionaryProviderID.youdao.rawValue)
        }
        if sim.contains(ProviderID.baidu.rawValue), !blank(baiduAppID), filled(baiduSecret) {
            on.insert(DictionaryProviderID.baidu.rawValue)
        }
        if sim.contains(ProviderID.caiyun.rawValue), filled(caiyunToken) {
            on.insert(DictionaryProviderID.caiyun.rawValue)
        }
        return on
    }

    /// 请求路径在动手前等一等密钥。等不到就照常往下走——那时密钥确实没有，
    /// 会报「未填密钥」而不是一直转圈。超时 20 秒：用户不点授权框，请求不该一直挂着。
    func awaitSecrets(timeout: TimeInterval = 20) async {
        if secretsReady { return }
        let deadline = Date().addingTimeInterval(timeout)
        while !secretsReady, Date() < deadline {
            try? await Task.sleep(nanoseconds: 40_000_000)
            if Task.isCancelled { return }
        }
    }
}
