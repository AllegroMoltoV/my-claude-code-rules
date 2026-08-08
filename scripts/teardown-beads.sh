#!/usr/bin/env bash
#
# Beads のグローバル導入を取り消す。
#
#   ./scripts/teardown-beads.sh            # フックと運用ルールを削除する
#   ./scripts/teardown-beads.sh --restore  # settings.json をバックアップから復元する
#
# 依存コマンド
#   bd と jq。いずれも本スクリプトは導入しない。未導入なら中止する。
#
# 戻さないもの
#   bd CLI 自体。削除する場合は導入時に使った方法で取り除くこと。
#   各リポジトリの .beads/。タスク状態が失われるため手動で判断すること。
#   bd metrics の設定。無断で送信を再開させないため、状態を表示するだけにする。

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

# 依存コマンドの確認。jq が無いと settings.json の編集が途中で止まり、部分適用になる。
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
  echo "[fail] 依存コマンドが不足しているため中止した。設定は変更していない" >&2
  exit 1
fi

# bd 公式の統合を削除する。--restore の経路でも実行する必要がある。
# この操作はグローバルフックだけでなく、カレントディレクトリの CLAUDE.md に
# 追記された Beads の管理ブロックも取り除く。settings.json の復元より前に
# 実行することで、復元後のファイルがバックアップとバイト単位で一致する。
echo "[run ] bd の統合を削除する"
bd setup claude --global --remove || echo "[warn] bd setup claude --global --remove が失敗した"

if [ "${1:-}" = "--restore" ]; then
  if [ ! -f "${BACKUP}" ]; then
    echo "[fail] バックアップが無い: ${BACKUP}" >&2
    exit 1
  fi
  cp -p "${BACKUP}" "${SETTINGS}"
  echo "[run ] settings.json をバックアップから復元した"
else
  # 状態復元 hook と記録漏れ通知 hook を削除する
  # Stop はスクリプト名で判定する。完全一致にすると、リポジトリを移設したあとに
  # 古いパスのエントリを取り除けない。setup 側と同じ判定にそろえている。
  TMP="$(mktemp)"
  jq --arg cmd "${STATE_CMD}" '
    def is_nudge: (.hooks // []) | map(.command? // "") | any(endswith("beads-stop-nudge.sh"));
    (if (.hooks.SessionStart? | type) == "array" then
      .hooks.SessionStart |= map(select(([.hooks[]?.command] | index($cmd)) | not))
    else . end)
    | (if (.hooks.Stop? | type) == "array" then
      .hooks.Stop |= map(select(is_nudge | not))
    else . end)
  ' "${SETTINGS}" > "${TMP}"

  if [ -s "${TMP}" ] && jq -e . "${TMP}" >/dev/null 2>&1; then
    cat "${TMP}" > "${SETTINGS}"
    echo "[run ] SessionStart と Stop の hook を削除した"
  else
    echo "[fail] settings.json の更新に失敗した。変更は適用していない" >&2
  fi
  rm -f "${TMP}"

  # bd 公式の統合は分岐の前で削除済み。

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

# 配置した運用ルールを削除する。原本と内容が違う場合は、利用者が独自に加えた
# 変更を黙って消さないよう警告だけ出す。
RULES_SRC="${REPO_ROOT}/rules/beads.md"
if [ ! -f "${RULES_DST}" ]; then
  echo "[skip] 運用ルールは存在しない"
elif [ -f "${RULES_SRC}" ] && ! diff -q "${RULES_SRC}" "${RULES_DST}" >/dev/null 2>&1; then
  echo "[warn] 配置先が原本と異なるため削除しない: ${RULES_DST}"
  echo "       差分の確認: diff '${RULES_SRC}' '${RULES_DST}'"
else
  rm "${RULES_DST}"
  echo "[run ] 運用ルールを削除した: ${RULES_DST}"
fi

# 匿名利用統計は自動で戻さない。無断で送信を再開させるべきではないため、
# 現在の状態と戻す方法だけを伝える。
echo "[info] 匿名利用統計は停止したままです。再開する場合は bd metrics on を実行してください"

echo
echo "=== 取り消し後の SessionStart hook ==="
jq '.hooks.SessionStart // "なし"' "${SETTINGS}"
echo
echo "完了。ログ: ${LOG_FILE}"
