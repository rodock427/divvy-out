# Org tree for roll-ups (spec 8). A roll-up is a view: it never changes who is charged.
#   - Nodes: every charge owner (from Get-ManagerSummary, NO OWNER excluded) plus their managers up the chain.
#   - A person's manager: an override Manager for that person if one applied, else the directory manager.
#   - Disabled managers are skipped: the node attaches to the next enabled manager above.
#   - Manager loops: the loop members are warned and left out of roll-ups (no parent, no roll-up,
#     not under anyone). People below a loop become top-level.
#   - A free-text override manager is a top-level node.

function Get-OrgTree {
    param([Parameter(Mandatory)] $Result)
    if ($Result.Contains('OrgTree') -and $Result.OrgTree) { return $Result.OrgTree }
    $byId = $Result.Directory.ById

    # Manager set by override, per person (directory ID): only from overrides that were used.
    $overrideParent = @{}
    foreach ($o in @($Result.Overrides.Items | Where-Object { $_.Status -in 'OK', 'TreeOnly' -and $_.Manager })) {
        $people = @(if ($o.TargetUser) { $o.TargetUser }) + @($Result.Rows | Where-Object { $_.Override -eq $o -and $_.User } | ForEach-Object User)
        $parent = if ($o.ManagerUser) { "id:$($o.ManagerUser.Id)" } else { "text:$($o.Manager)" }
        foreach ($p in $people) { $overrideParent["id:$($p.Id)"] = $parent }
    }
    $rawParent = {
        param([string]$key)
        if ($overrideParent.ContainsKey($key)) { return $overrideParent[$key] }
        if (-not $key.StartsWith('id:')) { return $null }
        $user = $null
        if (-not $byId.TryGetValue($key.Substring(3), [ref]$user)) { return $null }
        $m = Get-DirectoryManager $user $Result
        if ($m.User) { "id:$($m.User.Id)" } else { $null }
    }
    $enabled = {
        param([string]$key)
        if (-not $key.StartsWith('id:')) { return $true }
        $user = $null
        $byId.TryGetValue($key.Substring(3), [ref]$user) -and $user.Enabled
    }
    $display = {
        param([string]$key)
        if ($key.StartsWith('text:')) { return $key.Substring(5) }
        $user = $null
        if ($byId.TryGetValue($key.Substring(3), [ref]$user)) { $user.Display } else { $key.Substring(3) }
    }

    $summary = @(Get-ManagerSummary $Result | Where-Object Key -ne '~NO OWNER')

    # Loops in the raw manager chain, starting from every owner.
    $loop = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($g in $summary) {
        $path = [System.Collections.Generic.List[string]]::new()
        $cur = $g.Key
        while ($cur) {
            $at = $path.IndexOf($cur)
            if ($at -ge 0) { for ($i = $at; $i -lt $path.Count; $i++) { [void]$loop.Add($path[$i]) }; break }
            if ($loop.Contains($cur)) { break }
            $path.Add($cur)
            $cur = & $rawParent $cur
        }
    }
    # Effective parent: next enabled manager up; none if the chain reaches a loop.
    $effParent = {
        param([string]$key)
        if ($loop.Contains($key)) { return $null }
        $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        [void]$seen.Add($key)
        $cur = & $rawParent $key
        while ($cur) {
            if ($loop.Contains($cur) -or -not $seen.Add($cur)) { return $null }
            if (& $enabled $cur) { return $cur }
            $cur = & $rawParent $cur
        }
        $null
    }

    $nodes = [ordered]@{}
    $newNode = { param([string]$key)
        [pscustomobject]@{
            Key = $key; Id = if ($key.StartsWith('id:')) { $key.Substring(3) } else { '' }; Name = & $display $key
            Direct = $null; Parent = $null; Children = [System.Collections.Generic.List[object]]::new(); InLoop = $loop.Contains($key)
            DirectTotal = [decimal]0; TeamTotal = [decimal]0
        }
    }
    foreach ($g in $summary) {
        if (-not $nodes.Contains($g.Key)) { $nodes[$g.Key] = & $newNode $g.Key }
        $nodes[$g.Key].Direct = $g
        $nodes[$g.Key].DirectTotal = $g.Total
    }
    # Attach every node to its effective parent, creating manager nodes up the chain.
    $todo = [System.Collections.Generic.Queue[string]]::new()
    foreach ($k in @($nodes.Keys)) { $todo.Enqueue($k) }
    $linked = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    while ($todo.Count) {
        $k = $todo.Dequeue()
        if (-not $linked.Add($k)) { continue }
        $p = & $effParent $k
        if (-not $p) { continue }
        if (-not $nodes.Contains($p)) { $nodes[$p] = & $newNode $p; $todo.Enqueue($p) }
        $nodes[$k].Parent = $nodes[$p]
        $nodes[$p].Children.Add($nodes[$k])
    }
    # Children in name order (ordinal), so every view is stable.
    foreach ($n in $nodes.Values) {
        if ($n.Children.Count -gt 1) {
            $sorted = @(Get-SortedByKey $n.Children.ToArray() { param($c) "$($c.Name)`0$($c.Key)" })
            $n.Children.Clear(); foreach ($c in $sorted) { $n.Children.Add($c) }
        }
    }
    # With teams below = own direct charge + every node beneath.
    $sumTeam = $null
    $sumTeam = { param($n) $t = $n.DirectTotal; foreach ($c in $n.Children) { $t += & $sumTeam $c }; $n.TeamTotal = $t; $t }
    $roots = @(Get-SortedByKey @($nodes.Values | Where-Object { -not $_.Parent }) { param($c) "$($c.Name)`0$($c.Key)" })
    foreach ($r in $roots) { [void](& $sumTeam $r) }

    if ($loop.Count) {
        $loopRows = @($Result.Rows | Where-Object { $_.State -eq 'Charged' -and $loop.Contains($(if ($_.ManagerId) { "id:$($_.ManagerId)" } else { "text:$($_.ManagerName)" })) })
        Add-Issue $Result Warning ManagerLoop "Manager chain loops through $($loop.Count) people. They keep their own statements but are left out of roll-ups." -Rows @($loopRows | ForEach-Object RowNumber) -Detail ((@($loop) | ForEach-Object { & $display $_ }) -join '; ')
    }
    $Result.OrgTree = [pscustomobject]@{ Nodes = $nodes; Roots = $roots; Loop = $loop }
    $Result.OrgTree
}

# Nodes in a subtree, depth first, with their level (0 = the top). Depth 0 = all levels.
function Get-SubtreeNodes {
    param($Node, [int]$Depth = 0, [int]$Level = 0)
    [pscustomobject]@{ Node = $Node; Level = $Level }
    if ($Depth -gt 0 -and $Level -ge $Depth) { return }
    foreach ($c in $Node.Children) { Get-SubtreeNodes $c $Depth ($Level + 1) }
}

# Spec 8 roll-up checks. Stops the run if any fails (it would be a bug).
function Assert-RollupCheck {
    param([Parameter(Mandatory)] $Result)
    $tree = Get-OrgTree $Result
    $direct = [decimal]0
    foreach ($g in Get-ManagerSummary $Result) { $direct += $g.Total }
    if ($direct -ne $Result.Reconciliation.Allocated) { Stop-Divvy 'Internal error: direct charges by manager do not add up to the grand total.' }
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($n in $tree.Nodes.Values) {
        $sub = [decimal]0
        foreach ($s in Get-SubtreeNodes $n) { $sub += $s.Node.DirectTotal }
        if ($sub -ne $n.TeamTotal) { Stop-Divvy "Internal error: roll-up total for one manager does not match its subtree." }
        if ($n.Direct) { foreach ($r in $n.Direct.Rows) { if (-not $seen.Add($r.RowNumber)) { Stop-Divvy 'Internal error: a usage row is under two managers.' } } }
    }
}
