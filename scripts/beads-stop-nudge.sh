#!/usr/bin/env bash
#
# Claude Code の Stop hook。応答を終える直前に発火する。
#
# 目的
#   作業中 (in_progress) のまま長時間更新されていないタスクを検出し、
#   Beads への記録漏れを Claude に気づかせる。
#
# 動作
#   decision=block を返して応答の終了を阻止し、記録を促す。Claude は終われず、
#   記録するか、記録不要と判断してもう一度終了を試みることになる。
#
# ループ対策 (最重要)
#   block は応答の完了を止めるため、条件が真のままだと無限ループになる。
#   次の 3 段で必ず止まるようにしている。
#
#   1. stop_hook_active : 既に一度ブロックされた状態で再入した場合は即座に黙る。
#   2. レート制限       : ブロックする直前に stamp を書き、COOLDOWN_SEC の間は必ず黙る。
#                         Claude が記録を怠っても、次の Stop は素通りする。
#                         したがってブロックは COOLDOWN_SEC あたり最大 1 回に限られる。
#   3. 条件付き         : in_progress のタスクが STALE_SEC 以上更新されていないときだけ
#                         発火する。Claude が bd note を実行すると updated_at が更新され、
#                         条件が偽になる。
#
#   上記いずれかに該当しない場合は何も出力せず exit 0 する。
#
# 誤検知の扱い
#   記録すべきことが無いターンでも発火しうる。その場合の損失は応答が 1 往復増えるだけで、
#   レート制限により 2 回目は素通りする。取りこぼしを防ぐ側に倒している。
#
# 環境変数
#   BD_STOP_STALE_SEC     何秒更新が無ければ発火するか (既定 900)
#   BD_STOP_COOLDOWN_SEC  一度発火したら何秒黙るか (既定 900)

set -uo pipefail

# hook は stdin に JSON を渡してくる。stop_hook_active を再入判定に使う。
INPUT="$(cat 2>/dev/null || true)"
if printf '%s' "${INPUT}" | jq -e '.stop_hook_active == true' >/dev/null 2>&1; then
  exit 0
fi

STALE_SEC="${BD_STOP_STALE_SEC:-900}"
COOLDOWN_SEC="${BD_STOP_COOLDOWN_SEC:-900}"

command -v bd >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# beads ワークスペース以外では黙る
RAW="$(bd list --status=in_progress --json 2>/dev/null)" || exit 0
printf '%s' "${RAW}" | jq -e 'type == "array"' >/dev/null 2>&1 || exit 0

NOW="$(date +%s)"

# レート制限。stamp はリポジトリを汚さないよう一時ディレクトリに置く。
KEY="$(printf '%s' "${PWD}" | cksum | cut -d' ' -f1)"
STAMP="${TMPDIR:-/tmp}/bd-stop-nudge-${KEY}"
if [ -f "${STAMP}" ]; then
  LAST="$(cat "${STAMP}" 2>/dev/null || echo 0)"
  case "${LAST}" in
    ''|*[!0-9]*) LAST=0 ;;
  esac
  if [ $((NOW - LAST)) -lt "${COOLDOWN_SEC}" ]; then
    exit 0
  fi
fi

# STALE_SEC 以上更新されていない in_progress タスクを抽出する
STALE_LIST="$(printf '%s' "${RAW}" | jq -r \
  --argjson now "${NOW}" --argjson th "${STALE_SEC}" '
  [ .[]
    | select((.updated_at // empty) != null)
    | select(($now - (.updated_at | fromdateiso8601)) > $th)
    | "- \(.id) \(.title)"
  ] | .[]' 2>/dev/null)"

[ -z "${STALE_LIST}" ] && exit 0

printf '%s' "${NOW}" > "${STAMP}"

MINUTES=$((STALE_SEC / 60))
REASON="次のタスクが in_progress のまま ${MINUTES} 分以上更新されていません。

${STALE_LIST}

このターンで上記に関する進捗、判断、検証結果、blocker、利用者から受け取った決定があったなら、応答を終える前に記録してください。

- 経過や検証結果は bd note <id> に書く
- 利用者から受け取った決定は bd remember に書く (close --reason や closed 課題の note は次セッションへ注入されない)
- 完了しているなら bd close <id> --reason=\"実施: … 検証: …\"

記録は作業の終わりにまとめてではなく、事実が確定した時点で書きます。セッションは context compaction や離席で予告なく途切れるためです。

記録すべきことが無ければ、その旨を一言述べてそのまま応答を終えてかまいません。この通知は ${MINUTES} 分間は再度出ないため、次は素通りします。"

jq -n --arg reason "${REASON}" --arg sys "beads: in_progress のタスクが ${MINUTES} 分以上未更新のため応答を保留しました" '
{
  decision: "block",
  reason: $reason,
  systemMessage: $sys
}'
