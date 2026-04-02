param($StatusDir, $StatusMd, $GoogleEnabled, $SpreadsheetId, $GoogleTool)
$lastHash = ""
while ($true) {
    Start-Sleep -Seconds 10
    $files = Get-ChildItem "$StatusDir/*.yaml" -ErrorAction SilentlyContinue
    if (-not $files) { continue }
    $currentHash = ($files | ForEach-Object { (Get-Item $_).LastWriteTime.Ticks }) -join ","
    if ($currentHash -eq $lastHash) { continue }
    $lastHash = $currentHash

    $lines = @("# Swarm Status", "Last updated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')", "")
    $lines += "## Active Tasks"
    $lines += "| Team | Task | Worker | Phase | Started |"
    $lines += "|------|------|--------|-------|---------|"
    $sheetsActive = @()
    $sheetsCompleted = @()

    foreach ($f in $files) {
        $yaml = Get-Content $f.FullName -Raw
        $team = $f.BaseName

        $inActive = $false; $inCompleted = $false
        foreach ($line in (Get-Content $f.FullName)) {
            if ($line -match "^active:") { $inActive = $true; $inCompleted = $false; continue }
            if ($line -match "^completed_today:") { $inActive = $false; $inCompleted = $true; continue }
            if ($line -match "^(blocked|skill_proposals|team|updated_at):") { $inActive = $false; $inCompleted = $false; continue }

            if ($inActive -and $line -match "description:\s*(.+)") {
                $desc = $Matches[1].Trim('"')
                $lines += "| $team | $desc | | | |"
                $sheetsActive += "$team,$desc"
            }
            if ($inCompleted -and $line -match "description:\s*(.+)") {
                $desc = $Matches[1].Trim('"')
                $sheetsCompleted += "$(Get-Date -Format 'HH:mm'),$team,$desc"
            }
        }
    }

    $lines += ""
    $lines += "## Completed Today"
    $lines += "| Time | Team | Task |"
    $lines += "|------|------|------|"
    $lines += ""

    $lines -join "`n" | Set-Content $StatusMd -Encoding UTF8

    if ($GoogleEnabled -eq "true" -and $SpreadsheetId) {
        try {
            if ($GoogleTool -eq "gog") {
                if ($sheetsActive.Count -gt 0) {
                    $data = ($sheetsActive -join "`n")
                    & gog sheets write $SpreadsheetId --range "Active!A2:B" --clear-first --data $data 2>$null
                }
            }
        } catch { }
    }
}
