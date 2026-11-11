# Overrides (spec 5.3): load, validate, find each person with Overrides.KeyRules, and attach the
# override to the usage rows it applies to. Row states are set later (Resolve-Mapping).
#
# One override per row. If two overrides hit the same row, neither is applied to it (Conflict).
# Bad overrides (NoHit, MultipleHits, DuplicateKey, Conflict, LinkFailed, BadValue) are skipped and,
# with Policy.BadOverride = 'Draft', force the run to DRAFT. Stale overrides only warn.

# 'Problem' is written by overrides-template.csv as a hint; it is ignored on read.
$script:OverrideColumns = 'Key', 'Manager', 'CostCenter', 'Exclude', 'Include', 'LinkTo', 'SeatFor', 'Reason', 'By', 'Date', 'Problem'

function Import-OverrideFile {
    param([string]$Path, $Result)
    $records = @(Import-Csv -LiteralPath $Path -Encoding utf8)
    $columns = if ($records.Count) { @($records[0].PSObject.Properties.Name) } else { @() }
    $Result.Overrides.Columns = $columns
    if (-not $records.Count) { return @() }
    if ($columns -notcontains 'Key') { Add-Issue $Result Error OverrideInvalid 'The overrides file needs a Key column.'; return @() }
    $unknown = @($columns | Where-Object { $script:OverrideColumns -notcontains $_ })
    if ($unknown.Count) { Add-Issue $Result Warning OverrideColumns "The overrides file has columns DivvyOut does not use: $($unknown -join ', ')." }

    $flag = { param([string]$v) if ($v -match '^(y|yes|true|1)$') { $true } elseif ($v -match '^(n|no|false|0)?$') { $false } else { $null } }
    $n = 1
    foreach ($rec in $records) {
        $n++
        $get = { param($c) if ($columns -contains $c) { ([string]$rec.$c).Trim() } else { '' } }
        $item = [pscustomobject]@{
            RowNumber = $n; Key = & $get 'Key'; Manager = & $get 'Manager'; CostCenter = & $get 'CostCenter'
            ExcludeText = & $get 'Exclude'; IncludeText = & $get 'Include'; LinkTo = & $get 'LinkTo'; SeatForText = & $get 'SeatFor'; SeatFor = @()
            Reason = & $get 'Reason'; By = & $get 'By'; Date = & $get 'Date'
            Exclude = $false; Include = $false
            Status = 'OK'; TargetKind = $null; TargetRows = @(); TargetUser = $null; KeyRule = $null
            LinkUser = $null; ManagerUser = $null; AppliedRows = 0
        }
        $item.Exclude = & $flag $item.ExcludeText
        $item.Include = & $flag $item.IncludeText
        $item
    }
}

# Finds a person with the key rules, in order; the first single hit wins.
# Usage-field rules find usage rows; directory rules find one directory user.
function Find-OverridePerson {
    param([string]$Value, [object[]]$Rules, [object[]]$Indexes, [switch]$DirectoryOnly)
    $multiple = $false
    for ($i = 0; $i -lt $Rules.Count; $i++) {
        $rule = $Rules[$i]
        if ($DirectoryOnly -and -not $rule.AdAttribute) { continue }
        $key = ConvertTo-NormalizedValue $Value $rule.Normalize
        if (-not $key) { continue }
        $list = $null
        if (-not $Indexes[$i].TryGetValue($key, [ref]$list)) { continue }
        if ($rule.UsageField) { return @{ Kind = 'Usage'; Rows = @($list); User = $null; Rule = $rule.Number } }
        if ($list.Count -eq 1) { return @{ Kind = 'User'; Rows = @(); User = $list[0]; Rule = $rule.Number } }
        $multiple = $true
    }
    @{ Kind = $null; Multiple = $multiple }
}

function Resolve-Override {
    param([Parameter(Mandatory)] $Result)
    if (-not $Result.Inputs.Contains('Overrides') -or -not $Result.Inputs.Overrides.Path) { return }
    $items = @(Import-OverrideFile $Result.Inputs.Overrides.Path $Result)
    $Result.Overrides.Items = $items
    if (-not $items.Count -or (Get-IssueCount $Result Error)) { return }
    $cfg = $Result.Config
    $draft = $cfg.Policy.BadOverride -eq 'Draft'
    $flagBad = { param([object[]]$bad, [string]$code, [string]$msg)
        if (-not $bad.Count) { return }
        foreach ($b in $bad) { $b.Status = $code }
        Add-Issue $Result Warning $code "$($bad.Count) override rows: $msg Skipped." -Rows @($bad | ForEach-Object RowNumber) -Detail (($bad | ForEach-Object Key) -join '; ')
        if ($draft) { $Result.DraftReasons.Add("$($bad.Count) override rows could not be applied ($code)") }
    }

    # Blank keys and bad Y/N values.
    $blank = @($items | Where-Object { -not $_.Key })
    if ($blank.Count) { & $flagBad $blank 'OverrideBlankKey' 'Key is blank.' }
    & $flagBad @($items | Where-Object { $_.Status -eq 'OK' -and ($null -eq $_.Exclude -or $null -eq $_.Include) }) 'OverrideBadValue' 'Exclude/Include must be Y or blank.'

    # SeatFor: offering names (';' between several), after Usage.OfferingAliases, that the quote prices as seats (D85).
    $aliases = $cfg.Usage.OfferingAliases
    $badSeatFor = @(foreach ($o in $items | Where-Object { $_.Status -eq 'OK' -and $_.SeatForText }) {
            $ok = $true
            $o.SeatFor = @(foreach ($n in $o.SeatForText.Split(';') | ForEach-Object Trim | Where-Object { $_ }) {
                    $a = if ($aliases.ContainsKey($n)) { $aliases[$n] } else { $n }
                    $canon = $null
                    if ($Result.Quote.OfferingNames.TryGetValue($a, [ref]$canon)) { $canon } else { $ok = $false }
                })
            if (-not $ok) { $o }
        })
    & $flagBad $badSeatFor 'OverrideBadValue' 'SeatFor names an offering with no seat price in the quote.'

    # Same key text twice.
    $groups = @($items | Where-Object Status -eq 'OK' | Group-Object { $_.Key.ToLowerInvariant() } | Where-Object Count -gt 1)
    & $flagBad @($groups | ForEach-Object Group) 'OverrideDuplicateKey' 'the same Key appears more than once.'

    # Indexes, one per key rule.
    $keyRules = $cfg.Overrides.KeyRules
    $indexes = [System.Collections.Generic.List[object]]::new()
    foreach ($rule in $keyRules) {
        if ($rule.AdAttribute) { $indexes.Add((New-DirectoryIndex $Result.Directory.Users $rule.AdAttribute $rule.Normalize '')); continue }
        $idx = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new([StringComparer]::Ordinal)
        foreach ($row in $Result.Rows) {
            $k = ConvertTo-NormalizedValue ([string]$row.Fields[$rule.UsageField]) $rule.Normalize
            if (-not $k) { continue }
            if (-not $idx.ContainsKey($k)) { $idx[$k] = [System.Collections.Generic.List[object]]::new() }
            $idx[$k].Add($row)
        }
        $indexes.Add($idx)
    }

    # Find each person, the LinkTo user, and the manager.
    $noHit = @(); $multi = @(); $linkFail = @(); $linkNeedsUsage = @()
    $mgrIdx = if ($cfg.Overrides.ManagerLookup) { New-DirectoryIndex $Result.Directory.Users $cfg.Overrides.ManagerLookup.AdAttribute $cfg.Overrides.ManagerLookup.Normalize '' }
    $mgrText = @()
    foreach ($o in $items | Where-Object Status -eq 'OK') {
        $hit = Find-OverridePerson $o.Key $keyRules $indexes
        if (-not $hit.Kind) { if ($hit.Multiple) { $multi += $o } else { $noHit += $o }; continue }
        $o.TargetKind = $hit.Kind; $o.TargetRows = $hit.Rows; $o.TargetUser = $hit.User; $o.KeyRule = $hit.Rule
        # A usage key whose rows all matched one directory user means that person: all of their rows,
        # including rows under an alias or a username (DECISIONS D78). LinkTo keeps it row by row.
        if ($hit.Kind -eq 'Usage' -and -not $o.LinkTo) {
            $ids = @($hit.Rows | ForEach-Object { if ($_.User) { $_.User.Id } else { '' } } | Select-Object -Unique)
            if ($ids.Count -eq 1 -and $ids[0]) { $o.TargetKind = 'User'; $o.TargetUser = $hit.Rows[0].User }
        }
        if ($o.LinkTo) {
            if ($hit.Kind -ne 'Usage') { $linkNeedsUsage += $o; continue }
            $link = Find-OverridePerson $o.LinkTo $keyRules $indexes -DirectoryOnly
            if ($link.Kind -ne 'User') { $linkFail += $o; continue }
            $o.LinkUser = $link.User
        }
        if ($o.Manager) {
            $key = ConvertTo-NormalizedValue $o.Manager $cfg.Overrides.ManagerLookup.Normalize
            $list = $null
            $found = @(if ($key -and $mgrIdx.TryGetValue($key, [ref]$list)) { $list })
            if ($found.Count -gt 1 -and $cfg.Match.PreferEnabled) { $live = @($found | Where-Object Enabled); if ($live.Count) { $found = $live } }
            if ($found.Count -eq 1) { $o.ManagerUser = $found[0] } else { $mgrText += $o }
        }
    }
    & $flagBad $noHit 'OverrideNoHit' 'Key finds nobody (no usage row, no directory user).'
    & $flagBad $multi 'OverrideMultipleHits' 'Key finds more than one directory user.'
    & $flagBad $linkFail 'OverrideLinkFailed' 'LinkTo finds no single directory user.'
    & $flagBad $linkNeedsUsage 'OverrideLinkFailed' 'LinkTo needs a Key that finds usage rows (a usage-field key rule).'
    $mgrText = @($mgrText | Where-Object Status -eq 'OK')
    if ($mgrText.Count) {
        Add-Issue $Result Warning OverrideManagerText "$($mgrText.Count) override rows: Manager not found in the directory. The text is used as given." -Rows @($mgrText | ForEach-Object RowNumber) -Detail (($mgrText | ForEach-Object Manager) -join '; ')
    }
    $mgrOff = @($items | Where-Object { $_.Status -eq 'OK' -and $_.ManagerUser -and -not $_.ManagerUser.Enabled })
    if ($mgrOff.Count) { Add-Issue $Result Warning OverrideManagerDisabled "$($mgrOff.Count) override rows set a manager who is disabled in the directory. Used anyway." -Rows @($mgrOff | ForEach-Object RowNumber) }

    # Two directory-key overrides for the same user.
    $sameUser = @($items | Where-Object { $_.Status -eq 'OK' -and $_.TargetUser } | Group-Object { $_.TargetUser.Id } | Where-Object Count -gt 1)
    & $flagBad @($sameUser | ForEach-Object Group) 'OverrideDuplicateKey' 'more than one override finds the same directory user.'

    # Which overrides apply to each row: usage-key overrides by row; directory-key overrides by the row's user
    # (after any LinkTo from a usage-key override).
    $ok = @($items | Where-Object Status -eq 'OK')
    $byRow = @{}
    foreach ($o in $ok | Where-Object TargetKind -eq 'Usage') {
        foreach ($r in $o.TargetRows) {
            if (-not $byRow.ContainsKey($r.RowNumber)) { $byRow[$r.RowNumber] = [System.Collections.Generic.List[object]]::new() }
            $byRow[$r.RowNumber].Add($o)
        }
    }
    $byUser = @{}
    foreach ($o in $ok | Where-Object TargetKind -eq 'User') { $byUser[$o.TargetUser.Id] = $o }
    # One override acts on a row. Exception: a LinkTo line that only links can be followed by the linked
    # person's own override (link first, then that person's Manager / CostCenter / Exclude / Include).
    $hasAction = { param($o) [bool]($o.Manager -or $o.CostCenter -or $o.Exclude -or $o.Include -or $o.SeatFor.Count) }
    $conflict = [System.Collections.Generic.HashSet[object]]::new()
    $apply = @{}
    foreach ($row in $Result.Rows) {
        $own = @(if ($byRow.ContainsKey($row.RowNumber)) { $byRow[$row.RowNumber] })
        if ($own.Count -gt 1) { foreach ($o in $own) { [void]$conflict.Add($o) }; continue }
        $who = if ($own.Count -and $own[0].LinkUser) { $own[0].LinkUser } else { $row.User }
        $person = if ($who -and $byUser.ContainsKey($who.Id)) { $byUser[$who.Id] } else { $null }
        if ($own.Count -and $person) {
            if ($own[0].LinkUser -and -not (& $hasAction $own[0])) { $apply[$row.RowNumber] = @{ Link = $own[0]; Act = $person } }
            else { [void]$conflict.Add($own[0]); [void]$conflict.Add($person) }
        }
        elseif ($own.Count) { $apply[$row.RowNumber] = @{ Link = $(if ($own[0].LinkUser) { $own[0] }); Act = $own[0] } }
        elseif ($person) { $apply[$row.RowNumber] = @{ Link = $null; Act = $person } }
    }
    & $flagBad @($conflict) 'OverrideConflict' 'more than one override applies to the same usage row.'

    foreach ($row in $Result.Rows) {
        $a = $apply[$row.RowNumber]
        if (-not $a -or $a.Act.Status -ne 'OK' -or ($a.Link -and $a.Link.Status -ne 'OK')) { continue }
        if ($a.Link) {
            $l = $a.Link
            $row.User = $l.LinkUser
            $row.MatchStatus = if ($l.LinkUser.Enabled) { 'Linked' } else { 'Disabled' }
            $row.MatchRule = $null
            $row.Candidates = @($l.LinkUser.Id)
            $row.MatchValue = $l.LinkTo
            $row.MatchDirValue = $null
            $row.LinkOverride = $l
            $l.AppliedRows++
        }
        $row.Override = $a.Act
        if ($a.Act -ne $a.Link) { $a.Act.AppliedRows++ }
    }

    # Overrides that touch no usage row: a manager fix for the org tree is fine; anything else is stale.
    $stale = @($ok | Where-Object { $_.Status -eq 'OK' -and $_.AppliedRows -eq 0 -and -not ($_.TargetUser -and $_.Manager) })
    if ($stale.Count) {
        foreach ($o in $stale) { $o.Status = 'Stale' }
        Add-Issue $Result Warning OverrideStale "$($stale.Count) override rows match no usage row (stale)." -Rows @($stale | ForEach-Object RowNumber) -Detail (($stale | ForEach-Object Key) -join '; ')
    }
    $tree = @($ok | Where-Object { $_.Status -eq 'OK' -and $_.AppliedRows -eq 0 })
    foreach ($o in $tree) { $o.Status = 'TreeOnly' }
    $applied = @($items | Where-Object AppliedRows -gt 0)
    Add-Issue $Result Info OverridesApplied "$($applied.Count) of $($items.Count) override rows applied to $(@($Result.Rows | Where-Object Override).Count) usage rows; $($tree.Count) set a manager for the org tree only."
}
