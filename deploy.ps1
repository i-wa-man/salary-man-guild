<#
.SYNOPSIS
    AI Swarm - Team deployment script for psmux

.DESCRIPTION
    Deploys one or more AI swarm teams as psmux sessions.
    Each team = 1 Router + 5 Workers.

.EXAMPLE
    ./deploy.ps1 dev                     # Dev team only
    ./deploy.ps1 dev article             # Dev + Article teams
    ./deploy.ps1 dev -Battle             # Dev team, all Opus
    ./deploy.ps1 -All                    # All teams
    ./deploy.ps1 -All -Battle            # All teams, all Opus
    ./deploy.ps1 dev -Clean              # Dev team, fresh board
    ./deploy.ps1 -All -SetupOnly         # All sessions, no Claude
    ./deploy.ps1 -List                   # Show available teams
#>

param(
    [Parameter(Position = 0, ValueFromRemainingArguments)]
    [string[]]$Teams,

    [switch]$All,
    [switch]$Battle,
    [switch]$Clean,
    [switch]$SetupOnly,
    [switch]$List
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location "$ScriptDir\.."

# ============================================================
# Constants
# ============================================================
$WorkersPerTeam = 5
$RouterModel = "opus"
$WorkerModel = if ($Battle) { "opus" } else { "sonnet" }
$FormationLabel = if ($Battle) { "BATTLE (All Opus)" } else { "Default (Router:Opus / Workers:Sonnet)" }

# ============================================================
# Discover available teams from swarm/teams/*.yaml
# ============================================================
$TeamsDir = "swarm/teams"
$AvailableTeams = @()
if (Test-Path $TeamsDir) {
    $AvailableTeams = Get-ChildItem "$TeamsDir/*.yaml" | ForEach-Object { $_.BaseName }
}

# ============================================================
# -List: show available teams and exit
# ============================================================
if ($List) {
    Write-Host ""
    Write-Host "  Available teams:" -ForegroundColor Cyan
    foreach ($t in $AvailableTeams) {
        $desc = ""
        $yamlPath = "$TeamsDir/$t.yaml"
        if (Test-Path $yamlPath) {
            foreach ($yline in (Get-Content $yamlPath)) {
                if ($yline.Contains("description:")) {
                    $desc = $yline.Split(":", 2)[1].Trim().Trim('"')
                    break
                }
            }
        }
        $padded = $t.PadRight(12)
        Write-Host "    $padded $desc" -ForegroundColor White
    }
    Write-Host ""
    exit 0
}

# ============================================================
# Determine which teams to deploy
# ============================================================
if ($All) {
    $Teams = $AvailableTeams
} elseif (-not $Teams -or $Teams.Count -eq 0) {
    Write-Host ""
    Write-Host "  AI Swarm - Team Deployment" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Usage:" -ForegroundColor White
    Write-Host "    ./deploy.ps1 <team> [team2] [options]" -ForegroundColor Gray
    Write-Host "    ./deploy.ps1 -List                      # Show teams" -ForegroundColor Gray
    Write-Host "    ./deploy.ps1 -All                       # All teams" -ForegroundColor Gray
    Write-Host "    ./deploy.ps1 dev article -Battle        # Specific teams, all Opus" -ForegroundColor Gray
    Write-Host "    ./deploy.ps1 dev -Clean                 # Fresh board" -ForegroundColor Gray
    Write-Host "    ./deploy.ps1 dev -SetupOnly             # No Claude launch" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Available teams: $($AvailableTeams -join ', ')" -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

# Validate team names
foreach ($t in $Teams) {
    if ($t -notin $AvailableTeams) {
        Write-Host "  Error: Unknown team '$t'" -ForegroundColor Red
        Write-Host "  Available: $($AvailableTeams -join ', ')" -ForegroundColor Gray
        exit 1
    }
}

# ============================================================
# Banner
# ============================================================
Write-Host ""
Write-Host "  ==========================================================" -ForegroundColor Cyan
Write-Host "    AI SWARM - Team Deployment" -ForegroundColor Cyan
Write-Host "  ==========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Formation : $FormationLabel" -ForegroundColor White
Write-Host "  Teams     : $($Teams -join ', ')" -ForegroundColor White
Write-Host "  Per team  : 1 Router ($RouterModel) + $WorkersPerTeam Workers ($WorkerModel)" -ForegroundColor White
$totalAgents = $Teams.Count * ($WorkersPerTeam + 1)
Write-Host "  Total     : $totalAgents agents across $($Teams.Count) team(s)" -ForegroundColor White
Write-Host ""

# ============================================================
# Ensure runtime directories exist
# ============================================================
$RuntimeDirs = @(
    "swarm/boards",
    "swarm/results",
    "swarm/projects",
    "swarm/handoffs",
    "swarm/status",
    "swarm/skill-proposals"
)
foreach ($dir in $RuntimeDirs) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# ============================================================
# Deploy each team
# ============================================================
foreach ($teamName in $Teams) {
    $session = $teamName
    Write-Host "  [$teamName] " -ForegroundColor Yellow -NoNewline

    # Kill existing session
    psmux kill-session -t $session 2>$null

    # Board: reset (-Clean) or ensure exists
    $boardPath = "swarm/boards/$teamName.yaml"
    if ($Clean) {
        if (Test-Path $boardPath) {
            $bcontent = Get-Content $boardPath -Raw
            if ($bcontent.Contains("task_")) {
                $ts = Get-Date -Format "yyyyMMdd_HHmmss"
                $backupDir = "swarm/logs/backup_$ts"
                New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
                Copy-Item $boardPath "$backupDir/"
            }
        }
        "# $teamName team task board`ntasks: []" | Set-Content $boardPath -Encoding UTF8
    } else {
        if (-not (Test-Path $boardPath)) {
            "# $teamName team task board`ntasks: []" | Set-Content $boardPath -Encoding UTF8
        }
    }

    # Status file: ensure exists
    $statusPath = "swarm/status/$teamName.yaml"
    if (-not (Test-Path $statusPath)) {
        $sc = @("team: $teamName", "updated_at: """"", "active: []", "completed_today: []", "blocked: []", "skill_proposals: []")
        $sc -join "`n" | Set-Content $statusPath -Encoding UTF8
    }

    # Create psmux session (1 window, 6 panes: Router + 5 Workers)
    # Pane 0: Router
    psmux new-session -d -s $session -n "team"
    psmux set-option -p -t "$($session):team.0" @agent_id "router"
    psmux set-option -p -t "$($session):team.0" @team_name $teamName
    psmux send-keys -t "$($session):team.0" "cd ""$(Get-Location)""" Enter

    # Panes 1-5: Workers
    for ($i = 0; $i -lt $WorkersPerTeam; $i++) {
        $p = $i + 1
        if ($p % 2 -eq 1) {
            psmux split-window -t "$($session):team" -h
        } else {
            psmux split-window -t "$($session):team" -v
        }
        psmux set-option -p -t "$($session):team.$p" @agent_id "worker_$i"
        psmux set-option -p -t "$($session):team.$p" @team_name $teamName
        psmux send-keys -t "$($session):team.$p" "cd ""$(Get-Location)""" Enter
    }

    psmux select-layout -t "$($session):team" tiled 2>$null

    # Pane border labels
    psmux set-option -t $session -w pane-border-status top
    psmux set-option -t $session -w pane-border-format "#{@team_name}/#{@agent_id}"

    Write-Host "session created" -ForegroundColor Gray -NoNewline

    # Launch Claude Code (unless -SetupOnly)
    if (-not $SetupOnly) {
        # Router (pane 0)
        psmux send-keys -t "$($session):team.0" "claude --model $RouterModel --dangerously-skip-permissions"
        psmux send-keys -t "$($session):team.0" Enter

        Start-Sleep -Seconds 2

        # Workers (panes 1-5)
        for ($i = 0; $i -lt $WorkersPerTeam; $i++) {
            $p = $i + 1
            psmux send-keys -t "$($session):team.$p" "claude --model $WorkerModel --dangerously-skip-permissions"
            psmux send-keys -t "$($session):team.$p" Enter
            Start-Sleep -Milliseconds 500
        }

        Write-Host " > Claude launched" -ForegroundColor Gray -NoNewline

        # Wait for Router ready (max 30s)
        $ready = $false
        for ($w = 0; $w -lt 30; $w++) {
            $capture = psmux capture-pane -t "$($session):team.0" -p 2>$null
            if ($capture -and $capture.ToString().Contains("bypass permissions")) {
                $ready = $true
                break
            }
            Start-Sleep -Seconds 1
        }

        if ($ready) {
            # Load instructions: Router (pane 0)
            psmux send-keys -t "$($session):team.0" "Read swarm/router.md, swarm/teams/$teamName.yaml, swarm/config.yaml. You are the Router of the $teamName team."
            Start-Sleep -Milliseconds 500
            psmux send-keys -t "$($session):team.0" Enter

            Start-Sleep -Seconds 2

            # Load instructions: Workers (panes 1-5)
            for ($i = 0; $i -lt $WorkersPerTeam; $i++) {
                $p = $i + 1
                psmux send-keys -t "$($session):team.$p" "Read swarm/worker.md and swarm/teams/$teamName.yaml. You are worker_$i in the $teamName team."
                Start-Sleep -Milliseconds 300
                psmux send-keys -t "$($session):team.$p" Enter
                Start-Sleep -Seconds 1
            }
            Write-Host " > instructions loaded" -ForegroundColor Gray -NoNewline
        } else {
            Write-Host " > WARNING: Router not ready in 30s" -ForegroundColor Yellow -NoNewline
        }
    }

    Write-Host " > Ready" -ForegroundColor Green
}

# ============================================================
# Start dashboard watcher (background)
# ============================================================
Write-Host "  Starting dashboard watcher..." -ForegroundColor Yellow
$watcherArgs = @(
    "swarm/status",
    "swarm/status.md",
    "true",
    "",
    "gog"
)
foreach ($cfgLine in (Get-Content "swarm/config.yaml" -ErrorAction SilentlyContinue)) {
    if ($cfgLine.Contains("spreadsheet_id:")) {
        $sid = $cfgLine.Split(":", 2)[1].Trim().Trim('"')
        if ($sid.Length -gt 0) { $watcherArgs[3] = $sid }
    }
}
$watcherPath = Join-Path $ScriptDir "watcher.ps1"
$watcher = Start-Job -FilePath $watcherPath -ArgumentList $watcherArgs
Write-Host "  Dashboard watcher running (Job $($watcher.Id))." -ForegroundColor Green
Write-Host ""

# ============================================================
# Summary
# ============================================================
Write-Host ""
Write-Host "  ==========================================================" -ForegroundColor Green
Write-Host "    All teams deployed." -ForegroundColor Green
Write-Host "  ==========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Connect:" -ForegroundColor White
foreach ($t in $Teams) {
    $padded = $t.PadRight(12)
    Write-Host "    psmux attach -t $padded  # Router + $WorkersPerTeam Workers" -ForegroundColor Gray
}
Write-Host ""
Write-Host "  Files:" -ForegroundColor White
Write-Host "    Boards    : swarm/boards/{team}.yaml" -ForegroundColor Gray
Write-Host "    Results   : swarm/results/" -ForegroundColor Gray
Write-Host "    Status    : swarm/status.md" -ForegroundColor Gray
Write-Host "    Projects  : swarm/projects/" -ForegroundColor Gray
Write-Host "    Proposals : swarm/skill-proposals/" -ForegroundColor Gray
Write-Host ""

# ============================================================
# Launch Commander (interactive, stays in this terminal)
# ============================================================
Write-Host "  ==========================================================" -ForegroundColor Cyan
Write-Host "    Launching Commander..." -ForegroundColor Cyan
Write-Host "    Talk to the Commander to give instructions to your teams." -ForegroundColor Gray
Write-Host "    Open new tabs and run 'psmux attach -t <team>' to watch." -ForegroundColor Gray
Write-Host "  ==========================================================" -ForegroundColor Cyan
Write-Host ""

claude --model opus --dangerously-skip-permissions
