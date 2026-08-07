#!/usr/bin/env bash
#
# Beads のグローバル導入を取り消す。
#
#   ./scripts/teardown-beads.sh            # hook と運用ルールを削除する
#   ./scripts/teardown-beads.sh --restore  # settings.json をバックアップから完全復元する
#
# bd CLI 自体は削除しない。削除する場合は導入時に使った方法で取り除くこと。
# 各リポジトリの .beads/ も削除しない。タスク状態が失われるため手動で判断すること。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${REPO_ROOT}/.logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/teardown-beads-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

CLAUDE_DIR="${HOME}/.claude"
SETTINGS="${CLAUDE_DIR}/settings.json"
BACKUP="${CLAUDE_DIR}/settings.json.pre-beads.bak"
RULES_DST="${CLAUDE_DIR}/rules/beads.md"

STATE_CMD='bd list --status=in_progress 2>/dev/null; bd ready 2>/dev/null; bd blocked 2>/dev/null; true'
STOP_CMD="${REPO_ROOT}/scripts/beads-stop-nudge.sh"

echo "=== Beads グローバル導入の取り消し $(date '+%Y-%m-%d %H:%M:%S') ==="

if [ "${1:-}" = "--restore" ]; then
  if [ ! -f "${BACKUP}" ]; then
    echo "[fail] バックアップが無い: ${BACKUP}" >&2
    exit 1
  fi
  cp -p "${BACKUP}" "${SETTINGS}"
  echo "[run ] settings.json をバックアップから復元した"
else
  # 状態復元 hook と記録漏れ通知 hook を削除する
  TMP="$(mktemp)"
  jq --arg cmd "${STATE_CMD}" --arg stop "${STOP_CMD}" '
    (if (.hooks.SessionStart? | type) == "array" then
      .hooks.SessionStart |= map(select(([.hooks[]?.command] | index($cmd)) | not))
    else . end)
    | (if (.hooks.Stop? | type) == "array" then
      .hooks.Stop |= map(select(([.hooks[]?.command] | index($stop)) | not))
    else . end)
  ' "${SETTINGS}" > "${TMP}"

  if [ -s "${TMP}" ] && jq -e . "${TMP}" >/dev/null 2>&1; then
    cat "${TMP}" > "${SETTINGS}"
    echo "[run ] SessionStart と Stop の hook を削除した"
  else
    echo "[fail] settings.json の更新に失敗した。変更は適用していない" >&2
  fi
  rm -f "${TMP}"

  # bd 公式 hook を削除する
  echo "[run ] bd prime の hook を削除する"
  bd setup claude --global --remove || echo "[warn] bd setup claude --global --remove が失敗した"

  # 空になった hooks キーを取り除き、導入前の状態と完全に一致させる。
  # イベント名を列挙せず、空配列になったものを全て落とす。
  TMP2="$(mktemp)"
  jq '
    if (.hooks? | type) == "object"
      then .hooks |= with_entries(select((.value | type) != "array" or (.value | length) > 0))
      else . end
    | if (.hooks? | type) == "object" and (.hooks | length) == 0
      then del(.hooks) else . end
  ' "${SETTINGS}" > "${TMP2}"
  if [ -s "${TMP2}" ] && jq -e . "${TMP2}" >/dev/null 2>&1; then
    if ! diff -q "${SETTINGS}" "${TMP2}" >/dev/null 2>&1; then
      cat "${TMP2}" > "${SETTINGS}"
      echo "[run ] 空になった hooks キーを削除した"
    fi
  fi
  rm -f "${TMP2}"
fi

if [ -f "${RULES_DST}" ]; then
  rm "${RULES_DST}"
  echo "[run ] 運用ルールを削除した: ${RULES_DST}"
else
  echo "[skip] 運用ルールは存在しない"
fi

echo
echo "=== 取り消し後の SessionStart hook ==="
jq '.hooks.SessionStart // "なし"' "${SETTINGS}"
echo
echo "完了。ログ: ${LOG_FILE}"
