import Foundation

public enum L10n {
    public static var language: AppLanguage { AppPreferencesStore().load().language }
    public static var locale: Locale { language.locale }

    public static func bundle(for language: AppLanguage) -> Bundle {
        let resources = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("AISwitcher_AISwitcherCore.bundle")) } ?? Bundle.module
        guard let path = resources.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return resources }
        return bundle
    }

    public static func text(_ key: String, language: AppLanguage? = nil) -> String {
        bundle(for: language ?? self.language).localizedString(forKey: key, value: key, table: nil)
    }

    public static func format(_ key: String, _ arguments: String..., language: AppLanguage? = nil) -> String {
        let selected = language ?? self.language
        return String(format: text(key, language: selected), locale: selected.locale, arguments: arguments)
    }

    public static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(locale))
    }

    public static func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.day().month().year().hour().minute().second().locale(locale))
    }
}
