# 多言語対応

## 構成

| ファイル | 中身 |
|---|---|
| `apps/macos/WiFiPulse/Localizable.xcstrings` | 画面の文言 |
| `apps/macos/WiFiPulse/InfoPlist.xcstrings` | `Info.plist` の文言（位置情報・ローカルネットワークの権限の説明など） |
| `scripts/l10n-coverage.py` | 言語別カバレッジの集計 |
| `.github/workflows/l10n.yml` | カバレッジの検査（CI） |

- **ソース言語は英語（`en`）**。コードには英語で書き、キーは英語の原文そのもの。日本語は翻訳として入れる。
- 対応言語: 英語・日本語。言語はプロジェクトの `knownRegions`（開発言語 `developmentRegion = en`）とカタログのエントリで決まる。
- `Info.plist` 本体の文言（権限の説明）も英語で書き、日本語は `InfoPlist.xcstrings` に入れる。

## 表示言語の選び方

- **既定はシステム設定に従う**（システム設定 › 一般 › 言語と地域 の「優先する言語」から、対応している言語を選ぶ）。
- アプリの 設定 › 一般 › 言語 で「システム設定に従う / English / 日本語」を選べる。
- 仕組みは macOS の「言語と地域 › アプリケーション」と同じで、アプリのドメインの `AppleLanguages` に書き込む（`AppLanguage.swift`）。どちらで変えても同じ設定を指す。
- 表示言語は起動時に決まるので、変更は再起動で反映される。設定画面の「今すぐ再起動」で、今のプロセスの終了を待ってから起動し直す。
- 起動時の言語は統合ログに出る:
  ```bash
  log show --info --last 5m --predicate 'subsystem == "me.riku-mono.WiFiPulse" AND category == "app"'
  ```
- 開発中に一時的に言語を切り替えて起動する:
  ```bash
  open WiFiPulse.app --args -AppleLanguages '(ja)'
  ```

## 文言を書くときのルール

コンパイラが翻訳対象として抽出できる書き方にする。抽出されない文字列は翻訳されずに日本語のまま出る。

| 場所 | 書き方 |
|---|---|
| SwiftUI の `Text` / `Label` / `Button` / `Section` / `.help` / `.navigationTitle` などに直接渡す | 文字列リテラルのままでよい（`LocalizedStringKey` として抽出される） |
| 自作ビューの引数・モデル・判定ロジック・エラーメッセージなど、`String` として扱う文言 | `String(localized: "…")` で包む |
| 自作ビューの見出しなど、常にリテラルを渡す引数 | 引数の型を `LocalizedStringKey` にする（例: `row(_ title: LocalizedStringKey, …)`） |
| チャートの系列名（凡例と色の対応表のキーを兼ねる） | `SeriesName` の定数を使う。マークと `chartForegroundStyleScale` で同じ値を使わないと色が付かない |
| 値を埋め込む文 | `String(localized: "Overlaps: \(n)")` のように補間で書く。キーは `Overlaps: %lld` になる |
| 曜日・日時・数値・バイト数 | 文字列で組み立てず `formatted()`（`FormatStyle`）に任せる |

やってはいけないこと:

- **翻訳された文字列を比較・判定に使う**（`label.contains("Open")` など）。日本語では一致しなくなる。判定は `Bool` や enum で持つ
- **文を細切れにして連結する**。語順が言語で変わるので、1文を1つのキーにして値を補間で埋め込む。列挙は `formatted(.list(type: .and))` に任せる（日本語は「A、B、C」、英語は「A, B, and C」）
- **英語で意味が違う2つの文言に同じ英文を使う**。キーが同じになり、日本語訳を分けられない（例: 保存先は "Folder"、アプリの場所は "Path"）
- 翻訳が要らない記号・単位・コマンド例は、カタログで「翻訳しない（Don't Translate）」にする

## 文言を追加・変更したら

1. Xcode でビルドすると、カタログに新しいキーが追加される（状態は「新規」）。
   コマンドラインなら次でカタログをソースと同期できる:
   ```bash
   xcodebuild -exportLocalizations -project apps/macos/WiFiPulse.xcodeproj \
     -localizationPath /tmp/wifipulse-loc -exportLanguage en
   ```
2. Xcode でカタログを開き、各言語の訳を入れる。
   - 値を2つ以上埋め込む文は、語順が変わっても崩れないよう `%1$@`・`%2$lld` のように番号付きの指定子を使う
   - 英語で数によって形が変わる文は、「Vary by Plural」で `one` / `other` を分けるか、「ラベル: 数値」の形にして複数形を避ける
   - 英語では付けない単位（「件」「回」など）は、明示的なキーで書く: `String(localized: "unit.runs", defaultValue: "", comment: "…")` に日本語訳「回」を入れる
3. カバレッジを確認し、README の表を更新する:
   ```bash
   scripts/l10n-coverage.py --update README.md
   ```

ソースから消えた文字列は、カタログ上で「Stale」になる。カバレッジの分母からは外れるが、不要なら削除する。

## カバレッジ

```bash
scripts/l10n-coverage.py                                  # 表を表示
scripts/l10n-coverage.py --require en=100                 # 基準を下回ったら終了コード 1
scripts/l10n-coverage.py --languages fr                   # まだ訳の無い言語も表に出す
scripts/l10n-coverage.py --json coverage.json             # JSON で保存
```

- 対象は「翻訳しない」以外の文字列。複数形などの variation は、すべてが翻訳済みのときだけ翻訳済みと数える。
- CI（`l10n.yml`）では `en`（ソース）・`ja` が 100% であることと、README の表が最新であることを検査する。結果は GitHub Actions の Job Summary に表で出る。
- 新しい言語を追加するときは、最初は基準に入れず、揃ってから `--require <言語>=100` を足す。

### 検査できていないこと

CI は Ubuntu 上でカタログ（JSON）を読むだけなので、**コードに新しい文言を足したのにカタログへ同期していない**ことは検出できない。
macOS の CI（#4）ができたら、`xcodebuild -exportLocalizations` の実行後にカタログに差分が出ないことも検査する。
