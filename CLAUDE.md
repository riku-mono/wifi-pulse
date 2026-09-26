# CLAUDE.md

Wi-Fi Pulse: Mac の Wi-Fi とネットワークを常時計測・診断する macOS ネイティブアプリ（SwiftUI）と、その周辺（LP・Web 版サンプル、予定）のモノレポ。
全体像は [README.md](README.md)、アプリの設計は [apps/macos/README.md](apps/macos/README.md)。

## 構成

- `apps/macos/` — Xcode プロジェクト（macOS 27 / Xcode 27 / Swift 6、既定のアクター分離は `MainActor`）
  - `WiFiPulse/{App,Core,Services,Views,Resources}`、`Info.plist` はフォルダの外
  - Bundle ID `me.riku-mono.WiFiPulse`（所有ドメイン `riku-mono.me`。今後の識別子も `me.riku-mono.*`）
- `apps/web/` — LP と Web 版サンプル（未着手）
- `docs/` — `distribution.md`（Mac App Store に出せない理由・配布方針）、`localization.md`（多言語対応のルール）
- `scripts/l10n-coverage.py` — 言語別カバレッジ
- `scripts/unregister-dev-builds.sh` — 開発用ビルドを LaunchServices の登録から外す
- `.github/workflows/l10n.yml` — カバレッジの CI（Ubuntu）

## ビルド・実行

```bash
cd apps/macos
xcodebuild -project WiFiPulse.xcodeproj -scheme WiFiPulse -configuration Debug -derivedDataPath build/DerivedData.noindex build
open build/DerivedData.noindex/Build/Products/Debug/WiFiPulse.app
```

- `project.pbxproj` は手書きで、ファイルシステム同期グループを使っている。`WiFiPulse/` にファイルを置けばターゲットに入る。**ターゲットの追加（テストなど）は Xcode の UI で行う**。
- ビルドしたアプリは LaunchServices に登録され、Spotlight に同じアプリが並ぶ。ビルド・起動の確認が済んだら `scripts/unregister-dev-builds.sh` で登録を外す（`/Applications` のものは残る）。ビルド先を `.noindex` にしてあるのは Spotlight の索引から外すため。
- App Sandbox は無効（`nettop`・`log`・`ping` などを使うため）。署名はアドホック。

## 守ること

### 文言（多言語対応）— 詳細は docs/localization.md
- **ソース言語は英語**。コードの文言は英語で書き、日本語訳を `Localizable.xcstrings` に入れる。
- `Text`/`Label`/`Button` などに直接渡す以外の文言は `String(localized:)`。常にリテラルを受ける自作の引数は `LocalizedStringKey`。
- チャートの系列名は `SeriesName` の定数を使う（凡例と色の対応表のキーを兼ねる）。
- 翻訳された文字列を比較・判定に使わない。文を細切れに連結しない（一覧は `formatted(.list(type: .and))`）。
- 文言を変えたら `xcodebuild -exportLocalizations …` でカタログを同期 → 日本語訳 → `scripts/l10n-coverage.py --update README.md`。CI は en/ja 100% と README の表が最新であることを検査する。
- 表示言語は既定でシステム設定に従い、設定 › 一般 › 言語 で上書きできる（`Core/AppLanguage.swift`、アプリのドメインの `AppleLanguages`、再起動で反映）。

### パフォーマンス — 詳細は apps/macos/README.md
- 毎秒の計測は `Monitor.live`（`LiveSnapshot`）に1回だけ組み立てる。履歴は `@ObservationIgnored` に置き、グラフは `revision` を読む。
- 常に表示される部分（メニューバー・サブタイトル・サイドバー）は、変化したときだけ更新されるプロパティ（`menu`・`networkTitle`・`connection`）を読む。
- グラフは `Equatable` なビューに分けて間引く。常時動くアニメーション・シンボルエフェクトは使わない。
- UI を変えたら **Release ビルドで CPU を測って比べる**（各画面を開いて30秒平均。`ps -o time=` の CPU 時間の差分から出すと確実。目安: 概要 1.3%、アプリの通信 2.8%＋nettop 0.6%）。

### 外部プロセス
- `nettop` は **疑似端末（pty）** につなぐ（パイプだと16KB単位でまとめて届き、行の途中で切れる）。
- `nettop` は標準入力が EOF だと空回りして CPU 100%超になる。見張り役の `sh`（`ProcessMonitor.watchdog`）を挟み、アプリが強制終了しても止まるようにしてある。外部プロセスを足したら `kill -9` 後に子プロセスが残らないか確認する。

### ネットワーク
- LAN の無いリンクがある。iPhone のテザリングでは `192.0.0.2/32`・`NOARP`・ゲートウェイ `192.0.0.1` になり、サブネットの外へ UDP を送ると `sendto` がカーネル内で回り続けて CPU 100% になる。LAN 宛ての送信はインターフェースのサブネットとフラグを見てから（`DeviceScanner.sweepTargets`）。

## 作業環境の制約（この Mac で Claude Code を使うとき）

- **画面キャプチャ・アクセシビリティ（System Events）の権限が無い**。見た目や操作の確認はユーザーに頼む。確認できていないことは PR に未チェックで残す。
- 起動時の表示言語などは統合ログで確認できる: `log show --info --last 5m --predicate 'subsystem == "me.riku-mono.WiFiPulse" AND category == "app"'`
- 起動時に開く画面は `defaults write me.riku-mono.WiFiPulse selectedView <overview|latency|neighbors|processes|…>` で指定できる（性能測定に使う）。

## 進め方

- main に直接コミットしない。ブランチ → PR（本文は日本語。確認したこと／できていないことをチェックリストで書く）。
- 残りの作業は GitHub の Issue: #2 テスト（Swift Testing）、#3 アプリアイコン（Icon Composer）、#4 CI（macOS でビルド・テスト）、#5 署名・公証・配布（Developer Program 加入待ち）。
