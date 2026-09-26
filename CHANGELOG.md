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
- 英語対応（String Catalog。日本語がソース言語）
- 言語別カバレッジの集計スクリプト（`scripts/l10n-coverage.py`）と CI での検査

### Fixed
- 周辺の Wi-Fi で、暗号化されている OWE のネットワークを「危険」表示にしていた
