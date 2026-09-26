#!/usr/bin/env python3
"""String Catalog（.xcstrings）の言語別カバレッジを集計する。

    scripts/l10n-coverage.py                          # 表を表示
    scripts/l10n-coverage.py --require en=100         # en が 100% 未満なら終了コード 1
    scripts/l10n-coverage.py --update README.md       # README の表を書き換える
    scripts/l10n-coverage.py --check README.md        # README の表が最新でなければ終了コード 1
    scripts/l10n-coverage.py --json coverage.json     # 集計結果を JSON で保存

数え方:
- 対象は `shouldTranslate: false` でない文字列。ソースから消えた（`extractionState: stale`）ものは分母から除き、別に数える。
- 翻訳済みは、その言語のすべての文字列ユニット（複数形などの variation を含む）が `translated` のもの。
- ソース言語は常に 100%。
- GitHub Actions 上では、結果の表を Job Summary にも書き出す。

外部ライブラリは使わない（macOS 標準・Ubuntu 標準の python3 で動く）。
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from dataclasses import dataclass, field

MARK_START = "<!-- l10n-coverage:start -->"
MARK_END = "<!-- l10n-coverage:end -->"
DEFAULT_GLOB = "apps/**/*.xcstrings"


@dataclass
class LangStats:
    translated: int = 0
    needs_review: int = 0
    untranslated: int = 0

    def percent(self, total: int) -> float:
        return 100.0 if total == 0 else self.translated * 100.0 / total


@dataclass
class CatalogStats:
    path: str
    source: str
    total: int = 0
    stale: int = 0
    skipped: int = 0
    langs: dict[str, LangStats] = field(default_factory=dict)


def units(node) -> list[dict]:
    """localization の下にある stringUnit をすべて集める（複数形などの variations / substitutions の中も辿る）。"""
    found = []
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "stringUnit":
                found.append(value)
            elif isinstance(value, dict):
                found += units(value)
    return found


def analyze(path: str, languages: list[str]) -> CatalogStats:
    data = json.load(open(path, encoding="utf-8"))
    st = CatalogStats(path=path, source=data.get("sourceLanguage", "en"))
    strings = data.get("strings", {})
    langs = set(languages)
    for entry in strings.values():
        langs.update(entry.get("localizations", {}).keys())
    langs.discard(st.source)
    st.langs = {lang: LangStats() for lang in sorted(langs)}

    for entry in strings.values():
        if entry.get("shouldTranslate") is False:
            st.skipped += 1
            continue
        if entry.get("extractionState") == "stale":
            st.stale += 1
            continue
        st.total += 1
        locs = entry.get("localizations", {})
        for lang, ls in st.langs.items():
            us = units(locs.get(lang, {}))
            states = {u.get("state") for u in us}
            if us and states == {"translated"}:
                ls.translated += 1
            elif "needs_review" in states:
                ls.needs_review += 1
            else:
                ls.untranslated += 1
    return st


def merge(stats: list[CatalogStats]) -> tuple[int, dict[str, LangStats], str]:
    total = sum(s.total for s in stats)
    merged: dict[str, LangStats] = {}
    for s in stats:
        for lang, ls in s.langs.items():
            m = merged.setdefault(lang, LangStats())
            m.translated += ls.translated
            m.needs_review += ls.needs_review
            m.untranslated += ls.untranslated
    sources = {s.source for s in stats}
    return total, merged, ", ".join(sorted(sources))


def bar(pct: float, width: int = 10) -> str:
    filled = int(round(pct / 100 * width))
    return "█" * filled + "░" * (width - filled)


def markdown(stats: list[CatalogStats]) -> str:
    total, merged, source = merge(stats)
    lines = [
        "| 言語 | 翻訳済み | カバレッジ | 要確認 | 未翻訳 |",
        "|---|---:|---|---:|---:|",
        f"| `{source}`（ソース） | {total} / {total} | {bar(100)} 100.0% | 0 | 0 |",
    ]
    for lang, ls in sorted(merged.items()):
        pct = ls.percent(total)
        lines.append(f"| `{lang}` | {ls.translated} / {total} | {bar(pct)} {pct:.1f}% | {ls.needs_review} | {ls.untranslated} |")
    stale = sum(s.stale for s in stats)
    skipped = sum(s.skipped for s in stats)
    files = ", ".join(f"`{s.path}`" for s in stats)
    lines += ["", f"対象: {files}（翻訳不要 {skipped} 件・ソースから消えた文字列 {stale} 件は除外）"]
    return "\n".join(lines)


def replace_section(text: str, table: str) -> str:
    if MARK_START not in text or MARK_END not in text:
        raise SystemExit(f"マーカー {MARK_START} / {MARK_END} が見つかりません")
    head, rest = text.split(MARK_START, 1)
    _, tail = rest.split(MARK_END, 1)
    return f"{head}{MARK_START}\n{table}\n{MARK_END}{tail}"


def main() -> int:
    ap = argparse.ArgumentParser(description="String Catalog の言語別カバレッジを集計する")
    ap.add_argument("catalogs", nargs="*", help=f"対象の .xcstrings（既定: {DEFAULT_GLOB}）")
    ap.add_argument("--languages", default="", help="必ず表に出す言語（カンマ区切り。まだ1件も訳していない言語を載せるため）")
    ap.add_argument("--require", action="append", default=[], metavar="LANG=PCT",
                    help="この割合を下回ったら終了コード 1（例: en=100）。複数指定可")
    ap.add_argument("--update", metavar="FILE", help="FILE のマーカーの間を表で書き換える")
    ap.add_argument("--check", metavar="FILE", help="FILE の表が最新でなければ終了コード 1")
    ap.add_argument("--json", metavar="FILE", help="集計結果を JSON で保存する")
    args = ap.parse_args()

    paths = args.catalogs or sorted(glob.glob(DEFAULT_GLOB, recursive=True))
    if not paths:
        print("対象の .xcstrings がありません", file=sys.stderr)
        return 1
    languages = [x.strip() for x in args.languages.split(",") if x.strip()]
    stats = [analyze(p, languages) for p in paths]
    table = markdown(stats)
    print(table)

    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a", encoding="utf-8") as f:
            f.write("## 多言語対応のカバレッジ\n\n" + table + "\n")

    total, merged, _ = merge(stats)
    if args.json:
        out = {"total": total, "languages": {k: {"translated": v.translated, "needs_review": v.needs_review,
                                                   "untranslated": v.untranslated, "percent": round(v.percent(total), 2)}
                                              for k, v in merged.items()}}
        json.dump(out, open(args.json, "w", encoding="utf-8"), ensure_ascii=False, indent=2)

    status = 0
    for req in args.require:
        lang, _, pct = req.partition("=")
        if lang in {s.source for s in stats}:
            continue
        got = merged.get(lang, LangStats()).percent(total) if lang in merged else 0.0
        if got + 1e-9 < float(pct):
            print(f"✗ {lang}: {got:.1f}%（基準 {pct}%）", file=sys.stderr)
            status = 1

    if args.update:
        text = open(args.update, encoding="utf-8").read()
        open(args.update, "w", encoding="utf-8").write(replace_section(text, table))
    if args.check:
        text = open(args.check, encoding="utf-8").read()
        if replace_section(text, table) != text:
            print(f"✗ {args.check} のカバレッジ表が古いです。scripts/l10n-coverage.py --update {args.check} を実行してください",
                  file=sys.stderr)
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
