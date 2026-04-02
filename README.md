# AI Swarm - Domain Teams on psmux

multi-agent-shogunの設計思想をベースに、psmux（Windows native tmux）上で動くAIスウォーム。

## What is this?

ドメイン（領域）ごとに独立したチームを持つマルチエージェントシステム。
必要なチームだけ起動して、プロジェクトを並行で進める。

```
./deploy.ps1 dev article       ← 開発チームと記事チームを起動
                                  各チーム: 1 Router + 5 Workers = 6 agents
```

## Quick Start

### Prerequisites

- [psmux](https://github.com/psmux/psmux) (`winget install psmux`)
- [Claude Code CLI](https://www.npmjs.com/package/@anthropic-ai/claude-code) (`npm install -g @anthropic-ai/claude-code`)
- (optional) [gog](https://gogcli.sh/) for Google Sheets sync (`brew install gogcli`)

### Deploy

```powershell
cd multi-agent-shogun

# 1チーム起動
./swarm/deploy.ps1 dev

# 複数チーム起動
./swarm/deploy.ps1 dev article sns

# 全チーム起動
./swarm/deploy.ps1 -All

# 全員Opusモード（Battle）
./swarm/deploy.ps1 dev -Battle

# ボードをリセットして起動
./swarm/deploy.ps1 dev -Clean

# 利用可能チーム一覧
./swarm/deploy.ps1 -List
```

### Connect

```powershell
# チームのRouterに接続
psmux attach -t dev

# Router画面（window: router）
psmux select-window -t dev:router

# Worker画面（window: workers、5ペイン）
psmux select-window -t dev:workers
```

### Give an Order

Routerに接続して指示を出す:

```
「商品Xの競合5社を調査して比較表を作成せよ」
```

Routerがタスクに分解 → Workerに並列投入 → 結果を集約して報告。

---

## Teams

| Team | Session | Domain |
|------|---------|--------|
| **design** | `design` | UI/UX、グラフィック、ワイヤーフレーム |
| **dev** | `dev` | ソフトウェア開発、API、DB |
| **ops** | `ops` | 保守運用、監視、インフラ |
| **article** | `article` | ブログ、SEO記事、ホワイトペーパー |
| **sns** | `sns` | SNS投稿、運用分析、エンゲージメント |
| **strategy** | `strategy` | 事業戦略、市場分析、意思決定支援 |

### Adding a Team

1. `swarm/teams/{name}.yaml` を作成（既存チームをコピーして編集）
2. `./deploy.ps1 {name}` で起動

---

## Per Team: 1 Router + 5 Workers

```
psmux session: {team}
├── Window: router    [1 pane]   Router (Opus)
│     タスク分解、Worker起動、結果回収、ダッシュボード更新
│
└── Window: workers   [5 panes]  Worker×5 (Sonnet / Battle時Opus)
      タスク実行、結果報告
```

- **Router**: リクエストを受けてタスクに分解し、Workerに投げる。自分では実作業しない。
- **Worker**: ボードからタスクを取って実行し、結果を報告する。

各チームが内部で「調査→設計→実装→レビュー→改善」のサイクルを回す。
サイクルのどのフェーズを踏むかはRouterがタスクごとに判断する。

---

## Projects

プロジェクトごとにYAMLを作成。ドメイン知識が蓄積される。

```powershell
# テンプレートをコピー
cp swarm/projects/_template.yaml swarm/projects/product_x.yaml
# 編集して使う
```

```yaml
project:
  id: product_x
  name: "商品Xの販売"
  teams: [strategy, article, sns]
  paths:
    drive: "G:/My Drive/Projects/product_x"

  knowledge:                    # ← プロジェクトを進めるほど蓄積
    target_audience: "30代男性、IT企業勤務"
    tone: "プロフェッショナルだが堅すぎない"
    decisions:
      - date: "2026-03-29"
        what: "価格帯は月額3,000-5,000円"

  phases:                       # ← DAG: 依存関係で順序制御
    - id: research
      depends_on: []
    - id: strategy
      depends_on: [research]
    - id: content
      depends_on: [strategy]
```

---

## Dashboard

### Local

各Routerが `swarm/status/{team}.yaml` を更新。

### Google Sheets (optional)

`swarm/config.yaml` で設定:

```yaml
google:
  dashboard:
    enabled: true
    spreadsheet_id: "1ABCxyz..."
```

Routerがタスク完了時に `gog sheets write` でスプレッドシートに同期。

---

## Autonomy Levels

| Level | Description |
|-------|-------------|
| **L1** | 全判断でユーザー確認（初期状態） |
| **L2** | 戦略判断のみ確認 |
| **L3** | 異常時のみ報告 |

同じ判断を3回連続承認 → 昇格提案。ユーザー承認で昇格。
成果物を差し戻されたら → 即1段階降格。

---

## Skill Proposals

Workerが繰り返しパターンを発見 → 結果報告に記載 → Routerが評価 →
`swarm/skill-proposals/` に記録 → ユーザー承認でグローバルスキル化。

---

## Team Coordination (Handoffs)

チーム間の成果物受け渡し:

```
Design team → wireframe.fig → Dev team
```

`swarm/handoffs/` にhandoffファイルを置く。
L1ではユーザーが橋渡し。L2+ではRouter同士が自動連携。

---

## File Structure

```
swarm/
├── config.yaml              # Global settings
├── router.md                # Router instructions (shared)
├── worker.md                # Worker instructions (shared)
├── deploy.ps1               # Deployment script
├── architecture.md          # Full design document
├── README.md                # This file
├── teams/                   # Team definitions
│   ├── design.yaml
│   ├── dev.yaml
│   ├── ops.yaml
│   ├── article.yaml
│   ├── sns.yaml
│   └── strategy.yaml
├── projects/                # Project definitions [runtime]
│   └── _template.yaml
├── boards/                  # Task boards [runtime]
├── results/                 # Task results [runtime]
├── handoffs/                # Team handoffs [runtime]
├── status/                  # Per-team status [runtime]
└── skill-proposals/         # Skill proposals [runtime]
```

`[runtime]` = 実行時に生成。git tracked ではない（.gitignoreで除外）。

---

## vs multi-agent-shogun (original)

| | Shogun | Swarm |
|--|--------|-------|
| Structure | 3-tier fixed (将軍→家老→足軽) | Independent domain teams |
| Sessions | 1 session, 10 agents | N sessions, 6 each |
| Platform | WSL + tmux | psmux (Windows native) |
| Workers | Fixed 8 numbered | 5 per team, deploy as needed |
| Projects | Single focus | Multi-project |
| Dashboard | Local markdown | Local + Google Sheets |
| Learning | Memory MCP | Memory MCP + project knowledge |
| Autonomy | Manual | L1→L2→L3 growth |

---

## Status: 🚧 Work in Progress

This is an evolving design. Core architecture is defined.
Feedback and iteration are expected.
