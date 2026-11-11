# Reads the directory snapshot CSV, checks the columns the profile names, checks ID uniqueness,
# and builds lookup indexes (normalized value -> users).

function Import-AdSnapshot {
    param([Parameter(Mandatory)] [string]$Path, [Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Result)
    $ad = $Config.Ad
    try { $records = @(Import-Csv -LiteralPath $Path -Encoding utf8) }
    catch {
        $msg = $_.Exception.Message.Replace($Path, '<directory file>')
        Add-Issue $Result Error DirectoryUnreadable "Could not read the directory snapshot ($($_.Exception.GetType().Name)): $msg"
        return
    }
    $columns = if ($records.Count) { @($records[0].PSObject.Properties.Name) } else { @() }
    $Result.Directory.Columns = $columns
    $Result.Directory.RowCount = $records.Count
    if ($records.Count -eq 0) { Add-Issue $Result Error DirectoryEmpty 'The directory snapshot has no rows.'; return }

    # Every attribute the profile names -> which profile keys use it.
    $need = [ordered]@{}
    $add = { param([string]$attr, [string]$key) if ($attr) { if (-not $need.Contains($attr)) { $need[$attr] = @() }; $need[$attr] += $key } }
    foreach ($k in 'IdAttribute', 'EnabledColumn', 'ManagerAttribute', 'ManagerKeyAttribute', 'DisplayAttribute') { & $add $ad[$k] "Ad.$k" }
    if ($ad.CostCenter) { & $add $ad.CostCenter.Attribute 'Ad.CostCenter.Attribute' }
    foreach ($mi in $ad.ManagerInfo) { & $add $mi.Attribute 'Ad.ManagerInfo' }
    foreach ($a in $ad.Attributes) { & $add $a 'Ad.Attributes' }
    foreach ($r in $Config.Match.Rules) { & $add $r.AdAttribute "Match.Rules[$($r.Number)].AdAttribute" }
    foreach ($r in $Config.Overrides.KeyRules) { & $add $r.AdAttribute "Overrides.KeyRules[$($r.Number)].AdAttribute" }
    if ($Config.Overrides.ManagerLookup) { & $add $Config.Overrides.ManagerLookup.AdAttribute 'Overrides.ManagerLookup.AdAttribute' }
    foreach ($attr in $need.Keys) {
        if ($columns -notcontains $attr) {
            Add-Issue $Result Error MissingDirectoryColumn "Directory attribute '$attr' (used by $($need[$attr] -join ', ')) is not a column in the directory snapshot."
        }
    }
    if (Get-IssueCount $Result Error) { return }

    $users = [System.Collections.Generic.List[object]]::new()
    $byId = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $blank = [System.Collections.Generic.List[int]]::new()
    $dupRows = [System.Collections.Generic.List[int]]::new()
    $dupIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $n = 1
    foreach ($rec in $records) {
        $n++
        $id = ([string]$rec.($ad.IdAttribute)).Trim()
        $user = [pscustomobject]@{
            Id        = $id
            Enabled   = ([string]$rec.($ad.EnabledColumn)).Trim() -eq $ad.EnabledValue
            Display   = ([string]$rec.($ad.DisplayAttribute)).Trim()
            Record    = $rec
            RowNumber = $n
        }
        if (-not $id) { $blank.Add($n); continue }
        if ($byId.ContainsKey($id)) { [void]$dupIds.Add($id); $dupRows.Add($n); continue }
        $byId[$id] = $user
        $users.Add($user)
    }
    if ($blank.Count) { Add-Issue $Result Error BlankId "$($blank.Count) directory rows have a blank '$($ad.IdAttribute)' (Ad.IdAttribute)." -Rows $blank.ToArray() }
    if ($dupIds.Count) {
        Add-Issue $Result Error DuplicateId "'$($ad.IdAttribute)' (Ad.IdAttribute) has $($dupIds.Count) repeated values ($($dupRows.Count) extra rows). Each user needs a unique ID." -Rows $dupRows.ToArray()
    }
    $Result.Directory.Users = $users.ToArray()
    $Result.Directory.ById = $byId
}

# Index for one attribute: normalized value -> list of users. Built once per rule (spec NFR-6).
# Split: the attribute holds several values joined by this text (for example ';').
function New-DirectoryIndex {
    param([object[]]$Users, [string]$Attribute, [object[]]$Normalize, [string]$Split)
    $idx = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new([StringComparer]::Ordinal)
    foreach ($u in $Users) {
        $raw = [string]$u.Record.$Attribute
        $values = if ($Split) { $raw.Split($Split) } else { @($raw) }
        foreach ($v in $values) {
            $key = ConvertTo-NormalizedValue $v $Normalize
            if (-not $key) { continue }
            if (-not $idx.ContainsKey($key)) { $idx[$key] = [System.Collections.Generic.List[object]]::new() }
            if (-not $idx[$key].Contains($u)) { $idx[$key].Add($u) }
        }
    }
    , $idx
}
