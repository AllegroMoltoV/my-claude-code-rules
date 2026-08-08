#!/usr/bin/env bash
#
# セットアップ。何度実行しても結果が変わらない (冪等)。
#
# 2 つのフェーズを扱う。目的が違うため、どちらを行うのかを明示して実行する。
#
#   A. グローバルの初回セットアップ (機械ごとに 1 回)
#      ルールと skill を ~/.claude/ へ配置する。プロジェクトには触らない。
#
#        <このリポジトリ>/scripts/bootstrap.sh --global-only
#
#   B. プロジェクトのセットアップ (プロジェクトごと)
#      A に加えて、対象プロジェクトを開始可能な状態にする。
#
#        cd <新しいプロジェクト>
#        <このリポジトリ>/scripts/bootstrap.sh
#
# オプション
#   --global-only         A だけを行う。プロジェクトには一切書き込まない
#   --with-project-rules  rules をプロジェクトの .claude/rules/ にもコピーする
#                         (既定はグローバル一本化。他マシンへ持ち出すときだけ使う)
#   --no-beads            Beads の初期化を行わない
#   --target <dir>        対象ディレクトリ (既定はカレントディレクトリ)
#
# グローバルの rules と skill は symlink で配置する。コピーしないため
# 原本を編集すれば即座に反映され、同期のずれが起きない。
#
# 本スクリプトは自身の位置からリポジトリルートを求めるため、リポジトリを
# どこへ置いても動作する。リポジトリへは一切書き込まない。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RULES_REPO="${REPO_ROOT}"

# shellcheck source=lib/rules.sh
. "${REPO_ROOT}/scripts/lib/rules.sh"

GLOBAL_ONLY=0
WITH_PROJECT_RULES=0
USE_BEADS=1
TARGET="${PWD}"

while [ $# -gt 0 ]; do
  case "$1" in
    --global-only)        GLOBAL_ONLY=1; shift ;;
    --with-project-rules) WITH_PROJECT_RULES=1; shift ;;
    --no-beads)           USE_BEADS=0; shift ;;
    --target)             TARGET="$2"; shift 2 ;;
    -h|--help)            sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "不明なオプション: $1" >&2; exit 1 ;;
  esac
done

# ログの置き場所はフェーズで変わる。--global-only では対象プロジェクトが無いため、
# 呼び出し元のディレクトリを汚さないようリポジトリ側へ書く。
if [ "${GLOBAL_ONLY}" -eq 1 ]; then
  mkdir -p "${REPO_ROOT}/.logs"
  LOG_FILE="${REPO_ROOT}/.logs/bootstrap-global-$(date +%Y%m%d-%H%M%S).log"
else
  mkdir -p "${TARGET}"
  TARGET="$(cd "${TARGET}" && pwd)"
  mkdir -p "${TARGET}/.logs"
  LOG_FILE="${TARGET}/.logs/bootstrap-$(date +%Y%m%d-%H%M%S).log"
fi
exec > >(tee -a "${LOG_FILE}") 2>&1

CLAUDE_DIR="${HOME}/.claude"

if [ "${GLOBAL_ONLY}" -eq 1 ]; then
  echo "=== グローバルの初回セットアップ $(date '+%Y-%m-%d %H:%M:%S') ==="
else
  echo "=== プロジェクトのセットアップ $(date '+%Y-%m-%d %H:%M:%S') ==="
  echo "対象:     ${TARGET}"
fi
echo "ルール元: ${RULES_REPO} (読み取り専用)"
echo

HAS_RULES_REPO=1
if [ ! -d "${RULES_REPO}/rules" ]; then
  HAS_RULES_REPO=0
  echo "  [warn] ルール元が見つからない: ${RULES_REPO}"
  echo "         ルール配置、除外設定、INIT.md の配置を飛ばす"
  echo
fi

# ---------------------------------------------------------------------------
echo "A. グローバル資産"
# ---------------------------------------------------------------------------

mkdir -p "${CLAUDE_DIR}/rules"

# 公開リポジトリ由来の開発ルール
if [ "${HAS_RULES_REPO}" -eq 1 ]; then
  for src in "${RULES_REPO}"/rules/*.md; do
    link_rule "${src}" "${CLAUDE_DIR}/rules/$(basename "${src}")"
  done
fi

# skill
mkdir -p "${CLAUDE_DIR}/skills"
SKILL_DST="${CLAUDE_DIR}/skills/project-bootstrap"
SKILL_NEW=0
[ -e "${SKILL_DST}" ] || SKILL_NEW=1
link_dir "${REPO_ROOT}/skills/project-bootstrap" "${SKILL_DST}"

echo

if [ "${GLOBAL_ONLY}" -eq 1 ]; then
  echo "=== 完了 ==="
  echo "ログ: ${LOG_FILE}"
  echo
  echo "次の手順"
  echo "  1. Claude Code を再起動する (skill を認識させるため)"
  echo "  2. プロジェクト用のフォルダを作り、.prompts/INIT.md をコピーして実行を依頼する"
  exit 0
fi

# ---------------------------------------------------------------------------
echo "B. プロジェクト"
# ---------------------------------------------------------------------------
cd "${TARGET}"

# git
if [ -d .git ]; then
  echo "  [skip] git リポジトリは初期化済み"
else
  git init -b main -q
  echo "  [run ] git リポジトリを初期化した (ブランチ: main)"
fi

# .git/info/exclude は既存の内容を消さず、不足している項目だけ追記する
if [ "${HAS_RULES_REPO}" -eq 1 ] && [ -f "${RULES_REPO}/exclude" ]; then
  EXCLUDE_FILE=".git/info/exclude"
  mkdir -p "$(dirname "${EXCLUDE_FILE}")"
  touch "${EXCLUDE_FILE}"
  ADDED=0
  while IFS= read -r entry; do
    [ -z "${entry}" ] && continue
    if ! grep -qxF "${entry}" "${EXCLUDE_FILE}"; then
      if [ "${ADDED}" -eq 0 ]; then
        printf '\n# my-claude-code-rules\n' >> "${EXCLUDE_FILE}"
      fi
      printf '%s\n' "${entry}" >> "${EXCLUDE_FILE}"
      ADDED=$((ADDED + 1))
    fi
  done < "${RULES_REPO}/exclude"
  if [ "${ADDED}" -gt 0 ]; then
    echo "  [run ] .git/info/exclude に ${ADDED} 件を追記した"
  else
    echo "  [skip] .git/info/exclude は設定済み"
  fi
fi

# 作業ディレクトリ
for d in .appendix .tmp .logs .prompts/PLANS .prompts/DISCUSSIONS docs/reports docs/logs; do
  if [ -d "${d}" ]; then
    echo "  [skip] ディレクトリは作成済み: ${d}"
  else
    mkdir -p "${d}"
    echo "  [run ] ディレクトリを作成した: ${d}"
  fi
done

# INIT.md は要件が書き込まれている可能性があるため上書きしない
if [ -f .prompts/INIT.md ]; then
  echo "  [skip] .prompts/INIT.md は配置済み (上書きしない)"
else
  cp "${REPO_ROOT}/.prompts/INIT.md" .prompts/INIT.md
  echo "  [run ] .prompts/INIT.md を配置した"
fi

# docs/INDEX.md の雛形
if [ -f docs/INDEX.md ]; then
  echo "  [skip] docs/INDEX.md は作成済み"
else
  cat > docs/INDEX.md <<'INDEXEOF'
# 文書索引

context compaction で文脈が失われた場合は、この索引から必要な文書をたどる。

| 知りたいこと | 参照先 |
|---|---|
| プロジェクトの目的と使い方 | `README.md` |
| 要件と初回セットアップの指示 | `.prompts/INIT.md` |
| 調査レポート | `docs/reports/` |
| 実行ログ (生の出力。git 追跡対象外) | `.logs/` |
| 実行ログ (残す価値があると判断したもの) | `docs/logs/` |
| 計画 | `.prompts/PLANS/` |
| 判断を要する論点 | `.prompts/DISCUSSIONS/` |
| タスクの状態、依存関係、blocker | `bd ready` / `bd blocked` / `bd list` |
INDEXEOF
  echo "  [run ] docs/INDEX.md の雛形を作成した"
fi

# rules のプロジェクトへのコピー (任意)。他マシンへ持ち出す用途のため symlink ではなく実体を置く。
if [ "${WITH_PROJECT_RULES}" -eq 1 ] && [ "${HAS_RULES_REPO}" -eq 1 ]; then
  mkdir -p .claude/rules
  cp "${RULES_REPO}"/rules/*.md .claude/rules/
  echo "  [run ] rules をプロジェクトの .claude/rules/ にコピーした"
elif [ -d .claude/rules ]; then
  echo "  [warn] .claude/rules/ が存在する。~/.claude/rules/ と二重に読み込まれる"
  echo "         グローバル一本化する場合は rm -rf .claude/rules を検討する"
fi

# Beads
if [ "${USE_BEADS}" -eq 0 ]; then
  echo "  [skip] Beads の初期化を省略した (--no-beads)"
elif [ -f .beads-optout ]; then
  echo "  [skip] .beads-optout があるため Beads を初期化しない"
elif ! command -v bd >/dev/null 2>&1; then
  echo "  [warn] bd コマンドが無いため Beads を初期化しない"
  echo "         導入: ${REPO_ROOT}/scripts/setup-beads.sh"
elif [ -d .beads ]; then
  echo "  [skip] Beads は初期化済み"
else
  bd init --stealth --skip-agents --non-interactive --init-if-missing -q >/dev/null 2>&1
  if [ -d .beads ]; then
    echo "  [run ] Beads を初期化した (stealth モード。git を汚さない)"
  else
    echo "  [warn] Beads の初期化に失敗した。bd doctor で確認すること"
  fi
fi

echo
echo "=== 完了 ==="
echo "ログ: ${LOG_FILE}"
echo
echo "次の手順"
echo "  1. .prompts/INIT.md の要件セクションを記入する"
echo "  2. Claude Code に .prompts/INIT.md の実行を依頼する"
if [ "${SKILL_NEW}" -eq 1 ]; then
  echo
  echo "skill を新規登録した。Claude Code を再起動すると /project-bootstrap が使えるようになる。"
fi
