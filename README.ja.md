<p align="center"><img src="assets/app-icon.png" width="128" alt=""></p>

<h1 align="center">Wi-Fi Pulse</h1>

<p align="center">
  Mac の Wi-Fi とネットワークを常時計測して、<br>
  遅いのが <em>どこか</em>（Wi-Fi・ルーター・回線）を切り分ける macOS アプリ
</p>

<p align="center">
  <a href="README.md">English</a> · <strong>日本語</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-27%2B-000000?logo=apple&logoColor=white" alt="macOS 27+">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/SwiftUI-native-0A84FF" alt="SwiftUI">
  <a href="https://github.com/riku-mono/wifi-pulse/actions/workflows/l10n.yml"><img src="https://github.com/riku-mono/wifi-pulse/actions/workflows/l10n.yml/badge.svg" alt="Localization"></a>
  <img src="https://img.shields.io/badge/license-proprietary-lightgrey" alt="License: proprietary">
</p>

> [!NOTE]
> 開発初期（0.1.0 未リリース）。署名はローカル実行用のアドホック署名のみ。

## できること

| | |
|---|---|
| **常時計測** | ルーター宛てとインターネット宛て（IPv4/IPv6）の ping を同時に取り、Wi-Fi 区間と回線区間の遅延を分けて表示 |
| **Wi-Fi 接続** | RSSI・ノイズ・SN比・チャンネル・規格・リンク速度（CoreWLAN）、DFS チャンネルの警告 |
| **周辺の Wi-Fi** | スペクトラム表示、チャンネル別の混雑度とおすすめ、AP の一覧 |
| **アプリの通信** | アプリ／プロセスごとの送受信量・接続先・RTT・TCP 再送（`nettop`） |
| **LAN の機器** | ARP・OUI（同梱のオフライン表）・mDNS 名による機器の一覧 |
| **診断** | `networkQuality` による速度と応答性（RPM）、バッファブロート試験、統合ログからの Wi-Fi イベント |
| **記録** | ネットワークごとに1分単位で集計を保存し、時間帯別の傾向と所見を表示 |
| **メニューバー** | 状態を常に表示。ウインドウを閉じても計測は続く |

ルーターや Mac の設定は一切変えない（読み取りのみ）。

## 必要な環境

- macOS 27 以降
- ビルドには Xcode 27 以降（Swift 6）

## ビルドと実行

```bash
cd apps/macos
open WiFiPulse.xcodeproj            # Xcode で ⌘R
```

<details>
<summary>コマンドラインから</summary>

```bash
cd apps/macos
xcodebuild -project WiFiPulse.xcodeproj -scheme WiFiPulse \
  -configuration Debug -derivedDataPath build/DerivedData.noindex build
open build/DerivedData.noindex/Build/Products/Debug/WiFiPulse.app

# ユニットテスト
xcodebuild -project WiFiPulse.xcodeproj -scheme WiFiPulse \
  -configuration Debug -derivedDataPath build/DerivedData.noindex test
```

</details>

設計とパフォーマンスの方針は [apps/macos/README.md](apps/macos/README.md) を参照。

<details>
<summary>権限</summary>

| 権限 | 用途 | 許可しないとき |
|---|---|---|
| 位置情報 | SSID・BSSID・ビーコンの詳細（macOS の仕様で位置情報の許可が必要） | ネットワーク名・BSSID・メーカー・利用率が出ない |
| ローカルネットワーク | LAN の機器の一覧 | 機器の一覧が空になる |

</details>

<details>
<summary>記録データ</summary>

計測の記録は `~/Library/Application Support/WiFiPulse/` に JSON Lines で保存する（設定で変更できる）。
MAC アドレスや機器名を含むので、人に渡すときは注意すること。

</details>

## 対応言語

英語（ソース言語）と日本語。表示言語は既定でシステム設定に従い、アプリの 設定 › 一般 › 言語 で変えられる。
文言は String Catalog（`.xcstrings`）で管理している。手順は [docs/localization.md](docs/localization.md)。

<!-- l10n-coverage:start -->
| 言語 | 翻訳済み | カバレッジ | 要確認 | 未翻訳 |
|---|---:|---|---:|---:|
| `en`（ソース） | 542 / 542 | ██████████ 100.0% | 0 | 0 |
| `ja` | 542 / 542 | ██████████ 100.0% | 0 | 0 |

対象: `apps/macos/WiFiPulse/InfoPlist.xcstrings`, `apps/macos/WiFiPulse/Localizable.xcstrings`（翻訳不要 32 件・ソースから消えた文字列 0 件は除外）
<!-- l10n-coverage:end -->

## 配布について

App Sandbox の中では動かせない機能（`nettop`・統合ログ・システムコマンドの実行）があるため、Mac App Store では配布できない。
Developer ID 署名と公証による直接配布を予定している。詳しくは [docs/distribution.md](docs/distribution.md)。

## リポジトリ構成

```
wifi-pulse/
├── apps/
│   ├── macos/      macOS アプリ（SwiftUI / Xcode プロジェクト）
│   └── web/        LP と Web 版サンプル（予定）
├── assets/         README・LP 用のアプリアイコンの画像
├── docs/           配布・多言語対応の資料
└── scripts/        開発用スクリプト（多言語カバレッジの集計など）
```

## ロードマップ

- [ ] 残りのユニットテスト: ネットワークの切り替え（[#2](https://github.com/riku-mono/wifi-pulse/issues/2)）
- [x] アプリアイコン（[#3](https://github.com/riku-mono/wifi-pulse/issues/3)）
- [ ] CI: macOS でのビルドとテスト（[#4](https://github.com/riku-mono/wifi-pulse/issues/4)）
- [ ] Developer ID 署名・公証・自動アップデート（[#5](https://github.com/riku-mono/wifi-pulse/issues/5)）
- [ ] `apps/web`: LP と Web 版サンプル

## 開発に参加する

[CONTRIBUTING.md](CONTRIBUTING.md) を参照。セキュリティの問題は [SECURITY.md](SECURITY.md) の方法で報告してください。

## ライセンス

All rights reserved. [LICENSE](LICENSE) を参照。
