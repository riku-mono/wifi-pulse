import AppKit

/// アプリの外観（ライト・ダーク）。既定はシステム設定に従う。
///
/// `NSApp.appearance` に入れるので、メインウインドウ・メニューバーのパネル・設定ウインドウにまとめて効き、
/// 再起動は要らない。メニューバーのアイコンはメニューバー側の外観に従うので変わらない。
nonisolated enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    static let key = "appearance"

    var id: Self { self }

    var label: String {
        switch self {
        case .system: String(localized: "System Setting", comment: "外観の選択肢")
        case .light: String(localized: "Light", comment: "外観の選択肢")
        case .dark: String(localized: "Dark", comment: "外観の選択肢")
        }
    }

    /// `nil` はシステム設定に従う（自動の切り替えにも追従する）
    var nsAppearanceName: NSAppearance.Name? {
        switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    /// 保存されている選択。読めない値ならシステム設定に従う
    static func stored(_ defaults: UserDefaults = .standard) -> AppAppearance {
        defaults.string(forKey: key).flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    @MainActor
    static func apply(_ appearance: AppAppearance) {
        NSApplication.shared.appearance = appearance.nsAppearanceName.flatMap(NSAppearance.init(named:))
    }
}
