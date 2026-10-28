#!/usr/bin/env python3
"""PreToolUse フック (Bash)。project.md の規約のうち、字句で確実に判定できる 2 つだけを止める。

- 先頭が cd <dir> && で始まるコマンド。cd は単独で実行し、次の呼び出しで続ける
- git に続けて -C を渡すコマンド。cd してから git を実行する

&& や | による連結全般は対象にしない。制御構文 (for ...; do) やコマンド置換 ("$(a | b)") に
正当な用法があり、字句の判定では誤検出と見逃しが避けられないため、文章の規約に任せる。

止めるときは終了コード 2 で理由を標準エラーに出す。Claude Code はこれを Claude へ返す。
python3 が無い環境では Claude Code がフックの失敗として扱い、コマンドは止まらない。
"""
import json
import shlex
import sys


def tokens(command):
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    return list(lexer)


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 0
    command = (data.get("tool_input") or {}).get("command") or ""
    try:
        toks = tokens(command)
    except ValueError:
        # 引用符が閉じていないなど、字句に分けられないコマンドは判定しない
        return 0

    reasons = []
    if len(toks) >= 3 and toks[0] == "cd" and toks[2] == "&&":
        reasons.append("cd と後続のコマンドを && で連結しています。cd を単独の Bash 呼び出しで実行し、続くコマンドは次の呼び出しに分けてください。")
    if any(a == "git" and b == "-C" for a, b in zip(toks, toks[1:])):
        reasons.append("git -C を使っています。cd で対象のディレクトリへ移ってから git を実行してください。")

    if reasons:
        print("project.md の規約によりこのコマンドを止めました。", file=sys.stderr)
        for reason in reasons:
            print(f"- {reason}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
