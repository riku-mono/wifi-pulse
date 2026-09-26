# Wi-Fi Pulse for macOS

SwiftUI 製の macOS アプリ本体。

- Bundle ID: `me.riku-mono.WiFiPulse`
- Deployment target: macOS 27
- Swift 6（既定のアクター分離は `MainActor`、Approachable Concurrency 有効）
- App Sandbox: 無効（理由は [../../docs/distribution.md](../../docs/distribution.md)）

## 構成

```
WiFiPulse/
├── App/        エントリポイント、AppModel、メニューコマンド
├── Core/       統計・判定・保存形式・シェル実行などの共通部品
├── Services/   計測器（Monitor, Pinger, ProcessMonitor, NeighborScanner, …）
├── Views/      画面ごとの SwiftUI ビュー
└── Resources/  OUI 表（MAC アドレス → メーカー名、IEEE 公開データ）
```

Xcode のファイルシステム同期グループを使っているので、`WiFiPulse/` にファイルを置くだけでプロジェクトに含まれる。

## データの流れ

| 計測器 | 取得元 | 頻度 | 動く条件 |
|---|---|---|---|
| `Monitor` | CoreWLAN・`getifaddrs`・`Pinger` ×3・`dig` | 1秒（DNS は10秒） | 常時 |
| `DeviceScanner` | UDP スイープ・`arp`・mDNS 逆引き | 20秒 | 常時 |
| `ProcessMonitor` | `nettop`（疑似端末経由） | 2秒 | 「アプリの通信」を開いている間 |
| `NeighborScanner` | CoreWLAN スキャン | 手動／自動（30秒〜） | 「周辺の Wi-Fi」 |
| `SpeedTest` / `LoadTest` / `WiFiEvents` | `networkQuality`・URLSession・`log show` | 手動 | ボタンを押したとき |

## パフォーマンスの方針

計測値の更新でビューツリー全体が描き直されないことを最優先にしている。

- 計測値は1秒に1回だけ `LiveSnapshot` に組み立て、ビューはそれを読むだけ。履歴は観測対象外（`@ObservationIgnored`）に置き、`revision` を読んだビューだけが参照する。
- 常に表示されている部分（メニューバーのアイコン・ウインドウのサブタイトル・サイドバー）は、値が変わったときだけ更新されるプロパティ（`menu`・`networkTitle`・`connection`）を読む。
- グラフは `Equatable` なビューに分け、入力が同じなら描き直さない。範囲の広いグラフは間引いて更新する。
- 毎秒のアニメーション・常時動くシンボルエフェクトは使わない。
- CoreWLAN・カウンタ・ping の取り出しはメインスレッドの外（`@concurrent`）で行う。

### 外部プロセスの注意

- `nettop` はパイプにつなぐと 16KB 単位でまとめて書き出す（数秒遅れ・行の途中で切れる）ので、疑似端末につないで1行ずつ受ける。
- `nettop` は標準入力が EOF だと空回りして CPU を100%以上使う。macOS には親の終了で子を止める仕組みが無いため、見張り役の `sh` を挟み、アプリがどう終わっても（強制終了・クラッシュを含む）nettop が止まるようにしている。

### 計測方法

Release ビルドで各画面を開き、`top` で30秒平均を取る。

```bash
defaults write me.riku-mono.WiFiPulse selectedView overview   # 起動時に開く画面
top -l 16 -s 2 -stats pid,command,cpu -pid $(pgrep -x WiFiPulse)
```

2026-09 時点の目安（Apple Silicon）: 概要 1.3%、遅延（60分表示）1.7%、周辺の Wi-Fi 0.6%、アプリの通信 2.8%＋nettop 0.6%。

## データ形式

`~/Library/Application Support/WiFiPulse/` に JSON Lines で保存する。

| ファイル | 内容 |
|---|---|
| `minutes.jsonl` | 1分ごとの集計（遅延の中央値・p95・ロス率・RSSI・通信量） |
| `speedtests.jsonl` | 速度測定の結果 |
| `loadtests.jsonl` | 負荷試験の結果 |
| `devices.json` / `device_names.json` | LAN の機器と、付けた名前 |
| `networks.json` | 計測したネットワーク（識別子・SSID・ゲートウェイ） |

記録はネットワークごとに分ける。各レコードの `net` がネットワークの識別子で、ルーター（ゲートウェイ）の MAC アドレス（取れないときは `ip:<ゲートウェイ>`）。位置情報の許可が無くても取れ、メッシュ Wi-Fi の中継機を移っても変わらない。`minutes.jsonl` にはその1分の `bssid`（アクセスポイント。位置情報の許可があるときだけ）も入る。`net` の無いレコードはこの項目を入れる前の記録。

- ネットワークが変わると、変化を検知した時点で直近の履歴と1分バッファを区切る（前の分は前のネットワークとして書き出す。10秒未満の切れ端は捨てる）。切断中は区切らないので、一瞬切れて同じネットワークに戻っても履歴は続く。
- 傾向とレポートは既定でいまのネットワークを表示し、ツールバーでほかのネットワーク・不明・すべてを選べる。速度測定の履歴と LAN の機器一覧は、いまのネットワークの分だけ表示する。
