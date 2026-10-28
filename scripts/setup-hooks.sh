#!/usr/bin/env bash
#
# 規約を機械で守らせるフックをグローバルに導入する。何度実行しても結果が変わらない (冪等)。
#
#   ./scripts/setup-hooks.sh
#
# 依存コマンド
#   jq と python3。いずれも本スクリプトは導入しない。未導入なら中止する。
#
# 実行内容
#   1. jq と python3 の導入確認
#   2. ~/.claude/settings.json のバックアップ (初回のみ)
#   3. PreToolUse (Bash) に bash-guard.py、PostToolUse (Write と Edit) に md-lint.py を登録

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${REPO_ROOT}/.logs"
mkdir -p "${LOG_DIR}"
# ログ名は yyyymmddnn-<name>.log。nn は同じ日付・同じディレクトリ内の連番。
LOG_DAY="$(date +%Y%m%d)"
LOG_SEQ=1
while compgen -G "${LOG_DIR}/${LOG_DAY}$(printf '%02d' "${LOG_SEQ}")-*" >/dev/null; do LOG_SEQ=$((LOG_SEQ + 1)); done
LOG_FILE="$(printf '%s/%s%02d-setup-hooks.log' "${LOG_DIR}" "${LOG_DAY}" "${LOG_SEQ}")"
exec > >(tee -a "${LOG_FILE}") 2>&1

CLAUDE_DIR="${HOME}/.claude"
SETTINGS="${CLAUDE_DIR}/settings.json"
BACKUP="${CLAUDE_DIR}/settings.json.pre-hooks.bak"
BASH_GUARD="${REPO_ROOT}/scripts/hooks/bash-guard.py"
MD_LINT="${REPO_ROOT}/scripts/hooks/md-lint.py"

echo "=== 規約フックのグローバル導入 $(date '+%Y-%m-%d %H:%M:%S') ==="

# 1. 依存コマンドの確認
MISSING=0
for cmd in jq python3; do
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

# 2. バックアップ
if [ -f "${BACKUP}" ]; then
  echo "[skip] バックアップは作成済み: ${BACKUP}"
elif [ -f "${SETTINGS}" ]; then
  cp -p "${SETTINGS}" "${BACKUP}"
  echo "[run ] バックアップを作成した: ${BACKUP}"
else
  echo '{}' > "${SETTINGS}"
  echo "[run ] ${SETTINGS} を新規作成した"
fi

# 3. フックの登録
# setup-beads.sh の Stop フックと同じく、スクリプト名で既存のエントリを判定する。
# リポジトリを移設してもエントリが重複しないよう、該当するエントリを取り除いてから
# 現在のパスで 1 件だけ追加する。ほかのフックには触れない。
TMP="$(mktemp)"
jq --arg guard "${BASH_GUARD}" --arg lint "${MD_LINT}" '
  def has_script($name): (.hooks // []) | map(.command? // "") | any(endswith($name));
  .hooks //= {}
  | .hooks.PreToolUse //= []
  | .hooks.PostToolUse //= []
  | .hooks.PreToolUse |= (
      map(select(has_script("bash-guard.py") | not))
      + [{"matcher": "Bash", "hooks": [{"type": "command", "command": $guard}]}]
    )
  | .hooks.PostToolUse |= (
      map(select(has_script("md-lint.py") | not))
      + [{"matcher": "Write|Edit", "hooks": [{"type": "command", "command": $lint}]}]
    )
' "${SETTINGS}" > "${TMP}"

if [ ! -s "${TMP}" ] || ! jq -e . "${TMP}" >/dev/null 2>&1; then
  echo "[fail] settings.json の更新に失敗した。変更は適用していない" >&2
  rm -f "${TMP}"
  exit 1
fi

if diff -q "${SETTINGS}" "${TMP}" >/dev/null 2>&1; then
  echo "[skip] 規約フックは導入済み"
  rm -f "${TMP}"
else
  cat "${TMP}" > "${SETTINGS}"
  rm -f "${TMP}"
  echo "[run ] 規約フックを登録した"
fi

echo
echo "=== 導入後の PreToolUse と PostToolUse ==="
jq '{PreToolUse: .hooks.PreToolUse, PostToolUse: .hooks.PostToolUse}' "${SETTINGS}"
echo
echo "完了。ログ: ${LOG_FILE}"
echo "Claude Code を再起動すると反映される。"
