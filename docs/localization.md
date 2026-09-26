# 多言語対応

## 構成

| ファイル | 中身 |
|---|---|
| `apps/macos/WiFiPulse/Localizable.xcstrings` | 画面の文言 |
| `apps/macos/WiFiPulse/InfoPlist.xcstrings` | `Info.plist` の文言（位置情報・ローカルネットワークの権限の説明など） |
| `scripts/l10n-coverage.py` | 言語別カバレッジの集計 |
| `.github/workflows/l10n.yml` | カバレッジの検査（CI） |

- **ソース言語は日本語（`ja`）**。キーは日本語の原文そのもの。
- 対応言語: 日本語・英語。言語はプロジェクトの `knownRegions` とカタログのエントリで決まる。
- macOS の「システム設定 › 一般 › 言語と地域 › アプリケーション」でアプリごとに言語を切り替えられる。

## 文言を書くときのルール

コンパイラが翻訳対象として抽出できる書き方にする。抽出されない文字列は翻訳されずに日本語のまま出る。

| 場所 | 書き方 |
|---|---|
| SwiftUI の `Text` / `Label` / `Button` / `Section` / `.help` / `.navigationTitle` などに直接渡す | 文字列リテラルのままでよい（`LocalizedStringKey` として抽出される） |
| 自作ビューの引数・モデル・判定ロジック・エラーメッセージなど、`String` として扱う文言 | `String(localized: "…")` で包む |
| 自作ビューの見出しなど、常にリテラルを渡す引数 | 引数の型を `LocalizedStringKey` にする（例: `row(_ title: LocalizedStringKey, …)`） |
| チャートの系列名（凡例と色の対応表のキーを兼ねる） | `SeriesName` の定数を使う。マークと `chartForegroundStyleScale` で同じ値を使わないと色が付かない |
| 値を埋め込む文 | `String(localized: "重なり \(n) 件")` のように補間で書く。キーは `重なり %lld 件` になる |
| 曜日・日時・数値・バイト数 | 文字列で組み立てず `formatted()`（`FormatStyle`）に任せる |

やってはいけないこと:

- **翻訳された文字列を比較・判定に使う**（`label.contains("オープン")` など）。英語では一致しなくなる。判定は `Bool` や enum で持つ
- **文を細切れにして連結する**。語順が言語で変わるので、1文を1つのキーにして値を補間で埋め込む
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
- CI（`l10n.yml`）では `ja`・`en` が 100% であることと、README の表が最新であることを検査する。結果は GitHub Actions の Job Summary に表で出る。
- 新しい言語を追加するときは、最初は基準に入れず、揃ってから `--require <言語>=100` を足す。

### 検査できていないこと

CI は Ubuntu 上でカタログ（JSON）を読むだけなので、**コードに新しい文言を足したのにカタログへ同期していない**ことは検出できない。
macOS の CI（#4）ができたら、`xcodebuild -exportLocalizations` の実行後にカタログに差分が出ないことも検査する。
