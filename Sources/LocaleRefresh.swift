import SwiftUI

private struct LocaleRefresh: ViewModifier {
    @ObservedObject private var config = AppConfig.shared
    func body(content: Content) -> some View {
        content.id(config.appLanguage)
    }
}

extension View {
    func localeRefresh() -> some View {
        modifier(LocaleRefresh())
    }
}
