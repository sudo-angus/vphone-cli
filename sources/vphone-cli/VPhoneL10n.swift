import Foundation

/// Two-language helper for user-facing GUI strings. The app bundle is
/// assembled by the Makefile with no .lproj resources, so the usual
/// NSLocalizedString machinery has nothing to load from — instead each
/// call site carries both languages and we pick from the user's system
/// preference directly.
enum VPhoneL10n {
    /// True when the user's top preferred language is any Chinese variant.
    static let prefersChinese: Bool =
        Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false

    static func tr(_ en: String, _ zh: String) -> String {
        prefersChinese ? zh : en
    }
}
