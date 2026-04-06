# Salary Man Guild

psmux（Windows native tmux）上で動くマルチエージェントAIチーム指揮システム。
ドメインごとに独立したチームを持ち、必要なチームだけ起動してプロジェクトを並行で進める。

```
./deploy.ps1 dev article       ← 開発チームと記事チームを起動
                                  各チーム: 1 Router + 5 Workers = 6 agents
                                  + Commander（あなたとの窓口）
```

---

## 起動手順

### 前提: インストール（初回のみ）

```powershell
# 1. psmux（Windows native tmux）
winget install psmux

# 2. Claude Code CLI
npm install -g @anthropic-ai/claude-code

# 3. Claude Code の認証（初回のみ。ブラウザが開く）
claude

# 4.（任意）Google Sheets 連携
brew install gogcli
gog auth add you@gmail.com
```

### 初回: クローンして起動

```powershell
git clone https://github.com/i-wa-man/salary-man-guild.git
cd salary-man-guild

# 必要なチームだけ起動
./deploy.ps1 dev article
```

### 2回目以降: プルして起動

```powershell
cd salary-man-guild
git pull

# 起動
./deploy.ps1 dev article
```

### deploy.ps1 のオプション

```powershell
./deploy.ps1 dev                # 1チーム起動
./deploy.ps1 dev article sns    # 複数チーム起動
./deploy.ps1 -All               # 全チーム起動
./deploy.ps1 dev -Battle        # 全員Opus（高品質モード）
./deploy.ps1 dev -Clean         # ボードをリセットして起動
./deploy.ps1 -List              # 利用可能なチーム一覧
./deploy.ps1 dev -SetupOnly     # セッション作成のみ（Claude起動なし）
```

### deploy.ps1 が自動でやること

```
1. ランタイムディレクトリ作成（boards/, results/, status/ 等）
2. チームごとにpsmuxセッション作成・pane分割（Router×1 + Worker×5）
3. 全paneで Claude Code CLI 起動
4. Router / Worker に初期指示を send-keys で送信
5. Commander セッション作成・起動
6. ダッシュボード監視ジョブ開始（バックグラウンド）
```

### 使う: Commander に接続して話しかける

```powershell
psmux attach -t commander
```

あとは自然言語で指示するだけ:

```
「商品Xの競合5社を調査して比較表を作成してくれ」
```

Commander がチームを選んで Router に指示 → Router がタスク分解 → Worker が並列実行 → 結果集約して報告。

### 進捗確認

```powershell
# Commander に聞く
「進捗は？」

# ダッシュボードを見る
cat status.md

# チームの中を直接覗く
psmux attach -t dev        # dev チームに接続
# Ctrl+B, 0 → Router画面
# Ctrl+B, 1 → Worker画面（5pane）
# Ctrl+B, d → detach して戻る
```

---

## チーム一覧

| Team | Domain | ドメイン知識 |
|------|--------|------------|
| **dev** | ソフトウェア開発、API、DB | `teams/dev/CLAUDE.md` |
| **design** | UI/UX、グラフィック、ワイヤーフレーム | `teams/design/CLAUDE.md` |
| **ops** | 保守運用、監視、インフラ | `teams/ops/CLAUDE.md` |
| **article** | ブログ、SEO記事、ホワイトペーパー | `teams/article/CLAUDE.md` |
| **sns** | SNS投稿、運用分析、エンゲージメント | `teams/sns/CLAUDE.md` |
| **strategy** | 事業戦略、市場分析、意思決定支援 | `teams/strategy/CLAUDE.md` |

### チームの追加

1. `teams/{name}.yaml` を作成（既存チームをコピーして編集）
2. `teams/{name}/CLAUDE.md` を作成（ドメイン知識を記述）
3. `./deploy.ps1 {name}` で起動

---

## データの流れ

```
あなた → Commander → Router → boards/{team}.yaml → Worker
                                                      │
                                                      ▼
                     Router ← results/{task_id}_result.yaml
                       │
                       ├── boards/{team}.yaml 更新（done）
                       ├── teams/{team}/CLAUDE.md に知見追記（自律）
                       ├── status/{team}.yaml 更新 → status.md 自動生成
                       └── Commander に完了通知 → あなたに報告
```

### ファイルの役割

| ファイル | 誰が書く | 誰が読む | 内容 |
|---------|---------|---------|------|
| `boards/{team}.yaml` | Router, Worker | Router, Worker | タスク一覧と状態 |
| `results/{id}_result.yaml` | Worker | Router | タスクの実行結果 |
| `teams/{team}/CLAUDE.md` | Router（追記） | 全エージェント | ドメイン知識（使うほど育つ） |
| `projects/{id}.yaml` | Router | Router, Worker | プロジェクト固有の知識・フェーズ |
| `status/{team}.yaml` | Router | Dashboard watcher | チームの現在状態 |
| `status.md` | Watcher（自動） | あなた | 全チーム横断のダッシュボード |
| `handoffs/` | Router A | Router B | チーム間の成果物受け渡し |
| `skill-proposals/` | Router | あなた | スキル化提案（承認/却下） |

---

## チーム構成: 1 Router + 5 Workers

```
psmux session: {team}
  pane 0: Router (Opus)       タスク分解、Worker管理、結果回収、知識蓄積
  pane 1: Worker 0 (Sonnet)   タスク実行、結果報告
  pane 2: Worker 1 (Sonnet)
  pane 3: Worker 2 (Sonnet)
  pane 4: Worker 3 (Sonnet)
  pane 5: Worker 4 (Sonnet)
```

- **Router**: タスクに分解してWorkerに投げる。自分では実作業しない
- **Worker**: ボードからタスクを取って実行。ドメイン知識（CLAUDE.md）に従って動く

Battle モード（`-Battle`）では全員 Opus になる。

---

## 知識の自律蓄積

タスク実行を通じて得た知見が `teams/{team}/CLAUDE.md` に自動蓄積される。

```
Worker: タスク実行中に知見を得る
  → 結果ファイルに knowledge_candidate として報告
  → Router が「この知見で未来のアウトプットが変わるか？」を判断
  → Yes → CLAUDE.md に追記
  → 次のタスクから全エージェントが参照
```

ユーザーの承認は不要。業務判断ではなくシステム運用のため。

---

## プロジェクト

プロジェクトごとにYAMLを作成。知識が蓄積される。

```powershell
cp projects/_template.yaml projects/product_x.yaml
# 編集して使う
```

```yaml
project:
  id: product_x
  name: "商品Xの販売"
  teams: [strategy, article, sns]
  knowledge:
    target_audience: "30代男性、IT企業勤務"
    tone: "プロフェッショナルだが堅すぎない"
  phases:
    - id: research
      depends_on: []
    - id: strategy
      depends_on: [research]
    - id: content
      depends_on: [strategy]
```

---

## 自律レベル

| Level | 人間の関与 |
|-------|----------|
| **L1** | 全判断でユーザー確認（初期状態） |
| **L2** | 戦略判断のみ確認 |
| **L3** | 異常時のみ報告 |

- 同じ判断を3回連続承認 → 昇格提案 → ユーザー承認で昇格
- 成果物を差し戻し → 即1段階降格

---

## Dashboard

### Local

各Routerが `status/{team}.yaml` を更新 → バックグラウンドで `status.md` 自動生成。

### Google Sheets (optional)

`config.yaml` で設定:

```yaml
google:
  dashboard:
    enabled: true
    spreadsheet_id: "1ABCxyz..."
```

---

## スキル提案

Worker が繰り返しパターンを発見 → 結果報告に記載 → Router が評価 →
`skill-proposals/` に記録 → ユーザー承認で `~/.claude/skills/` にグローバルスキル化。

---

## チーム間連携 (Handoffs)

```
Design team → wireframe → Dev team
```

`handoffs/` にhandoffファイルを置く。
L1ではユーザーが橋渡し。L2+ではRouter同士が自動連携。

---

## ファイル構成

```
├── CLAUDE.md                    # エージェント共通ルール
├── SPEC.md                      # 技術仕様書（全詳細）
├── config.yaml                  # グローバル設定
├── commander.md                 # Commander 指示書
├── router.md                    # Router 指示書（全チーム共通）
├── worker.md                    # Worker 指示書（全チーム共通）
├── deploy.ps1                   # デプロイスクリプト
├── watcher.ps1                  # ダッシュボード監視
│
├── teams/                       # チーム定義
│   ├── dev.yaml                 #   スコープ定義（what/not）
│   ├── dev/CLAUDE.md            #   ドメイン知識（原則・判断基準・蓄積知見）
│   ├── design.yaml
│   ├── design/CLAUDE.md
│   ├── ops.yaml
│   ├── ops/CLAUDE.md
│   ├── article.yaml
│   ├── article/CLAUDE.md
│   ├── sns.yaml
│   ├── sns/CLAUDE.md
│   ├── strategy.yaml
│   └── strategy/CLAUDE.md
│
├── projects/                    # プロジェクト定義 [runtime]
│   └── _template.yaml
├── boards/                      # タスクボード [runtime]
├── results/                     # タスク結果 [runtime]
├── handoffs/                    # チーム間受け渡し [runtime]
├── status/                      # チームステータス [runtime]
├── status.md                    # ダッシュボード [runtime, 自動生成]
└── skill-proposals/             # スキル提案 [runtime]
```

`[runtime]` = 実行時に生成。git tracked ではない。

---

## vs multi-agent-shogun (original)

| | Shogun | Salary Man Guild |
|--|--------|-----------------|
| Structure | 3-tier fixed (将軍→家老→足軽) | Independent domain teams |
| Sessions | 1 session, 10 agents | N sessions, 6 each |
| Platform | WSL + tmux | psmux (Windows native) |
| Workers | Fixed 8 | 5 per team, deploy as needed |
| Projects | Single focus | Multi-project |
| Dashboard | Local markdown | Local + Google Sheets |
| Knowledge | Memory MCP | Memory MCP + project knowledge + domain CLAUDE.md |
| Autonomy | Manual | L1→L2→L3 growth |
