# Row states (spec 7.1), charge owner (spec 8), and cost center.
#   NotHere    : Excluded, NoMatch, Disabled (Duplicate with Policy.DuplicateSeatRows = 'ChargeOnce'). Not charged, not in any divisor.
#   NeedsOwner : AmbiguousMatch, NoManager, ManagerNotFound, ManagerDisabled. Charged, no statement owner, blocks FINAL.
#   Charged    : present, with an owner.

# The single place that decides who a row's charge goes to (spec 8: 'Resolve-ChargeOwner').
# Returns @{ Id; Name; Source; Problem }. Problem is $null, 'NoManager', 'ManagerNotFound', or 'ManagerDisabled'.
function Resolve-ChargeOwner {
    param([Parameter(Mandatory)] $Row, [Parameter(Mandatory)] $Result)
    switch ($Result.Config.Charge.Owner) {
        'DirectManager' {
            $o = $Row.Override
            if ($o -and $o.Manager) {
                if ($o.ManagerUser) { return @{ Id = $o.ManagerUser.Id; Name = $o.ManagerUser.Display; Source = 'Override'; Problem = $null } }
                return @{ Id = $null; Name = $o.Manager; Source = 'Override (not in directory)'; Problem = $null }
            }
            $m = Get-DirectoryManager $Row.User $Result
            if ($m.Problem) { return @{ Id = $null; Name = $null; Source = 'Directory'; Problem = $m.Problem } }
            return @{ Id = $m.User.Id; Name = $m.User.Display; Source = 'Directory'; Problem = $null }
        }
        default { Stop-Divvy "Charge.Owner '$($Result.Config.Charge.Owner)' is not supported." }
    }
}

# The user's manager from the directory: @{ User; Problem }.
function Get-DirectoryManager {
    param($User, $Result)
    $ad = $Result.Config.Ad
    if (-not $Result.Directory.Contains('ManagerIndex') -or -not $Result.Directory.ManagerIndex) {
        # Manager reference -> users. References compare ignoring case and outer spaces (AD DNs ignore case).
        $idx = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($u in $Result.Directory.Users) {
            $k = ([string]$u.Record.($ad.ManagerKeyAttribute)).Trim()
            if (-not $k) { continue }
            if (-not $idx.ContainsKey($k)) { $idx[$k] = [System.Collections.Generic.List[object]]::new() }
            $idx[$k].Add($u)
        }
        $Result.Directory.ManagerIndex = $idx
    }
    $ref = ([string]$User.Record.($ad.ManagerAttribute)).Trim()
    if (-not $ref) { return @{ User = $null; Problem = 'NoManager' } }
    $list = $null
    if (-not $Result.Directory.ManagerIndex.TryGetValue($ref, [ref]$list) -or $list.Count -ne 1) { return @{ User = $null; Problem = 'ManagerNotFound' } }
    if (-not $list[0].Enabled) { return @{ User = $list[0]; Problem = 'ManagerDisabled' } }
    @{ User = $list[0]; Problem = $null }
}

# Sort key used for rounding ties and duplicate handling (DECISIONS D18). Ordinal compare.
function Get-RowSortKey {
    param($Row, $Result)
    $first = [string]$Row.Fields[$Result.Config.Match.Rules[0].UsageField]
    $id = if ($Row.User) { $Row.User.Id } else { '' }
    '{0}|{1}|{2}|{3:D9}' -f $Row.Package, $id, $first.Trim().ToLowerInvariant(), $Row.RowNumber
}

function Resolve-Mapping {
    param([Parameter(Mandatory)] $Result)
    $cc = $Result.Config.Ad.CostCenter
    foreach ($row in $Result.Rows) {
        $o = $row.Override
        $user = $row.User
        if ($o -and $o.Exclude) { $row.State = 'NotHere'; $row.Reason = 'Excluded' }
        elseif ($row.MatchStatus -eq 'NoMatch') { $row.State = 'NotHere'; $row.Reason = 'NoMatch' }
        elseif ($row.MatchStatus -eq 'Ambiguous') { $row.State = 'NeedsOwner'; $row.Reason = 'AmbiguousMatch' }
        elseif (-not $user -or (-not $user.Enabled -and -not ($o -and $o.Include))) { $row.State = 'NotHere'; $row.Reason = 'Disabled' }
        else {
            $owner = Resolve-ChargeOwner -Row $row -Result $Result
            $row.ManagerId = $owner.Id; $row.ManagerName = $owner.Name; $row.ManagerSource = $owner.Source
            if ($owner.Problem) { $row.State = 'NeedsOwner'; $row.Reason = $owner.Problem }
            else { $row.State = 'Charged'; $row.Reason = $null }
        }
        if ($user) {
            $dm = Get-DirectoryManager $user $Result
            if ($dm.User) { $row.ManagerDirId = $dm.User.Id; $row.ManagerDirName = $dm.User.Display }
            if ($cc) {
                $raw = [string]$user.Record.($cc.Attribute)
                $final = $raw
                foreach ($rep in $cc.Replace) { $final = $final.Replace($rep.From, $rep.To) }
                $row.CostCenterRaw = $raw; $row.CostCenter = $final.Trim()
            }
        }
        if ($cc -and $o -and $o.CostCenter) { $row.CostCenter = $o.CostCenter }
    }

    # Same user, same offering: two seat rows (Policy.DuplicateSeatRows), or a seat row and a token row (warn).
    $pool = @($Result.Rows | Where-Object { $_.State -ne 'NotHere' -and $_.User })
    $groups = $pool | Group-Object { "$($_.User.Id)|$($_.Package)" } | Where-Object Count -gt 1
    $dupRows = [System.Collections.Generic.List[int]]::new(); $mixedRows = [System.Collections.Generic.List[int]]::new()
    foreach ($g in $groups) {
        $seats = @(Get-SortedByKey @($g.Group | Where-Object Access -eq 'Seat') { param($r) Get-RowSortKey $r $Result })
        if ($seats.Count -gt 1) {
            foreach ($s in $seats) { $dupRows.Add($s.RowNumber) }
            if ($Result.Config.Policy.DuplicateSeatRows -eq 'ChargeOnce') {
                foreach ($s in $seats | Select-Object -Skip 1) { $s.State = 'NotHere'; $s.Reason = 'Duplicate' }
            }
        }
        if ($seats.Count -and @($g.Group | Where-Object Access -eq 'Token').Count) { foreach ($r in $g.Group) { $mixedRows.Add($r.RowNumber) } }
    }
    if ($dupRows.Count) {
        $how = if ($Result.Config.Policy.DuplicateSeatRows -eq 'ChargeOnce') { 'Only the first is charged.' } else { 'Each row is charged.' }
        Add-Issue $Result Warning DuplicateSeatRows "Same user has 2+ seat rows for one offering. $how" -Rows ([int[]]($dupRows | Sort-Object))
    }
    if ($mixedRows.Count) { Add-Issue $Result Warning MixedAccess 'Same user has a seat row and a token row for one offering. Each row is charged by its own access option.' -Rows ([int[]]($mixedRows | Sort-Object)) }

    $o = @($Result.Rows | Where-Object { $_.Override -and $_.Override.Include -and $_.User -and -not $_.User.Enabled })
    if ($o.Count) { Add-Issue $Result Info IncludedDisabled "$($o.Count) rows of disabled users are charged because of Include = Y." -Rows @($o | ForEach-Object RowNumber) }
    $needs = @($Result.Rows | Where-Object State -eq 'NeedsOwner')
    foreach ($g in $needs | Group-Object Reason | Sort-Object Name) {
        Add-Issue $Result Warning "NeedsOwner$($g.Name)" "$($g.Count) rows need an owner ($($g.Name)). Charged, but on the NO OWNER statement. Blocks FINAL." -Rows @($g.Group | ForEach-Object RowNumber)
    }
}
