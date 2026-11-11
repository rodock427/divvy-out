# diagnostics.txt: safe to share (spec 9.5). Names of columns and attributes, counts, row numbers,
# masked value shapes. No names, no emails, no money unless -IncludeAmounts.
# Written on every run, including failed runs, so it must never throw.

function Write-Diagnostics {
    param([Parameter(Mandatory)] $Result, [Parameter(Mandatory)] [string]$Path)
    $sb = [System.Text.StringBuilder]::new()
    $w = { param([string]$t = '') [void]$sb.AppendLine($t) }
    $amounts = [bool]$Result.Options.IncludeAmounts
    $money = { param($d) if ($null -eq $d) { '-' } else { ([decimal]$d).ToString('#,##0.00', [cultureinfo]::InvariantCulture) } }

    try {
        & $w ('DivvyOut diagnostics. Safe to share: no names, no emails' + $(if ($amounts) { '. AMOUNTS INCLUDED (-IncludeAmounts).' } else { ', no amounts.' }))
        & $w ('=' * 72)
        & $w "Run:         $($Result.RunId)"
        & $w "Status:      $($Result.Status)"
        foreach ($reason in $Result.DraftReasons) { & $w "             - $reason" }
        & $w "Tool:        DivvyOut $($Result.ToolVersion)"
        & $w "PowerShell:  $($Result.PSVersion) on $($Result.Os)"
        & $w "Modules:     $(($Result.ModuleVersions.Keys | ForEach-Object { "$_ $($Result.ModuleVersions[$_])" }) -join ', ')"
        & $w "Started:     $($Result.Started.ToString('yyyy-MM-dd HH:mm:ss'))"

        & $w; & $w '[Inputs]  (file names are not shown)'
        foreach ($role in $Result.Inputs.Keys) {
            $i = $Result.Inputs[$role]
            $extra = switch ($role) {
                'Usage' { "rows=$($Result.Usage.RowCount) columns=$(@($Result.Usage.Headers).Count)" }
                'Directory' { "rows=$($Result.Directory.RowCount) columns=$(@($Result.Directory.Columns).Count)" }
                'Overrides' { "rows=$(@($Result.Overrides.Items).Count)" }
                default { '' }
            }
            & $w ('  {0,-10} {1,-12} {2}' -f $role, $(if ($i.Extension) { $i.Extension } else { $i.Name }), $extra)
        }

        $c = $Result.Config
        if ($c) {
            & $w; & $w '[Profile]'
            & $w "  Vendor: $($c.Vendor)   HeaderRow: $($c.Usage.HeaderRow)   Sheet: $(if ($c.Usage.Sheet) { $c.Usage.Sheet } else { '(first)' })   Encoding: $($c.Usage.Encoding)"
            & $w '  Column map (canonical <- header):'
            foreach ($f in $c.Usage.Columns.Keys) {
                $h = $c.Usage.Columns[$f]
                $found = if (@($Result.Usage.Headers | Where-Object { $_.Trim() -eq $h }).Count) { 'found' } elseif (@($Result.Usage.Headers).Count) { 'MISSING' } else { '?' }
                & $w ('    {0,-14} <- {1,-30} {2}' -f $f, "'$h'", $found)
            }
            & $w "  Access options: $(($c.Usage.AccessOptionValues.Keys | ForEach-Object { "$_='$($c.Usage.AccessOptionValues[$_])'" }) -join ', ')"
            & $w "  Offering aliases: $($c.Usage.OfferingAliases.Count)"
            & $w "  Match: PreferEnabled=$($c.Match.PreferEnabled) DisabledSoloHit=$($c.Match.DisabledSoloHit)"
            foreach ($r in $c.Match.Rules) {
                & $w ('    {0}. {1} -> {2}  [{3}]{4}' -f $r.Number, $r.UsageField, $r.AdAttribute, (Format-NormalizeSteps $r.Normalize), $(if ($r.Split) { " split '$($r.Split)'" } else { '' }))
            }
            $a = $c.Ad
            & $w "  Directory: Id=$($a.IdAttribute) Enabled=$($a.EnabledColumn)='$($a.EnabledValue)' Manager=$($a.ManagerAttribute) (refers to $($a.ManagerKeyAttribute)) Display=$($a.DisplayAttribute) CostCenter=$(if ($a.CostCenter) { $a.CostCenter.Attribute } else { '(none)' })"
            & $w '  Override key rules:'
            foreach ($r in $c.Overrides.KeyRules) {
                $src = if ($r.UsageField) { "usage $($r.UsageField)" } else { "directory $($r.AdAttribute)" }
                & $w ('    {0}. {1}  [{2}]' -f $r.Number, $src, (Format-NormalizeSteps $r.Normalize))
            }
            if ($c.Overrides.ManagerLookup) { & $w "  Manager lookup: $($c.Overrides.ManagerLookup.AdAttribute)  [$(Format-NormalizeSteps $c.Overrides.ManagerLookup.Normalize)]" }
            & $w "  Policy: $(($c.Policy.Keys | ForEach-Object { "$_=$($c.Policy[$_])" }) -join ' ')"
        }

        if (@($Result.Usage.Headers).Count) {
            & $w; & $w '[Usage headers found]'
            $n = 0; foreach ($h in $Result.Usage.Headers) { $n++; & $w ('  {0,3}  {1}' -f $n, $h) }
        }
        if (@($Result.Directory.Columns).Count) {
            & $w; & $w '[Directory columns found]'
            & $w ('  ' + ($Result.Directory.Columns -join ', '))
        }
        if (@($Result.Overrides.Columns).Count) {
            & $w; & $w '[Override columns found]'
            & $w ('  ' + ($Result.Overrides.Columns -join ', '))
        }

        $issues = @($Result.Issues)
        & $w; & $w "[Issues]  errors=$(@($issues | Where-Object Level -eq 'Error').Count) warnings=$(@($issues | Where-Object Level -eq 'Warning').Count) info=$(@($issues | Where-Object Level -eq 'Info').Count)"
        foreach ($level in 'Error', 'Warning', 'Info') {
            foreach ($i in $issues | Where-Object Level -eq $level) {
                & $w ('  {0,-7} {1,-22} {2}' -f $level.ToUpper(), $i.Code, $i.Message)
                if ($i.Rows.Count) { & $w "          rows ($($i.Rows.Count)): $(Format-RowList $i.Rows)" }
            }
        }

        $mr = $Result.MatchReport
        if ($mr) {
            & $w; & $w '[Match report]'
            foreach ($line in $mr.Lines) { & $w "  $line" }
        }

        $rows = @($Result.Rows)
        if ($rows.Count -and $rows[0].State) {
            & $w; & $w '[Row states]'
            foreach ($g in $rows | Group-Object State, Reason | Sort-Object Name) { & $w ('  {0,-36} {1,6}' -f $g.Name, $g.Count) }
        }

        $failed = @($rows | Where-Object { $_.MatchStatus -in 'NoMatch', 'Ambiguous' })
        if ($failed.Count -and $c) {
            $fields = @($c.Match.Rules | ForEach-Object UsageField | Select-Object -Unique)
            & $w; & $w "[Failed matches]  $($failed.Count) rows, values masked (first 200)"
            foreach ($r in $failed | Select-Object -First 200) {
                $shapes = ($fields | ForEach-Object { "$_=$(Get-MaskedShape $r.Fields[$_])" }) -join '  '
                & $w ('  row {0,-6} {1,-10} {2}' -f $r.RowNumber, $r.MatchStatus, $shapes)
            }
        }

        $rec = $Result.Reconciliation
        if ($rec) {
            & $w; & $w '[Reconciliation]'
            & $w "  Pools: $($rec.PoolCount)  unrecoverable: $($rec.UnrecoveredPools)  balanced: $($rec.Balanced)"
            if ($amounts) {
                & $w "  Quote total: $(& $money $rec.QuoteTotal)   Allocated: $(& $money $rec.Allocated)   Unrecovered: $(& $money $rec.Unrecovered)"
                foreach ($p in $Result.Pools) { & $w ('    {0,-40} price {1,14}  rows {2,5}  allocated {3,14}' -f $p.Name, (& $money $p.Price), $p.RowCount, (& $money $p.Allocated)) }
            }
        }

        if ($Result.Fatal) {
            & $w; & $w '[Stopped]'
            $ex = $Result.Fatal.Exception
            if ($ex.Data['DivvyStop']) { & $w "  $($ex.Message)" }
            else {
                # Unexpected error: the message may contain data values, so show the type and where it happened only.
                & $w "  Unexpected error: $($ex.GetType().FullName)"
                $trace = [string]$Result.Fatal.ScriptStackTrace -replace '(?m)(, )[^,\r\n]*[\\/]', '$1'
                foreach ($t in $trace -split "`r?`n") { & $w "    $t" }
            }
        }
    }
    catch {
        & $w; & $w "[Diagnostics writer error] $($_.Exception.GetType().FullName) at line $($_.InvocationInfo.ScriptLineNumber)"
    }
    Set-Content -LiteralPath $Path -Value $sb.ToString() -Encoding utf8BOM
}

function Format-NormalizeSteps {
    param([object[]]$Steps)
    (@($Steps) | ForEach-Object { if ($_ -is [System.Collections.IDictionary]) { "Regex '$($_.Pattern)'" } else { $_ } }) -join ','
}
