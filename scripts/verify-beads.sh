#!/usr/bin/env bash
#
# Beads グローバル導入の検証。使い捨てのローカル git リポジトリを作って確認する。
#
#   ./scripts/verify-beads.sh
#
# 検証項目
#   1. 長期タスクを作成し、依存関係と blocker を管理できる
#   2. 新しいセッション相当の処理で状態を復元できる
#   3. opt out したプロジェクトでは Beads が動作しない
#   4. セットアップを再実行しても設定が重複しない
#   5. 既存の Claude Code 設定が維持されている

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${REPO_ROOT}/.logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/verify-beads-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

SETTINGS="${HOME}/.claude/settings.json"
BACKUP="${HOME}/.claude/settings.json.pre-beads.bak"
RULES="${HOME}/.claude/rules/beads.md"
STATE_CMD='bd list --status=in_progress 2>/dev/null; bd ready 2>/dev/null; bd blocked 2>/dev/null; true'

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASS=0
FAIL=0

ok()   { printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
ng()   { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { if [ "$1" = "0" ]; then ok "$2"; else ng "$2"; fi; }

echo "=== Beads 検証 $(date '+%Y-%m-%d %H:%M:%S') ==="
echo "作業ディレクトリ: ${WORK}"
echo

# ---------------------------------------------------------------------------
echo "1. 長期タスクの作成、依存関係と blocker の管理"
# ---------------------------------------------------------------------------
LONG="${WORK}/repo-long"
mkdir -p "${LONG}"
cd "${LONG}"
git init -b main -q
printf '# repo-long\n' > README.md
git add README.md
git -c user.email=verify@example.com -c user.name=verify commit -q -m "初期コミット"

bd init --stealth --skip-agents --non-interactive --init-if-missing -q >/dev/null 2>&1
[ -d "${LONG}/.beads" ]; check $? ".beads/ が作成された"

# git を汚していないこと
[ -z "$(git status --porcelain)" ]; check $? "git status がクリーン (作業ツリーを汚さない)"
[ "$(git rev-list --count HEAD)" = "1" ]; check $? "bd init が git コミットを作っていない"

EPIC=$(bd create --title="認証基盤の刷新" --description="複数セッションにまたがる長期タスク" --type=epic --priority=1 --json | jq -r .id)
DESIGN=$(bd create --title="トークン発行APIの設計" --description="発行と失効の仕様を決める" --type=task --priority=1 --parent="${EPIC}" --json | jq -r .id)
IMPL=$(bd create --title="トークン発行APIの実装" --description="設計確定後に実装する" --type=task --priority=1 --parent="${EPIC}" --json | jq -r .id)
echo "  epic=${EPIC} design=${DESIGN} impl=${IMPL}"

[ -n "${EPIC}" ] && [ -n "${DESIGN}" ] && [ -n "${IMPL}" ]; check $? "長期タスク (epic と子タスク 2 件) を作成できた"

bd dep add "${IMPL}" "${DESIGN}" --json >/dev/null 2>&1; check $? "依存関係を登録できた (実装は設計に依存)"

bd ready --json | jq -e --arg id "${IMPL}" 'map(select(.id == $id)) | length == 0' >/dev/null
check $? "blocker のあるタスクが ready から除外される"

bd blocked --json | jq -e --arg id "${IMPL}" 'map(select(.id == $id)) | length == 1' >/dev/null
check $? "blocker のあるタスクが blocked に現れる"

bd update "${DESIGN}" --claim --json >/dev/null 2>&1; check $? "タスクを claim できた"

bd note "${DESIGN}" "未検証の想定: 既存クライアントはヘッダ認証に対応済みと聞いているが実地確認はまだ" >/dev/null 2>&1
check $? "未検証の想定を note として記録できた"

bd close "${DESIGN}" --reason="実施: 発行と失効の仕様を確定。検証: bd show で依存解除を確認" --json >/dev/null 2>&1
check $? "実施内容と検証結果を添えて close できた"

# bd show --json は要素 1 件の配列を返す
bd show "${DESIGN}" --json | jq -e '.[0].close_reason | test("検証:")' >/dev/null
check $? "close 時の検証結果が永続化されている"

bd show "${DESIGN}" --json | jq -e '.[0].notes | test("未検証の想定:")' >/dev/null
check $? "未検証の想定が note として永続化されている"

bd ready --json | jq -e --arg id "${IMPL}" 'map(select(.id == $id)) | length == 1' >/dev/null
check $? "blocker 解消後に依存タスクが ready になる"

echo

# ---------------------------------------------------------------------------
echo "2. 新しいセッション相当の処理での状態復元"
# ---------------------------------------------------------------------------
cd "${LONG}"
bd update "${IMPL}" --claim --json >/dev/null 2>&1
bd remember "検証済みの事実: このリポジトリは bd init --stealth で初期化しており git コミットは作られない" >/dev/null 2>&1

PRIME_OUT="$(bd prime --hook-json 2>/dev/null)"
printf '%s' "${PRIME_OUT}" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null
check $? "hook 1: SessionStart の JSON エンベロープを返す"

printf '%s' "${PRIME_OUT}" | jq -er '.hookSpecificOutput.additionalContext' | grep -q "Beads Workflow Context"
check $? "hook 1: workflow context が復元される"

printf '%s' "${PRIME_OUT}" | jq -er '.hookSpecificOutput.additionalContext' | grep -q "検証済みの事実"
check $? "hook 1: 永続メモリが復元される"

STATE_OUT="$(bash -c "${STATE_CMD}" 2>/dev/null)"
printf '%s' "${STATE_OUT}" | grep -q "${IMPL}"
check $? "hook 2: 作業中のタスクが復元される"

printf '%s' "${STATE_OUT}" | grep -q "${EPIC}"
check $? "hook 2: 次に着手できるタスクが復元される"

echo

# ---------------------------------------------------------------------------
echo "3. opt out したプロジェクトで Beads が動作しないこと"
# ---------------------------------------------------------------------------
OPTOUT="${WORK}/repo-optout"
mkdir -p "${OPTOUT}"
cd "${OPTOUT}"
git init -b main -q
printf '# repo-optout\n' > README.md
git add README.md
git -c user.email=verify@example.com -c user.name=verify commit -q -m "初期コミット"
touch .beads-optout

[ ! -d "${OPTOUT}/.beads" ]; check $? ".beads/ が存在しない"
[ -f "${OPTOUT}/.beads-optout" ]; check $? "opt out マーカーが存在する"

OPTOUT_PRIME="$(bd prime --hook-json 2>/dev/null)"
printf '%s' "${OPTOUT_PRIME}" | jq -e '.hookSpecificOutput.additionalContext == ""' >/dev/null
check $? "hook 1 は文脈を注入しない (additionalContext が空)"

OPTOUT_STATE="$(bash -c "${STATE_CMD}" 2>/dev/null)"
[ -z "${OPTOUT_STATE}" ]; check $? "hook 2 は何も出力しない"

bash -c "${STATE_CMD}" >/dev/null 2>&1; check $? "hook 2 は正常終了する (エラー通知を出さない)"

echo

# ---------------------------------------------------------------------------
echo "4. セットアップ再実行で設定が重複しないこと"
# ---------------------------------------------------------------------------
cd "${WORK}"
BEFORE="${WORK}/settings-before.json"
AFTER="${WORK}/settings-after.json"
cp "${SETTINGS}" "${BEFORE}"

"${REPO_ROOT}/scripts/setup-beads.sh" >/dev/null 2>&1
cp "${SETTINGS}" "${AFTER}"

diff -q "${BEFORE}" "${AFTER}" >/dev/null; check $? "再実行後も settings.json がバイト単位で同一"

HOOK_COUNT=$(jq '[.hooks.SessionStart[]?.hooks[]?.command] | length' "${SETTINGS}")
UNIQ_COUNT=$(jq '[.hooks.SessionStart[]?.hooks[]?.command] | unique | length' "${SETTINGS}")
[ "${HOOK_COUNT}" = "${UNIQ_COUNT}" ]; check $? "SessionStart hook に重複コマンドが無い (${HOOK_COUNT} 件)"
[ "${HOOK_COUNT}" = "2" ]; check $? "SessionStart hook は想定どおり 2 件"

echo

# ---------------------------------------------------------------------------
echo "5. 既存の Claude Code 設定が維持されていること"
# ---------------------------------------------------------------------------
jq -S 'del(.hooks)' "${SETTINGS}" > "${WORK}/now-nohooks.json"
jq -S . "${BACKUP}" > "${WORK}/orig.json"
diff -q "${WORK}/orig.json" "${WORK}/now-nohooks.json" >/dev/null
check $? "hooks 以外の設定が導入前と完全に一致"

jq -e '.model and .effortLevel and .enabledPlugins and .extraKnownMarketplaces' "${SETTINGS}" >/dev/null
check $? "model / effortLevel / plugin 設定が残存"

jq -e '.enabledPlugins | length == 5' "${SETTINGS}" >/dev/null
check $? "既存プラグイン 5 件が維持されている"

[ -f "${HOME}/.claude/settings.local.json" ]; check $? "settings.local.json が存在する"
jq -e . "${HOME}/.claude/settings.local.json" >/dev/null; check $? "settings.local.json が壊れていない"

for f in project testing working-principles documentation; do
  [ -f "${HOME}/.claude/rules/${f}.md" ]; check $? "既存ルール ${f}.md が維持されている"
done
[ -f "${RULES}" ]; check $? "Beads 運用ルールが配置されている"

echo
echo "==============================="
printf '合計: %d 件成功 / %d 件失敗\n' "${PASS}" "${FAIL}"
echo "ログ: ${LOG_FILE}"
echo "==============================="

[ "${FAIL}" -eq 0 ]
