# Matches each usage row to a directory user with the profile's ordered rules (spec 5.2).

# Normalize options (spec 5.2), applied in the order listed, to both sides of a compare.
function ConvertTo-NormalizedValue {
    param([string]$Value, [object[]]$Steps)
    if ($null -eq $Value) { return '' }
    $v = $Value
    foreach ($s in $Steps) {
        if ($s -is [System.Collections.IDictionary]) { $v = [regex]::Replace($v, $s.Pattern, $s.Replacement); continue }
        switch ($s) {
            'Trim' { $v = $v.Trim() }
            'ToLower' { $v = $v.ToLowerInvariant() }
            'StripDomainPrefix' { $i = $v.LastIndexOf('\'); if ($i -ge 0) { $v = $v.Substring($i + 1) } }
            'StripUpnSuffix' { $i = $v.IndexOf('@'); if ($i -ge 0) { $v = $v.Substring(0, $i) } }
        }
    }
    $v
}

# Sets on each row: MatchStatus (Matched | Ambiguous | Disabled | NoMatch), MatchRule, MatchValue,
# MatchDirValue, Candidates (directory IDs), User, PreferEnabledDropped, DisabledSkipped.
#   1. Try each rule in order. Empty values never match.
#   2. PreferEnabled and 2+ hits: drop disabled users.
#   3. One enabled user left: matched. 2+ left: Ambiguous, stop (never guess).
#   4. Every hit disabled: remember it. DisabledSoloHit 'Stop' ends here; 'TryNextRule' looks on for a live account.
#   5. Nothing better found: Disabled (if remembered), else NoMatch.
function Resolve-UserMatch {
    param([Parameter(Mandatory)] $Result)
    $cfg = $Result.Config
    $rules = $cfg.Match.Rules
    $indexes = [System.Collections.Generic.List[object]]::new()
    foreach ($rule in $rules) { $indexes.Add((New-DirectoryIndex $Result.Directory.Users $rule.AdAttribute $rule.Normalize $rule.Split)) }

    foreach ($row in $Result.Rows) {
        $done = $false; $firstDisabled = $null
        for ($i = 0; $i -lt $rules.Count -and -not $done; $i++) {
            $rule = $rules[$i]
            $key = ConvertTo-NormalizedValue ([string]$row.Fields[$rule.UsageField]) $rule.Normalize
            if (-not $key) { continue }
            $list = $null
            if (-not $indexes[$i].TryGetValue($key, [ref]$list)) { continue }
            $hits = @($list)
            $dropped = $false
            if ($hits.Count -gt 1 -and $cfg.Match.PreferEnabled) {
                $enabled = @($hits | Where-Object Enabled)
                if ($enabled.Count) { $dropped = $enabled.Count -lt $hits.Count; $hits = $enabled }
            }
            $set = { param($status, $user)
                $row.MatchStatus = $status; $row.MatchRule = $rule.Number; $row.MatchValue = $key
                $row.Candidates = @($hits | ForEach-Object Id); $row.User = $user
                $row.MatchDirValue = if ($user) { [string]$user.Record.($rule.AdAttribute) } else { $null }
            }
            if ($hits.Count -gt 1 -and @($hits | Where-Object Enabled).Count) {
                & $set 'Ambiguous' $null; $done = $true
            }
            elseif ($hits.Count -eq 1 -and $hits[0].Enabled) {
                & $set 'Matched' $hits[0]; $row.PreferEnabledDropped = $dropped; $row.DisabledSkipped = [bool]$firstDisabled; $done = $true
            }
            else {
                # Every hit is disabled.
                if (-not $firstDisabled) { $firstDisabled = @{ Rule = $rule; Key = $key; Hits = $hits } }
                if ($cfg.Match.DisabledSoloHit -eq 'Stop') { break }
            }
        }
        if ($done) { continue }
        if ($firstDisabled) {
            $hits = $firstDisabled.Hits
            $user = if ($hits.Count -eq 1) { $hits[0] } else { $null }
            $row.MatchStatus = 'Disabled'; $row.MatchRule = $firstDisabled.Rule.Number; $row.MatchValue = $firstDisabled.Key
            $row.Candidates = @($hits | ForEach-Object Id); $row.User = $user
            $row.MatchDirValue = if ($user) { [string]$user.Record.($firstDisabled.Rule.AdAttribute) } else { $null }
        }
        else { $row.MatchStatus = 'NoMatch' }
    }
    Write-MatchReport $Result
}

# Match report (spec 5.5): counts per rule and per outcome. Safe text only.
function Write-MatchReport {
    param($Result)
    $rows = @($Result.Rows)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Usage rows: $($rows.Count)")
    foreach ($rule in $Result.Config.Match.Rules) {
        $n = @($rows | Where-Object { $_.MatchStatus -eq 'Matched' -and $_.MatchRule -eq $rule.Number }).Count
        $lines.Add(('Rule {0} ({1} -> {2}): {3} matched' -f $rule.Number, $rule.UsageField, $rule.AdAttribute, $n))
    }
    $byStatus = [ordered]@{}
    foreach ($s in 'Matched', 'Disabled', 'Ambiguous', 'NoMatch') { $byStatus[$s] = @($rows | Where-Object MatchStatus -eq $s) }
    $lines.Add(('Matched: {0}   Disabled user: {1}   Ambiguous: {2}   No match: {3}' -f $byStatus.Matched.Count, $byStatus.Disabled.Count, $byStatus.Ambiguous.Count, $byStatus.NoMatch.Count))
    $Result.MatchReport = [ordered]@{ Lines = $lines.ToArray(); Counts = [ordered]@{} }
    foreach ($s in $byStatus.Keys) { $Result.MatchReport.Counts[$s] = $byStatus[$s].Count }

    $rowsOf = { param($set) [int[]]@($set | ForEach-Object RowNumber) }
    $fallback = @($rows | Where-Object { $_.MatchStatus -eq 'Matched' -and $_.MatchRule -gt 1 })
    if ($fallback.Count) { Add-Issue $Result Info FallbackRule "$($fallback.Count) rows matched by a fallback rule (not rule 1)." -Rows (& $rowsOf $fallback) }
    $dropped = @($rows | Where-Object PreferEnabledDropped)
    if ($dropped.Count) { Add-Issue $Result Info PreferEnabled "$($dropped.Count) rows matched after PreferEnabled dropped disabled duplicates." -Rows (& $rowsOf $dropped) }
    $skipped = @($rows | Where-Object DisabledSkipped)
    if ($skipped.Count) { Add-Issue $Result Info DisabledSkipped "$($skipped.Count) rows: an earlier rule found only disabled accounts; a later rule found a live one." -Rows (& $rowsOf $skipped) }
    if ($byStatus.Ambiguous.Count) { Add-Issue $Result Warning AmbiguousMatch "$($byStatus.Ambiguous.Count) rows match more than one directory user. Not picked. Fix with LinkTo." -Rows (& $rowsOf $byStatus.Ambiguous) }
    if ($byStatus.NoMatch.Count) { Add-Issue $Result Warning NoMatch "$($byStatus.NoMatch.Count) rows match no directory user. Not charged. Fix with LinkTo or Exclude." -Rows (& $rowsOf $byStatus.NoMatch) }
    if ($byStatus.Disabled.Count) { Add-Issue $Result Info DisabledUser "$($byStatus.Disabled.Count) rows belong to disabled directory users. Not charged." -Rows (& $rowsOf $byStatus.Disabled) }
}
