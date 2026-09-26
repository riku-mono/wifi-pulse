# 配布方法

## 結論

**Developer ID 署名＋公証（notarization）による直接配布**（LP からダウンロード）を主にする。
Mac App Store は、今の機能のままでは通らない。

## Mac App Store で配布できない理由

Mac App Store のアプリは **App Sandbox が必須**（App Review Guidelines 2.4.5）で、**公開 API だけを使う**必要がある（同 2.5.1）。
Wi-Fi Pulse の主要機能のいくつかは、この2つと両立しない。

| 機能 | 使っているもの | サンドボックス内で | 理由 |
|---|---|---|---|
| アプリの通信 | `/usr/bin/nettop` | ✕ | サンドボックス内のアプリが起動した子プロセスはサンドボックスを引き継ぐため、他プロセスの通信統計を読めない。同等の情報を得る公開 API も無い（nettop は非公開の NetworkStatistics を使っている） |
| Wi-Fi イベント | `/usr/bin/log show` | ✕ | 他プロセス（airportd など）の統合ログは読めない。公開 API の `OSLogStore` で読めるのは自プロセスのログだけ |
| 速度測定 | `/usr/bin/networkQuality` | ✕ | システムのコマンドラインツールをサンドボックス内から実行できない。自前で実装し直せば可能 |
| 常時計測の ping | `/sbin/ping` | △ | コマンドは実行できないが、ICMP ソケット（`SOCK_DGRAM` / `IPPROTO_ICMP`）で自前実装すれば `network.client` 権限で動く見込み（要検証） |
| LAN の機器 | ARP 表（sysctl）・`dig`・UDP スイープ | △ | ARP 表は sysctl で読むようにした。`dig` は Bonjour（`NWBrowser`）への置き換えが必要 |
| 経路の取得 | `route`・`ipconfig`・`networksetup` | △ | SystemConfiguration などの API で置き換えが必要 |
| Wi-Fi 接続・周辺スキャン | CoreWLAN | ○？ | 位置情報の許可があれば使える見込み（要検証） |
| 負荷試験 | URLSession | ○ | `network.client` 権限で動く |

○＝そのまま動く見込み、△＝実装し直せば動く見込み、✕＝不可

### Mac App Store 版を作るなら

「アプリの通信」と「Wi-Fi イベント」を外し、ping・ARP・経路取得を API で実装し直した **Lite 版** を別ターゲットとして作る形になる。
コードの大半（判定ロジック・グラフ・周辺 Wi-Fi）は共有できる。

## 直接配布に必要なもの

| 項目 | 必要なもの | 状態 |
|---|---|---|
| Developer ID Application 証明書 | Apple Developer Program（有料） | 未加入 |
| 公証 | 同上＋ `notarytool` | 未対応 |
| Hardened Runtime | ビルド設定 `ENABLE_HARDENED_RUNTIME = YES` | 未設定（公証の前提） |
| 自動アップデート | Sparkle など。配信情報（appcast）は `apps/web` から配信する想定 | 未対応 |
| 配布形式 | DMG か ZIP | 未対応 |

公証していないアプリは、ほかの Mac では Gatekeeper の警告が出て開きにくい。自分の Mac で使うだけならアドホック署名のままでよい。

## 識別子

- Bundle ID は所有ドメイン `riku-mono.me` を逆順にした `me.riku-mono.*` に揃える（例: `me.riku-mono.WiFiPulse`）。
- Bundle ID を変えると別アプリ扱いになり、設定（UserDefaults）と権限（位置情報など）が引き継がれない。**最初のリリースより前に確定させる。**
