# Wi-Fi Pulse

Mac の Wi-Fi とネットワークの状態を常時計測し、「遅いのはどこか」を切り分けるための macOS ネイティブアプリと、その周辺（LP・Web 版サンプル）のモノレポ。

> **ステータス**: 開発初期（0.1.0 未リリース）。署名はローカル実行用のアドホック署名のみ。

## できること

| 機能 | 内容 |
|---|---|
| 常時計測 | ルーター宛て・インターネット宛て（IPv4/IPv6）の ping を同時に取り、Wi-Fi 区間と回線区間の遅延を分けて表示 |
| Wi-Fi 接続 | RSSI・ノイズ・SN比・チャンネル・規格・リンク速度（CoreWLAN）、DFS チャンネルの警告 |
| 周辺の Wi-Fi | スペクトラム表示（各 AP のチャンネル幅と強さ）、チャンネル別の混雑度とおすすめ、AP 一覧（規格・セキュリティ・BSS Load・メーカー） |
| アプリの通信 | アプリ／プロセスごとの送受信量・接続先・RTT・TCP 再送（`nettop`） |
| LAN の機器 | ARP・OUI（同梱のオフライン表）・mDNS 名による機器一覧 |
| 診断 | `networkQuality` による速度と応答性（RPM）、バッファブロート試験、統合ログからの Wi-Fi イベント抽出 |
| 記録 | 1分ごとの集計を保存し、時間帯別の傾向と所見を表示 |
| メニューバー | 状態の常時表示。ウインドウを閉じても計測は続く |

ルーターや Mac の設定は一切変更しない（読み取りのみ）。

## リポジトリ構成

```
wifi-pulse/
├── apps/
│   ├── macos/      macOS アプリ（SwiftUI / Xcode プロジェクト）
│   └── web/        LP と Web 版サンプル（予定）
├── docs/           設計・配布・多言語対応に関する資料
├── scripts/        開発用スクリプト（多言語カバレッジの集計など）
├── CHANGELOG.md
└── LICENSE
```

## 必要な環境

- macOS 27 以降
- Xcode 27 以降（Swift 6）

## ビルドと実行

```bash
cd apps/macos
open WiFiPulse.xcodeproj            # Xcode で ⌘R

# コマンドラインから
xcodebuild -project WiFiPulse.xcodeproj -scheme WiFiPulse \
  -configuration Debug -derivedDataPath build/DerivedData.noindex build
open build/DerivedData.noindex/Build/Products/Debug/WiFiPulse.app
```

開発時のアーキテクチャやパフォーマンスの方針は [apps/macos/README.md](apps/macos/README.md) を参照。

## 権限

| 権限 | 用途 | 未許可のとき |
|---|---|---|
| 位置情報 | SSID・BSSID・ビーコンの詳細（macOS の仕様で位置情報の許可が必要） | ネットワーク名・BSSID・メーカー・利用率が出ない |
| ローカルネットワーク | LAN の機器一覧 | 機器一覧が空になる |

## 対応言語

英語（ソース言語）と日本語。表示言語は既定でシステム設定に従い、アプリの設定（一般 › 言語）か、システム設定 › 一般 › 言語と地域 › アプリケーション で変更できる。
文言は String Catalog（`.xcstrings`）で管理している。追加・翻訳の手順は [docs/localization.md](docs/localization.md)。

<!-- l10n-coverage:start -->
| 言語 | 翻訳済み | カバレッジ | 要確認 | 未翻訳 |
|---|---:|---|---:|---:|
| `en`（ソース） | 534 / 534 | ██████████ 100.0% | 0 | 0 |
| `ja` | 534 / 534 | ██████████ 100.0% | 0 | 0 |

対象: `apps/macos/WiFiPulse/InfoPlist.xcstrings`, `apps/macos/WiFiPulse/Localizable.xcstrings`（翻訳不要 32 件・ソースから消えた文字列 0 件は除外）
<!-- l10n-coverage:end -->

## 配布について

App Sandbox を使えない機能（`nettop`・統合ログ・システムコマンドの実行）があるため、Mac App Store では配布できない。
Developer ID 署名＋公証による直接配布を想定している。詳しくは [docs/distribution.md](docs/distribution.md)。

## データ

計測記録は `~/Library/Application Support/WiFiPulse/` に JSON Lines で保存する（設定で変更可）。
MAC アドレスや機器名を含むため、人に渡すときは注意すること。

## ロードマップ

- [ ] テストターゲット（#2）
- [ ] アプリアイコン（#3）
- [ ] CI（#4）
- [ ] Developer ID 署名・公証・自動アップデート（#5）
- [ ] `apps/web`: LP と Web 版サンプル

## ライセンス

All rights reserved. [LICENSE](LICENSE) を参照。
