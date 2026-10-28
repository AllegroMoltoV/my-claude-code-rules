#!/usr/bin/env python3
"""PostToolUse フック (Write、Edit)。documentation.md の表記規則のうち、字句で判定できるものを検査する。

- 全角かっこ (（ ）) と全角コロン (：)
- 日本語の文字に隣接する ASCII のダブルクオート

検査するのは、作業中のディレクトリの配下にある .md ファイルへ書いた文字列だけである。
Write は書いた本文全体、Edit は置き換えた後の文字列を見る。既存の箇所までは遡らない。
フロントマター、コードブロック、インラインコードは除く。設定値やコードの中の記号は規則の対象外のため。

PostToolUse は書き込みを取り消さない。違反があれば終了コード 2 で箇所を標準エラーに出し、
Claude に修正させる。
"""
import json
import re
import sys
from pathlib import Path

JA = r"[぀-ヿ㐀-鿿々ー]"
CHECKS = [
    (re.compile(r"[（）]"), "全角かっこ"),
    (re.compile(r"："), "全角コロン"),
    (re.compile(rf'{JA}"|"{JA}'), "日本語に隣接するダブルクオート"),
]
INLINE_CODE = re.compile(r"`[^`]*`")
FENCE = re.compile(r"^\s*(```|~~~)")


def prose_lines(text):
    lines = text.split("\n")
    start = 0
    if lines and lines[0].strip() == "---":
        for i in range(1, len(lines)):
            if lines[i].strip() == "---":
                start = i + 1
                break
    in_fence = False
    for line in lines[start:]:
        if FENCE.match(line):
            in_fence = not in_fence
            continue
        if not in_fence:
            yield line


def within(path, root):
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def main():
    # Claude Code は UTF-8 で渡し、UTF-8 で読む。Windows の既定 (cp932) のままだと日本語を読み違え、違反を見逃す
    sys.stdin.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 0
    tool_input = data.get("tool_input") or {}
    file_path = tool_input.get("file_path") or ""
    if not file_path.endswith(".md"):
        return 0
    cwd = data.get("cwd") or ""
    if not cwd or not within(Path(file_path), Path(cwd)):
        return 0
    text = tool_input.get("content") or tool_input.get("new_string") or ""

    findings = []
    for line in prose_lines(text):
        prose = INLINE_CODE.sub("", line)
        for pattern, label in CHECKS:
            if pattern.search(prose):
                findings.append(f"- {label}: {line.strip()[:80]}")
    if not findings:
        return 0
    print(f"{file_path} に documentation.md の表記規則に反する箇所があります。外部の文章を原文のまま引用した箇所を除き、修正してください。", file=sys.stderr)
    for finding in findings[:10]:
        print(finding, file=sys.stderr)
    if len(findings) > 10:
        print(f"- ほか {len(findings) - 10} 件", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
