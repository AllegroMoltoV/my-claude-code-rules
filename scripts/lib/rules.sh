#!/usr/bin/env bash
#
# ~/.claude/rules/ と ~/.claude/skills/ への配置を扱う共通処理。
# bootstrap.sh と setup-beads.sh の双方が source する。
#
# 既定は symlink である。原本を編集すれば配置先へ即座に反映され、同期作業その
# ものが不要になるためである。
#
# ただし symlink を作れない環境がある。権限や設定が足りないと、シェルは symlink
# ではなくコピーを作る。そこで起動時に実際に symlink を作れるかを試し、作れない
# 環境ではコピーへ自動的に切り替える。OS を判定せず、能力を判定する方式である。
#
# コピーの場合、配置先は原本から導かれる派生物として扱い、内容が異なれば原本の
# 内容で上書きする。配置先を編集しても次回の実行で失われるため、環境ごとの追加
# は配置先ではなく原本側で管理すること。

# 環境が symlink を作れるかを実測する。結果は LINK_MODE に入れる。
detect_link_mode() {
  [ -n "${LINK_MODE:-}" ] && return 0
  local probe_dir probe_src probe_dst
  probe_dir="$(mktemp -d)"
  probe_src="${probe_dir}/src"
  probe_dst="${probe_dir}/dst"
  : > "${probe_src}"
  if ln -s "${probe_src}" "${probe_dst}" 2>/dev/null && [ -L "${probe_dst}" ]; then
    LINK_MODE="symlink"
  else
    LINK_MODE="copy"
  fi
  rm -rf "${probe_dir}"
  export LINK_MODE
}

# link_rule <原本の絶対パス> <配置先の絶対パス>
#
# コピーの場合、内容が異なれば原本の内容で上書きする。上流の更新を配置先へ届ける
# ためである。警告を出して更新を拒む作りにすると、原本を更新しても配置先が古い
# ままになり、それに気づけない。
link_rule() {
  local src="$1"
  local dst="$2"
  local name
  name="$(basename "${dst}")"

  detect_link_mode

  if [ "${LINK_MODE}" = "copy" ]; then
    if [ ! -e "${src}" ]; then
      echo "  [warn] 原本が見つからない: ${src}"
      return 0
    fi
    if [ -f "${dst}" ] && diff -q "${src}" "${dst}" >/dev/null 2>&1; then
      echo "  [skip] コピー済み: ${name}"
    elif [ -e "${dst}" ]; then
      cp -f "${src}" "${dst}"
      echo "  [run ] 原本の内容で更新した: ${name}"
    else
      cp "${src}" "${dst}"
      echo "  [run ] コピーした: ${name} (この環境は symlink 非対応)"
    fi
    return 0
  fi

  if [ ! -e "${src}" ]; then
    echo "  [warn] 原本が見つからない: ${src}"
    return 0
  fi

  if [ -L "${dst}" ]; then
    if [ "$(readlink "${dst}")" = "${src}" ]; then
      echo "  [skip] symlink 済み: ${name}"
    else
      ln -sfn "${src}" "${dst}"
      echo "  [run ] symlink の向き先を修正した: ${name}"
    fi
  elif [ ! -e "${dst}" ]; then
    ln -sfn "${src}" "${dst}"
    echo "  [run ] symlink を作成した: ${name}"
  elif diff -q "${src}" "${dst}" >/dev/null 2>&1; then
    rm "${dst}"
    ln -sfn "${src}" "${dst}"
    echo "  [run ] 同内容の実体を symlink に置き換えた: ${name}"
  else
    echo "  [warn] symlink ではない実体ファイルが原本と異なるため変更しない: ${name}"
    echo "         差分の確認: diff '${src}' '${dst}'"
    echo "         内容を原本へ取り込んだうえで、配置先のファイルを削除して再実行すること"
  fi
}

# link_dir <原本ディレクトリの絶対パス> <配置先の絶対パス>
#
# skill のようにディレクトリ単位で参照するものに使う。
link_dir() {
  local src="$1"
  local dst="$2"
  local name
  name="$(basename "${dst}")"

  detect_link_mode

  if [ ! -d "${src}" ]; then
    echo "  [warn] 原本ディレクトリが見つからない: ${src}"
    return 0
  fi

  if [ "${LINK_MODE}" = "copy" ]; then
    if [ -d "${dst}" ] && diff -rq "${src}" "${dst}" >/dev/null 2>&1; then
      echo "  [skip] コピー済み: ${name}"
    else
      rm -rf "${dst}"
      cp -R "${src}" "${dst}"
      echo "  [run ] コピーした: ${name} (この環境は symlink 非対応)"
    fi
    return 0
  fi

  if [ -L "${dst}" ] && [ "$(readlink "${dst}")" = "${src}" ]; then
    echo "  [skip] symlink 済み: ${name}"
  elif [ -e "${dst}" ] && [ ! -L "${dst}" ]; then
    echo "  [warn] ${dst} が symlink ではない実体のため変更しない"
  else
    ln -sfn "${src}" "${dst}"
    echo "  [run ] symlink を作成した: ${name}"
  fi
}
