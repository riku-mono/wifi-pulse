import AppKit
import Foundation

/// アプリの表示言語。
///
/// 既定はシステム設定（システム設定 › 一般 › 言語と地域 の「優先する言語」）に従う。
/// 設定画面で選んだ言語は、macOS の「言語と地域 › アプリケーション」と同じく、
/// このアプリのドメインの `AppleLanguages` に書き込む。どちらで変えても同じ設定を指す。
/// 表示言語は起動時に決まるので、変更の反映には再起動が要る。
enum AppLanguage {
    private static let key = "AppleLanguages"

    /// アプリが対応している言語（`en`, `ja`）
    static var available: [String] {
        Bundle.main.localizations.filter { $0 != "Base" }.sorted()
    }

    /// いま表示に使っている言語（起動時に決まる）
    static var current: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

    /// アプリだけに設定された言語。`nil` ならシステム設定に従う。
    static var override: String? {
        get {
            guard let id = Bundle.main.bundleIdentifier,
                  let langs = UserDefaults.standard.persistentDomain(forName: id)?[key] as? [String],
                  let first = langs.first else { return nil }
            return match(first)
        }
        set {
            if let newValue {
                UserDefaults.standard.set([newValue], forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// システム設定に従った場合に使われる言語
    static var systemChoice: String {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[key] as? [String]
        return Bundle.preferredLocalizations(from: available, forPreferences: global ?? Locale.preferredLanguages).first ?? "en"
    }

    /// 次に起動したときに使われる言語
    static var nextLaunch: String { override ?? systemChoice }

    /// その言語自身の表記での名前（`ja` → 日本語、`en` → English）
    static func displayName(_ code: String) -> String {
        Locale(identifier: code).localizedString(forLanguageCode: code)?.localizedCapitalized ?? code
    }

    /// `ja-JP` のような地域つきの指定を、対応している言語に寄せる
    private static func match(_ identifier: String) -> String? {
        Bundle.preferredLocalizations(from: available, forPreferences: [identifier]).first
    }

    /// 今のプロセスが終わるのを待ってから起動し直す
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                             Bundle.main.bundlePath]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            NSSound.beep()
        }
    }
}
