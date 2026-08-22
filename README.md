# my-claude-code-rules

Claude Code で使用する開発ルール集です。プロジェクト管理、テスト、ドキュメント作成の規約と、プロジェクト初期セットアップの自動化をまとめています。

Claude Code はコンテキスト圧縮 (compact) 時に `CLAUDE.md` と `.claude/rules/` の内容だけを再注入します。会話中に読み込んだファイルは圧縮後に抜け落ちるため、ルールは `.claude/rules/` に配置する必要があります。

## 使い方

2 つのフェーズに分かれます。**フェーズ 1 は機械ごとに 1 回、フェーズ 2 はプロジェクトごとです。**

### フェーズ 1: グローバルの初回セットアップ

1. 本リポジトリを clone する
2. `~/.claude/settings.json` の `env` に `MY_CLAUDE_RULES` を設定する。値は clone した位置
3. `bash "${MY_CLAUDE_RULES}/scripts/bootstrap.sh" --global-only` を実行する
4. Beads でタスク管理をするなら `bash "${MY_CLAUDE_RULES}/scripts/setup-beads.sh"` も実行する
5. Claude Code を再起動する

```json
{
  "env": {
    "MY_CLAUDE_RULES": "<clone した位置>"
  }
}
```

`--global-only` はルールとスキルを `~/.claude/` へ配置するだけで、プロジェクトには触りません。

`setup-beads.sh` は `bd` と `jq` を必要とします。スクリプトはこれらを導入しません。未導入なら中止するので、導入方法は Claude Code に尋ねてください。

環境変数をシェルの設定ファイルではなく `settings.json` に書く理由は、Claude Code のツール呼び出しが非対話シェルで動くためです。`~/.bashrc` に書いても値が届かないことがあります。

### フェーズ 2: プロジェクトのセットアップ

1. プロジェクト用のフォルダを作る
2. 本リポジトリの `.prompts/INIT.md` をそのフォルダへコピーする
3. `INIT.md` に要件、前提と制約、完了の定義を書く
4. そのフォルダで Claude Code を起動し、「`.prompts/INIT.md` を実行してください」と頼む

**残りは Claude Code が行います。** git の初期化、除外設定の追記、作業ディレクトリの作成、Beads の初期化、現状の調査、長期タスクの登録まで進み、不明点を `.prompts/QUESTIONS.md` に書いて回答を待ちます。

## 内容物

| パス | 内容 |
|---|---|
| `rules/` | 開発ルール 5 ファイル。プロジェクト管理、テスト、文体、作業の進め方、Beads の運用 |
| `skills/project-bootstrap/` | プロジェクト初期セットアップのスキル |
| `scripts/` | 配置と Beads の導入、検証、取り消しのスクリプト 6 本 |
| `.prompts/INIT.md` | プロジェクトの入口となる要件シート |
| `exclude` | `.git/info/exclude` の参照用コピー |
| `.gitattributes` | スクリプトと Markdown の改行を LF に固定 |

`rules/` の各ファイルは共通の骨格に従います。H1 見出しと導入文を置き、規則は 1 項目あたり規則 1 文と理由 1 文までの箇条書きで書きます。H2 見出しは、箇条書き以外の構造要素 (表、コード例、番号付き手順) を持つとき、または本文が 5,000 文字を超えて分類が必要なときにだけ置きます。構造が不要なファイルに見出しを足せば、context を圧迫するだけだからです。

`documentation.md` の frontmatter は、この規約を `**/*.md` にだけ適用するための意図的な設定です。ターミナル応答や UI テキストを規律する原則は `working-principles.md` に置いています。

**`rules/` に `README.md` を置いてはいけません。** `bootstrap.sh` が `rules/*.md` を配置対象にするため、ルールとして読み込まれます。

`scripts/` の内訳は次のとおりです。いずれも POSIX シェルで動き、何度実行しても結果が変わりません。

| ファイル | 用途 |
|---|---|
| `bootstrap.sh` | ルールとスキルの配置、プロジェクトの初期化 |
| `lib/rules.sh` | 配置の共通処理。シンボリックリンクを作れるかを実測して切り替える |
| `setup-beads.sh` | Beads のフックを `~/.claude/settings.json` へ追加 |
| `teardown-beads.sh` | Beads の導入を取り消す |
| `verify-beads.sh` | Beads の動作を検証する |
| `beads-stop-nudge.sh` | 記録漏れを促す Stop フック |

## 補足

**配置はシンボリックリンクです。** 原本を編集すれば即座に反映されます。既存のリンクの向き先が違う場合は現在のリポジトリへ付け替えます。

**作れない環境では自動的にコピーになります。** その場合は上流の更新が自動では届かないため、`git pull` のあとに `bootstrap.sh --global-only` を再実行してください。内容が異なるファイルは原本の内容で上書きされます。したがって `~/.claude/rules/` を直接編集しても次回の実行で失われます。

**シェルが使えない環境では手動で配置できます。** `rules/` のファイルを `~/.claude/rules/` へ、`.prompts/INIT.md` をプロジェクトへコピーし、`.git/info/exclude` に `exclude` の各行を追記してください。追記であって置き換えではありません。

**`--with-project-rules` は使わないでください。** プロジェクトの `.claude/rules/` へ実体をコピーする機能ですが、上流の更新に追随せず、`~/.claude/rules/` と二重に読み込まれます。

**Beads の取り消しは `teardown-beads.sh --restore` です。** `settings.json` をバックアップから復元し、`bd` が `CLAUDE.md` へ追記した管理ブロックも取り除きます。匿名利用統計は自動では戻しません。`bd` 本体と各リポジトリの `.beads/` も削除しません。

**Stop フックは応答の終了を止めません。** `decision: block` を返しますが、Claude Code 2.1.224 ではこれが提案として扱われます。記録を強制する仕組みではなく、記録漏れに気づかせる仕組みです。発火の間隔は `BD_STOP_STALE_SEC` と `BD_STOP_COOLDOWN_SEC` で変えられます。

## ライセンス

MIT License。詳細は [LICENSE](LICENSE) を参照してください。

## 更新履歴

各版の詳細は [リリース](https://github.com/AllegroMoltoV/my-claude-code-rules/releases) を参照してください。

| バージョン | 日付 | 内容 |
|---|---|---|
| v2.9.0 | 2026-08-22 | 計画の検証手順を具体化。独立した文脈のサブエージェントに反証させ、必要性・実現可能性・代替手段を最初に問う手順を `project.md` に追加した。モデル名は陳腐化するため書かず、セッションのモデルを継承させる。rules 5 ファイルの書式を統一し、H1 見出しと文末表現を揃え、見出しを置く基準を定めた。`documentation.md` の分割されたコードブロックを統合し、`working-principles.md` の重複した 2 節を統合。規則の項目数は減らしていない |
| v2.8.0 | 2026-08-14 | `project.md` に承認要求削減ルールを追加。許可判定の実装を公式ドキュメントで検証し、承認ダイアログ削減という誤った因果説明を修正した。Web 調査と Codex の敵対的レビュー (3 ラウンド) を経て、rules 5 ファイル全体の重複・抽象的な心構え表明・製品仕様依存の記述を削減。`testing.md` のカバレッジ目標をリスクベース基準に変更 |
| v2.7.0 | 2026-08-08 | `bootstrap.sh` に `--global-only` を追加し、グローバルの初回セットアップとプロジェクトのセットアップを分離。README を 2 フェーズ構成に書き換え、分量を約半分に圧縮 |
| v2.6.0 | 2026-08-08 | Stop フックの重複登録を修正。判定をコマンド文字列の完全一致からスクリプト名へ変更。`working-principles.md` に「エラーと証拠なしを同じ 0 件にしない」を追加。`.beads-optout` を追加 |
| v2.5.1 | 2026-08-08 | Markdown の改行も LF に固定。Stop フックは応答の終了を止めないという実測結果に説明を合わせた |
| v2.5.0 | 2026-08-08 | `working-principles.md` に 6 節、`documentation.md` に 3 節を追加。一般技術語の英語表記をカタカナへ統一。`teardown-beads.sh` の非復元箇所を修正 |
| v2.4.0 | 2026-08-07 | Beads の運用ルール、`project-bootstrap` スキル、スクリプト 6 本を追加。`INIT.md` を置き換え、`.gitattributes` を追加 |
| v2.3.0 | 2026-07-18 | `working-principles.md` を追加。日本語出力の半角スペース、曖昧な表現、モックの限界などの規約を明確化 |
| v2.2.0 | 2026-05-21 | 計画作成後に懸念点を洗い出し、推奨案を含む複数案を提示するフローを追加 |
| v2.1.0 | 2026-05-20 | `INIT.md` に調査先行の手順を追加。プランの品質基準、docs への蓄積、TDD 原則を追加 |
| v2.0.1 | 2026-03-03 | `.prompts/INIT.md` を追加し、`.prompts/` を追跡対象に変更 |
| v2.0.0 | 2026-03-03 | `.claude/rules/` 方式へ移行。リポジトリ名を `my-claude-code-rules` に変更 |
| v1.0.0 | 2026-02-25 | 初の安定版 |
| v0.1.1 | 2026-02-23 | 使い方の手順を具体化 |
| v0.1.0 | 2026-02-23 | 初版 |
