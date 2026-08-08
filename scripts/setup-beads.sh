#!/usr/bin/env bash
#
# Beads をグローバルに導入する。何度実行しても結果が変わらない (冪等)。
#
#   ./scripts/setup-beads.sh
#
# 依存コマンド
#   bd と jq。いずれも本スクリプトは導入しない。未導入なら中止する。
#
# 実行内容
#   1. bd と jq の導入確認
#   2. 匿名利用統計の送信を停止
#   3. ~/.claude/settings.json のバックアップ (初回のみ)
#   4. bd 公式のグローバル SessionStart hook を導入 (bd prime)
#   5. タスク状態を復元する SessionStart hook を追加 (重複時は追加しない)
#   6. ~/.claude/rules/beads.md に運用ルールを配置

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${REPO_ROOT}/.logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/setup-beads-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

# shellcheck source=lib/rules.sh
. "${REPO_ROOT}/scripts/lib/rules.sh"

CLAUDE_DIR="${HOME}/.claude"
SETTINGS="${CLAUDE_DIR}/settings.json"
BACKUP="${CLAUDE_DIR}/settings.json.pre-beads.bak"
RULES_SRC="${REPO_ROOT}/rules/beads.md"
RULES_DST="${CLAUDE_DIR}/rules/beads.md"

# セッション開始時と compaction 後にタスク状態を復元する。
# beads 未導入のリポジトリでは全て失敗して無出力になり、末尾の true で正常終了する。
STATE_CMD='bd list --status=in_progress 2>/dev/null; bd ready 2>/dev/null; bd blocked 2>/dev/null; true'

# 応答を終える直前に、記録漏れの可能性があるときだけ通知する。
# 条件付き + レート制限でループを防いでいる。詳細はスクリプト冒頭のコメントを参照。
STOP_CMD="${REPO_ROOT}/scripts/beads-stop-nudge.sh"

echo "=== Beads グローバル導入 $(date '+%Y-%m-%d %H:%M:%S') ==="

# 1. 依存コマンドの確認
# 導入そのものは行わない。パッケージ管理の方式は環境ごとに異なり、
# スクリプトが特定の方式を前提にすると移植性を失うためである。
MISSING=0
for cmd in bd jq; do
  if command -v "${cmd}" >/dev/null 2>&1; then
    echo "[skip] ${cmd} は導入済み"
  else
    echo "[fail] ${cmd} が見つかりません。導入してから再実行してください" >&2
    MISSING=1
  fi
done
if [ "${MISSING}" -ne 0 ]; then
  echo "[fail] 依存コマンドが不足しているため中止した" >&2
  exit 1
fi
echo "       bd: $(bd version)"
echo "       jq: $(jq --version)"

# 2. 匿名利用統計
echo "[run ] 匿名利用統計を停止する"
bd metrics off >/dev/null 2>&1 || true

# 3. バックアップ
if [ -f "${BACKUP}" ]; then
  echo "[skip] バックアップは作成済み: ${BACKUP}"
elif [ -f "${SETTINGS}" ]; then
  cp -p "${SETTINGS}" "${BACKUP}"
  echo "[run ] バックアップを作成した: ${BACKUP}"
else
  echo "[skip] ${SETTINGS} が無いためバックアップは不要"
fi

# 4. bd 公式のグローバル hook
# --check は project 側 CLAUDE.md が無いと終了コード 1 を返す。pipefail の影響を避けるため
# 出力を変数に取ってから判定する。
CHECK_OUT="$(bd setup claude --check 2>&1 || true)"
if printf '%s' "${CHECK_OUT}" | grep -q "Global hooks installed"; then
  echo "[skip] bd prime の hook は導入済み"
else
  echo "[run ] bd prime の hook を導入する"
  # bd setup claude --global は cwd に project 用 CLAUDE.md も新規作成する。
  # グローバル導入では hook が文脈を注入するため不要なので、自分が作らせた分だけ元に戻す。
  CLAUDE_MD_EXISTED=0
  [ -f "${PWD}/CLAUDE.md" ] && CLAUDE_MD_EXISTED=1
  bd setup claude --global
  if [ "${CLAUDE_MD_EXISTED}" -eq 0 ] && [ -f "${PWD}/CLAUDE.md" ]; then
    rm "${PWD}/CLAUDE.md"
    echo "[run ] 副産物として生成された ${PWD}/CLAUDE.md を削除した"
  fi
fi

# 5. 状態復元 hook (冪等)
if [ ! -f "${SETTINGS}" ]; then
  echo '{}' > "${SETTINGS}"
fi

TMP="$(mktemp)"
# SessionStart はコマンド文字列がパスを含まないため、完全一致で判定できる。
#
# Stop はスクリプトの絶対パスを持つ。リポジトリの位置が変わると文字列が一致せず、
# 完全一致で判定すると古いエントリが残ったまま新しいエントリが増える。実際に
# 移設した環境で、同じ通知が 2 回発火する状態が発生した。
# そこでスクリプト名で判定し、該当するエントリをすべて取り除いてから現在のパスで
# 1 件だけ追加する。位置は末尾になる。
jq --arg cmd "${STATE_CMD}" --arg stop "${STOP_CMD}" '
  def is_nudge: (.hooks // []) | map(.command? // "") | any(endswith("beads-stop-nudge.sh"));
  .hooks //= {}
  | .hooks.SessionStart //= []
  | .hooks.Stop //= []
  | if ([.hooks.SessionStart[]?.hooks[]?.command] | index($cmd))
    then .
    else .hooks.SessionStart += [{"matcher": "", "hooks": [{"type": "command", "command": $cmd}]}]
    end
  | .hooks.Stop |= (
      map(select(is_nudge | not))
      + [{"matcher": "", "hooks": [{"type": "command", "command": $stop}]}]
    )
' "${SETTINGS}" > "${TMP}"

if [ ! -s "${TMP}" ] || ! jq -e . "${TMP}" >/dev/null 2>&1; then
  echo "[fail] settings.json の更新に失敗した。変更は適用していない" >&2
  rm -f "${TMP}"
  exit 1
fi

if diff -q "${SETTINGS}" "${TMP}" >/dev/null 2>&1; then
  echo "[skip] SessionStart と Stop の hook は導入済み"
  rm -f "${TMP}"
else
  cat "${TMP}" > "${SETTINGS}"
  rm -f "${TMP}"
  echo "[run ] SessionStart と Stop の hook を追加した"
fi

# 6. 運用ルール (symlink で配置。コピーしないためドリフトが起きない)
mkdir -p "${CLAUDE_DIR}/rules"
link_rule "${RULES_SRC}" "${RULES_DST}"

echo
echo "=== 導入後の SessionStart hook ==="
jq '.hooks.SessionStart' "${SETTINGS}"
echo
echo "完了。ログ: ${LOG_FILE}"
echo "Claude Code を再起動すると反映される。"
