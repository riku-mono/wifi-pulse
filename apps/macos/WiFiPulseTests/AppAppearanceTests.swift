import AppKit
import Foundation
import Testing
@testable import WiFiPulse

struct AppAppearanceTests {
    /// 保存先は使い捨てのドメインにする（アプリの設定を書き換えない）
    static func defaults() -> UserDefaults {
        let name = "AppAppearanceTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func defaultsToSystem() {
        #expect(AppAppearance.stored(Self.defaults()) == .system)
    }

    @Test func readsTheStoredChoice() {
        let d = Self.defaults()
        d.set("dark", forKey: AppAppearance.key)
        #expect(AppAppearance.stored(d) == .dark)
        d.set("light", forKey: AppAppearance.key)
        #expect(AppAppearance.stored(d) == .light)
    }

    @Test func unknownValueFallsBackToSystem() {
        let d = Self.defaults()
        d.set("sepia", forKey: AppAppearance.key)
        #expect(AppAppearance.stored(d) == .system)
    }

    /// システム設定に従うときは外観を指定しない（nil にするとシステムの自動切り替えにも追従する）
    @Test func appearanceNames() {
        #expect(AppAppearance.system.nsAppearanceName == nil)
        #expect(AppAppearance.light.nsAppearanceName == .aqua)
        #expect(AppAppearance.dark.nsAppearanceName == .darkAqua)
    }
}
