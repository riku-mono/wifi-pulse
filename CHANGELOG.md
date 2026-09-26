# Changelog

このプロジェクトの主な変更を記録する。形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に、バージョンは [Semantic Versioning](https://semver.org/lang/ja/) に従う。

## [Unreleased]

### Added
- macOS アプリの最初の版（SwiftUI / macOS 27）
  - 常時計測（ルーター・IPv4・IPv6 の同時 ping、Wi-Fi 区間と回線区間の切り分け）
  - Wi-Fi 接続の詳細と信号・ノイズの推移
  - 周辺の Wi-Fi: スペクトラム、チャンネル別混雑度とおすすめ、AP 一覧
  - アプリの通信: プロセス別の通信量・接続先・RTT・再送
  - LAN の機器一覧、速度測定、負荷試験、Wi-Fi イベント、時間帯別レポート
  - メニューバー表示
- 英語・日本語対応（String Catalog。英語がソース言語）
- 表示言語の設定（既定はシステム設定に従う。設定画面から English / 日本語 を選べ、再起動で反映）
- 言語別カバレッジの集計スクリプト（`scripts/l10n-coverage.py`）と CI での検査

### Fixed
- ネットワークが変わっても計測記録が混ざっていた。記録をネットワーク（ルーター）ごとに分け、傾向とレポートでネットワークを選べるようにした。速度測定の履歴と LAN の機器一覧は、いまのネットワークの分だけ表示する（#7）
- 周辺の Wi-Fi で、暗号化されている OWE のネットワークを「危険」表示にしていた
