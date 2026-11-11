# dashboard.html (spec 9.6, 9.7): one static, self-contained file. The data goes inline as JSON; the page
# (Assets/dashboard.html) is plain HTML/CSS/JS with no external calls. Owner-only: it lists everyone.

function Write-Dashboard {
    param([Parameter(Mandatory)] $Result, [Parameter(Mandatory)] [string]$Path)
    $inv = [cultureinfo]::InvariantCulture
    $rows = @($Result.Rows)
    $index = @{}; for ($i = 0; $i -lt $rows.Count; $i++) { $index[$rows[$i].RowNumber] = $i }
    $idxOf = { param($set) [int[]]@($set | ForEach-Object { $index[$_.RowNumber] }) }
    $personKey = { param($r) if ($r.User) { "id:$($r.User.Id)" } else { 'p:' + (Get-PersonLabel $r $Result).ToLowerInvariant() } }
    $pool = @($rows | Where-Object State -ne 'NotHere')
    $notHere = @($rows | Where-Object State -eq 'NotHere')

    $seat = [decimal]0; $token = [decimal]0
    foreach ($r in $pool) { $seat += $r.SeatCharge; $token += $r.TokenCharge }

    $tree = Get-OrgTree $Result
    $managers = foreach ($n in $tree.Nodes.Values) {
        [ordered]@{
            key = $n.Key; name = $n.Name; direct = Format-Money $n.DirectTotal; team = Format-Money $n.TeamTotal
            people = if ($n.Direct) { $n.Direct.People.Count } else { 0 }
            rows = @(if ($n.Direct) { & $idxOf $n.Direct.Rows })
        }
    }

    $offerings = foreach ($g in $pool | Group-Object Package) {
        $s = [decimal]0; $t = [decimal]0
        foreach ($r in $g.Group) { $s += $r.SeatCharge; $t += $r.TokenCharge }
        [ordered]@{ name = $g.Name; seat = Format-Money $s; token = Format-Money $t; total = Format-Money ($s + $t); sort = $s + $t }
    }
    $offerings = @($offerings | Sort-Object @{ e = { $_.sort }; Descending = $true }, @{ e = { $_.name } } | ForEach-Object { $_.Remove('sort'); $_ })

    $byPerson = @{}
    foreach ($r in $pool | Where-Object Access -eq 'Token') {
        $k = & $personKey $r
        if (-not $byPerson.ContainsKey($k)) { $byPerson[$k] = [ordered]@{ person = Get-PersonLabel $r $Result; tokens = [decimal]0; charge = [decimal]0 } }
        $byPerson[$k].tokens += $r.Tokens; $byPerson[$k].charge += $r.TokenCharge
    }
    $topTokens = @($byPerson.Values | Sort-Object @{ e = { $_.charge }; Descending = $true }, @{ e = { $_.person } } | Select-Object -First 10 |
            ForEach-Object { [ordered]@{ person = $_.person; tokens = $_.tokens.ToString($inv); charge = Format-Money $_.charge } })

    $costCenters = $null
    if ($Result.Config.Ad.CostCenter) {
        $costCenters = @($pool | Group-Object { [string]$_.CostCenter } | ForEach-Object {
                $t = [decimal]0; foreach ($r in $_.Group) { $t += $r.RowTotal }
                [ordered]@{ name = $_.Name; total = Format-Money $t; sort = $t }
            } | Sort-Object @{ e = { $_.sort }; Descending = $true }, @{ e = { $_.name } } | ForEach-Object { $_.Remove('sort'); $_ })
    }

    $attention = [System.Collections.Generic.List[object]]::new()
    $attention.Add([ordered]@{ label = 'Not found or not here (not charged)'; level = 'warn'; count = $notHere.Count; rows = @(& $idxOf $notHere) })
    $needs = @($rows | Where-Object State -eq 'NeedsOwner')
    $attention.Add([ordered]@{ label = 'Rows that need an owner'; level = 'warn'; count = $needs.Count; rows = @(& $idxOf $needs) })
    $fallback = @($rows | Where-Object { $_.MatchStatus -eq 'Matched' -and $_.MatchRule -gt 1 })
    $attention.Add([ordered]@{ label = 'Rows matched by a fallback rule'; level = 'info'; count = $fallback.Count; rows = @(& $idxOf $fallback) })
    $loopIssue = @($Result.Issues | Where-Object Code -eq 'ManagerLoop')
    if ($loopIssue.Count) {
        $loopRows = @($rows | Where-Object { $loopIssue[0].Rows -contains $_.RowNumber })
        $attention.Add([ordered]@{ label = 'Rows under a manager loop (left out of roll-ups)'; level = 'warn'; count = $loopRows.Count; rows = @(& $idxOf $loopRows) })
    }
    $badOv = @($Result.Overrides.Items | Where-Object { $_.Status -like 'Override*' })
    if ($badOv.Count) { $attention.Add([ordered]@{ label = 'Overrides that could not be applied (see exceptions.csv)'; level = 'warn'; count = $badOv.Count; rows = @() }) }

    $exceptions = @($Result.Issues | Group-Object Code | ForEach-Object {
            $n = 0; foreach ($i in $_.Group) { $n += [Math]::Max(1, $i.Rows.Count) }
            [ordered]@{ level = $_.Group[0].Level; code = $_.Name; rows = $n; message = $_.Group[0].Message }
        })

    $rec = $Result.Reconciliation
    $data = [ordered]@{
        run         = [ordered]@{
            id = $Result.RunId; status = $Result.Status; reasons = @($Result.DraftReasons); vendor = $Result.Config.Vendor
            period = $Result.Quote.Period; started = $Result.Started.ToString('yyyy-MM-dd HH:mm'); toolVersion = $Result.ToolVersion
        }
        rec         = [ordered]@{
            quote = Format-Money $rec.QuoteTotal; allocated = Format-Money $rec.Allocated; unrecovered = Format-Money $rec.Unrecovered; balanced = $rec.Balanced
            pools = @($Result.Pools | ForEach-Object { [ordered]@{ name = $_.Name; price = Format-Money $_.Price; allocated = Format-Money $_.Allocated; rows = $_.RowCount; unrecoverable = $_.Unrecoverable; ignored = $_.Ignored } })
        }
        tiles       = [ordered]@{
            allocated = Format-Money $rec.Allocated
            users     = @($pool | ForEach-Object { & $personKey $_ } | Sort-Object -Unique).Count
            managers  = @(Get-ManagerSummary $Result | Where-Object Key -ne '~NO OWNER').Count
            notFound  = @($notHere | ForEach-Object { & $personKey $_ } | Sort-Object -Unique).Count
        }
        split       = [ordered]@{ seat = Format-Money $seat; token = Format-Money $token }
        managers    = @($managers)
        attention   = @($attention)
        offerings   = @($offerings)
        topTokens   = @($topTokens)
        costCenters = $costCenters
        exceptions  = @($exceptions)
        rows        = @(foreach ($r in $rows) {
                [ordered]@{
                    n = $r.RowNumber; person = Get-PersonLabel $r $Result; team = [string]$r.Fields['Team']; offering = $r.PackageRaw
                    access = $r.Access; tokens = $r.Tokens.ToString($inv); total = Format-Money $r.RowTotal
                    state = $r.State; reason = [string]$r.Reason; manager = [string]$r.ManagerName
                }
            })
    }
    # Lists must stay JSON arrays even with 0 or 1 items (PowerShell unrolls them otherwise).
    # Inline JSON: escape '<' so no value can close the <script> tag.
    $escapedLt = [string][char]0x5C + 'u003c'   # JSON escape for '<'
    $json = ($data | ConvertTo-Json -Depth 8 -Compress).Replace([string][char]0x3C, $escapedLt)
    $template = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'Assets/dashboard.html') -Raw -Encoding utf8
    [IO.File]::WriteAllText($Path, $template.Replace('__DIVVY_DATA__', $json), [Text.UTF8Encoding]::new($false))
}
