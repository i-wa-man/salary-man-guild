# AI Swarm Architecture v3 - Domain Teams (Final)

## Overview

独立したドメインチームの集合。チームは必要に応じてデプロイ・追加する。

```
User
 │
 ├── design   [Router + Worker×5]   UI/UX、グラフィック
 ├── dev      [Router + Worker×5]   ソフトウェア開発
 ├── ops      [Router + Worker×5]   保守運用
 ├── article  [Router + Worker×5]   記事・ブログ
 ├── sns      [Router + Worker×5]   SNS運用
 ├── strategy [Router + Worker×5]   事業戦略
 └── (必要に応じて追加)
```

## Core Principles

1. **チーム = ドメイン**。タスクタイプではない。各チームが内部で調査→設計→実装→レビュー→改善のサイクルを回す。
2. **必要なチームだけデプロイ**。全チーム常時起動は不要。
3. **チームは独立**。チーム間連携はファイル経由（handoff）。
4. **スキルはグローバル**。`~/.claude/skills/` を全エージェントが共有。
5. **知識は蓄積**。プロジェクトのknowledgeが育つほど品質が上がる。
6. **自律性は成長**。L1（確認）→ L2（信頼）→ L3（自律）と昇格。

---

## Architecture

### Per Team

```
psmux session: {team_name}
├── Window: router    [1 pane]   Router (Opus, thinking disabled)
└── Window: workers   [5 panes]  Worker×5 (Sonnet)
                                 = 6 agents per team
```

### Formation Modes

| Mode | Router | Workers | Command |
|------|--------|---------|---------|
| Default | Opus (no thinking) | Sonnet | `./deploy.ps1 dev` |
| Battle | Opus (thinking) | Opus | `./deploy.ps1 dev -Battle` |

### Deployment Examples

```powershell
./deploy.ps1 dev                     # 1チーム (6 agents)
./deploy.ps1 dev article sns         # 3チーム (18 agents)
./deploy.ps1 -All                    # 全チーム (36 agents)
./deploy.ps1 -All -Battle            # 全チーム全Opus
./deploy.ps1 dev -Clean              # ボードリセットして起動
./deploy.ps1 -List                   # 利用可能チーム一覧
```

---

## File Structure

```
swarm/
├── config.yaml                  # グローバル設定
│     models, autonomy, google, cost, paths
│
├── router.md                    # Router指示書（全チーム共通）
│     タスク分解, Worker起動, 結果回収,
│     ダッシュボード更新, Sheets同期,
│     スキル化提案評価, フェーズDAG管理
│
├── worker.md                    # Worker指示書（全チーム共通）
│     タスク取得, 実行, セルフレビュー,
│     結果報告, スキル化候補発見
│
├── deploy.ps1                   # デプロイスクリプト
│
├── architecture.md              # この設計書
│
├── teams/                       # チーム定義（domain scope）
│   ├── design.yaml
│   ├── dev.yaml
│   ├── ops.yaml
│   ├── article.yaml
│   ├── sns.yaml
│   └── strategy.yaml
│
├── projects/                    # プロジェクト定義
│   ├── _template.yaml           # テンプレート
│   └── {project_id}.yaml        # phases, knowledge, teams, paths
│
├── boards/                      # チーム別タスクボード [runtime]
│   └── {team}.yaml
│
├── results/                     # タスク結果 [runtime]
│   └── {task_id}_result.yaml
│
├── handoffs/                    # チーム間連携 [runtime]
│   └── {project}_{from}_{to}.yaml
│
├── status/                      # チーム別ステータス [runtime]
│   └── {team}.yaml              # 各Routerが自チーム分を更新
│
├── status.md                    # 統合ダッシュボード
│                                  + Google Sheets同期（gog/gws）
│
└── skill-proposals/             # スキル化提案 [runtime]
    └── {sp_id}.yaml
```

---

## Communication

### Within a team

```
User → Router : 直接会話
Router → Worker : psmux send-keys (2-call method)
Worker → Router : psmux send-keys (2-call method)
Router → Board : swarm/boards/{team}.yaml を Edit
Worker → Result : swarm/results/{task_id}_result.yaml を Write
Router → Status : swarm/status/{team}.yaml を Edit
Router → Sheets : gog sheets write (config で enabled の場合)
```

### Between teams

```
Team A Router → swarm/handoffs/{file}.yaml → Team B Router
```

- L1: ユーザーが橋渡し
- L2+: Routerがhandoffファイルを書いて相手Routerをsend-keysで起こす

### send-keys Protocol

**必ず2回のBash/PowerShell呼び出しに分ける:**

```powershell
# 1回目: メッセージ
psmux send-keys -t {session}:{window}.{pane} 'メッセージ'
# 2回目: Enter
psmux send-keys -t {session}:{window}.{pane} Enter
```

複数Workerへの連続送信は**2秒間隔**。

---

## Project Management

### Project YAML (swarm/projects/{id}.yaml)

| Section | Purpose |
|---------|---------|
| project.paths | Drive/ローカルの参照先 |
| project.teams | 関わるチーム一覧 |
| project.autonomy | このプロジェクトの自律レベル |
| knowledge | **蓄積するドメイン知識** (ターゲット, トーン, 競合, 決定事項) |
| phases | **Phase DAG** (依存関係で順序制御。gate通過まで次フェーズ不可) |

### Phase DAG

```yaml
phases:
  - id: research
    depends_on: []
    gate: "Router review"
  - id: strategy
    depends_on: [research]
    gate: "User confirmation (L1)"
  - id: content
    depends_on: [strategy]
  - id: launch
    depends_on: [content]
    gate: "User final approval"
```

**ルール: gateを通過しないと次フェーズのタスクはボードに載らない。**

---

## Autonomy Model

### Levels

| Level | 人間の関与 |
|-------|-----------|
| L1 | 全gateでユーザー確認 |
| L2 | 戦略判断のみ確認 |
| L3 | 異常時のみ報告 |

### Promotion: L1 → L2 → L3

- 同じ種類の判断を**3回連続**でユーザーが承認 → 昇格提案
- ユーザーが承認して初めて昇格
- 成果物を差し戻されたら**即1段階降格**

### Always Ask (Level不問)

- 予算を伴う判断
- 外部への公開・送信
- 既存の方針の変更

---

## Skill Proposal Flow

```
Worker: 結果報告に skill_candidate: found: true を記載
  ↓
Router: 評価（他チームでも使える？2回以上？）
  ↓
Router: swarm/skill-proposals/{sp_id}.yaml に記録
  ↓
Router: status/{team}.yaml + Sheets の Skills タブに追記
  ↓
User: 承認 → ~/.claude/skills/ にグローバルスキルとして作成
```

---

## Google Workspace Integration

### Dashboard → Sheets

config.yaml で `google.dashboard.enabled: true` にすると、
Routerがタスク完了時に gog コマンドで Sheets を更新。

```bash
# Completed タブに行追加
gog sheets write {id} --range "Completed!A:E" --append --data "..."

# Active タブを全更新
gog sheets write {id} --range "Active!A2:F" --clear-first --data "..."
```

### Project Files → Drive

プロジェクト定義の `paths.drive` で Google Drive の同期フォルダを指定。
Google Drive デスクトップアプリでローカルマウント → 通常のファイルパスで参照。

---

## Adding a New Team

1. `swarm/teams/{name}.yaml` を作成:

```yaml
name: marketing
session: marketing
description: "広告運用、キャンペーン管理、コンバージョン最適化"

domain:
  what:
    - 広告キャンペーン設計
    - A/Bテスト計画
    - コンバージョン分析
  not:
    - クリエイティブ制作（→ design）
    - 記事執筆（→ article）
```

2. `./deploy.ps1 marketing` で起動

Router/Worker指示書は全チーム共通。チームYAMLがドメインを定義する。

---

## What's Inherited from Shogun

| Feature | Usage |
|---------|-------|
| Event-driven (no polling) | send-keys wake-up, 2-call method |
| YAML = source of truth | Boards, results, projects, team definitions |
| /clear protocol | Workers /clear after task completion |
| Memory MCP | Cross-session knowledge (shared globally) |
| Skill proposals | Worker discovers → Router evaluates → User approves |
| Dashboard | status.md + Google Sheets |

## What's Different from Shogun

| Shogun | Swarm |
|--------|-------|
| Fixed 3-tier (将軍→家老→足軽) | Independent domain teams |
| 1 session, 10 agents | N sessions, 6 agents each |
| Karo manually plans execution | Router decides per task |
| Always 8 workers running | Deploy only what you need |
| Single project focus | Multi-project via team composition |
| Samurai theme | Optional |
| Dashboard: Karo updates | Each Router updates own section |
| Local only | Local + Google Sheets sync |
