import Foundation

/// 清华大学开放中文词库（THUOCL，MIT）里词频最高、至少三个字的词。
/// 韩世依, 张钰晖, 马云山, 涂存超, 郭志芃, 刘知远, 孙茂松. THUOCL：清华大学开放中文词库. 2016.
enum ASRPreset: String, CaseIterable, Identifiable {
    case it, medical, law, finance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .it: return L("IT")
        case .medical: return L("医学")
        case .law: return L("法律")
        case .finance: return L("财经")
        }
    }

    var words: [String] {
        switch self {
        case .it: return Self.itWords
        case .medical: return Self.medicalWords
        case .law: return Self.lawWords
        case .finance: return Self.financeWords
        }
    }

    private static let itWords = [
        "字符串", "初始化", "客户端", "应用程序", "自定义", "配置文件", "解决方案", "编译器", "文件名", "数据结构",
        "数据类型", "构造函数", "开发者", "解决方法", "用户名", "头文件", "命令行", "实例化", "多线程", "环境变量",
        "服务器端", "生命周期", "优先级", "C语言", "成员变量", "程序运行", "服务端", "根目录", "文件系统", "开发人员",
        "32位", "全局变量", "IP地址", "内存空间", "版本号", "下载地址", "构造方法", "jar包", "源文件", "局部变量",
    ]
    private static let medicalWords = [
        "人民医院", "医疗机构", "残疾人", "应急预案", "救护车", "计划生育", "公共卫生", "糖尿病", "高血压", "心脏病",
        "卫生局", "世界卫生组织", "呼吸道", "传染病", "维生素", "急救车", "发病率", "白血病", "医疗保障", "新生儿",
        "艾滋病", "水污染", "医疗器械", "精神病", "生命体征", "并发症", "蛋白质", "主任医师", "确诊病例", "后遗症",
        "免疫力", "急诊科", "慢性病", "疾病预防控制中心", "微生物", "抗生素", "副主任医师", "急救中心", "紧急救援", "基本药物",
    ]
    private static let lawWords = [
        "房地产", "上市公司", "董事长", "全国人大常委会", "有限责任公司", "保险公司", "承担责任", "证券交易所", "国家安全", "权利人",
        "国家法律", "侵权行为", "证券市场", "营业执照", "市盈率", "增值税", "违法行为", "未成年人", "公司董事会", "有效期",
        "信息披露", "执法人员", "直辖市", "印花税", "医疗保险", "从业人员", "侵犯版权", "市场占有率", "建设工程", "年度报告",
        "注册商标", "经营范围", "中级人民法院", "医疗费", "注册会计师", "债权人", "道路交通", "建设用地", "人民检察院", "法学院",
    ]
    private static let financeWords = [
        "有限公司", "总经理", "董事长", "房地产", "当事人", "竞争力", "投资者", "主管部门", "研究员", "基金会",
        "百分点", "企业家", "农产品", "责任人", "财政部", "开发区", "中小企业", "经营者", "电子商务", "进出口",
        "发改委", "银行卡", "工商局", "招商引资", "参与者", "国民经济", "合作社", "流动性", "经销商", "纳税人",
        "数据库", "增长率", "购房者", "信用卡", "社会保险", "成交量", "交易所", "总收入", "稳定性", "失业率",
    ]
}

enum VoicePolishStyle: String, CaseIterable, Identifiable {
    case clean, formal, brief, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clean: return L("收干净")
        case .formal: return L("书面")
        case .brief: return L("简洁")
        case .custom: return L("自定义")
        }
    }

    /// 附在润色要求后面的一句。自定义为空时按收干净。
    func instruction(_ note: String) -> String {
        switch self {
        case .clean:
            return L("保持原来的口气。")
        case .formal:
            return L("在收干净之后改成书面语。")
        case .brief:
            return L("在收干净之后尽量缩短，只留要说的事。")
        case .custom:
            let custom = note.trimmingCharacters(in: .whitespacesAndNewlines)
            return custom.isEmpty ? L("保持原来的口气。") : custom
        }
    }
}
