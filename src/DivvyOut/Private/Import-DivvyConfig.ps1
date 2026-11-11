# Loads and checks the input profile and the quote. Problems go to $Result.Issues.

function Get-Setting {
    param($Table, [string]$Key, $Default)
    if ($Table -is [System.Collections.IDictionary] -and $Table.Contains($Key) -and $null -ne $Table[$Key]) { return $Table[$Key] }
    $Default
}

# Checks a Normalize list. Items are step names, or @{ Pattern = '...'; Replacement = '...' } for a regex.
function Get-NormalizeSteps {
    param($Steps, [string]$Path, $Result)
    $known = 'Trim', 'ToLower', 'StripDomainPrefix', 'StripUpnSuffix'
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($s in @($Steps | Where-Object { $null -ne $_ })) {
        if ($s -is [System.Collections.IDictionary]) {
            $pattern = Get-Setting $s 'Pattern' ''
            try { [void][regex]::new($pattern) }
            catch { Add-Issue $Result Error ProfileInvalid "Profile $Path has a Regex step with an invalid Pattern."; continue }
            if (-not $pattern) { Add-Issue $Result Error ProfileInvalid "Profile $Path has a Regex step with no Pattern."; continue }
            $out.Add(@{ Pattern = $pattern; Replacement = [string](Get-Setting $s 'Replacement' '') })
        }
        elseif ($known -contains $s) { $out.Add([string]$s) }
        else { Add-Issue $Result Error ProfileInvalid "Profile $Path has unknown Normalize step '$s'. Use: $($known -join ', '), or @{ Pattern = ...; Replacement = ... }." }
    }
    , $out.ToArray()
}

function Import-DivvyProfile {
    param([Parameter(Mandatory)] $Source, [Parameter(Mandatory)] $Result)

    $p = if ($Source -is [System.Collections.IDictionary]) { $Source } else { Import-PowerShellDataFile -LiteralPath $Source }
    $err = { param([string]$msg) Add-Issue $Result Error ProfileInvalid $msg }
    $str = { param($table, [string]$key, [string]$path)
        $v = Get-Setting $table $key $null
        if ($v -isnot [string] -or [string]::IsNullOrWhiteSpace($v)) { & $err "Profile key $path is missing or empty."; return $null }
        $v.Trim()
    }
    $oneOf = { param($table, [string]$key, [string]$path, [string[]]$allowed)
        $v = [string](Get-Setting $table $key $allowed[0])
        if ($allowed -notcontains $v) { & $err "Profile key $path must be one of: $($allowed -join ', '). Found '$v'." }
        $v
    }

    foreach ($section in 'Usage', 'Match', 'Ad', 'Overrides') {
        if ((Get-Setting $p $section $null) -isnot [System.Collections.IDictionary]) { & $err "Profile section $section is missing." }
    }
    if (Get-IssueCount $Result Error) { return $null }

    # Vendor rule
    $vendor = & $str $p 'Vendor' 'Vendor'
    $rule = if ($vendor) { $script:VendorRules[$vendor] } else { $null }
    if ($vendor -and -not $rule) { & $err "Profile Vendor '$vendor' has no rule module. Known vendors: $(($script:VendorRules.Keys | Sort-Object) -join ', ')." }

    # Usage
    $u = $p.Usage
    $columns = [ordered]@{}
    $srcCols = Get-Setting $u 'Columns' $null
    if ($srcCols -isnot [System.Collections.IDictionary] -or $srcCols.Count -eq 0) { & $err 'Profile key Usage.Columns is missing or empty.' }
    else {
        foreach ($k in Get-OrdinalSorted @($srcCols.Keys)) {
            $h = [string]$srcCols[$k]
            if ([string]::IsNullOrWhiteSpace($h)) { & $err "Profile key Usage.Columns.$k is empty." } else { $columns[$k] = $h.Trim() }
        }
    }
    $headerRow = Get-Setting $u 'HeaderRow' 1
    if ($headerRow -isnot [int] -or $headerRow -lt 1) { & $err 'Profile key Usage.HeaderRow must be a whole number, 1 or more.'; $headerRow = 1 }

    $access = [ordered]@{}
    $srcAccess = Get-Setting $u 'AccessOptionValues' $null
    if ($srcAccess -isnot [System.Collections.IDictionary] -or $srcAccess.Count -eq 0) { & $err 'Profile key Usage.AccessOptionValues is missing or empty.' }
    else {
        foreach ($k in Get-OrdinalSorted @($srcAccess.Keys)) {
            if ($rule -and $rule.AccessKinds -notcontains $k) { & $err "Profile key Usage.AccessOptionValues.$k is not an access kind of vendor '$vendor'. Use: $($rule.AccessKinds -join ', ')." }
            $t = [string]$srcAccess[$k]
            if ([string]::IsNullOrWhiteSpace($t)) { & $err "Profile key Usage.AccessOptionValues.$k is empty." }
            elseif (@($access.Values) -contains $t.Trim()) { & $err "Profile key Usage.AccessOptionValues uses the text '$t' twice." }
            else { $access[$k] = $t.Trim() }
        }
    }

    $aliases = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    $srcAliases = Get-Setting $u 'OfferingAliases' @{}
    foreach ($k in $srcAliases.Keys) { $aliases[([string]$k).Trim()] = ([string]$srcAliases[$k]).Trim() }

    # Match rules
    $m = $p.Match
    $matchRules = [System.Collections.Generic.List[object]]::new()
    $i = 0
    foreach ($r in @(Get-Setting $m 'Rules' @())) {
        $i++
        $path = "Match.Rules[$i]"
        if ($r -isnot [System.Collections.IDictionary]) { & $err "Profile $path is not a @{ } table."; continue }
        $matchRules.Add([pscustomobject]@{
                Number      = $i
                UsageField  = & $str $r 'UsageField' "$path.UsageField"
                AdAttribute = & $str $r 'AdAttribute' "$path.AdAttribute"
                Normalize   = Get-NormalizeSteps (Get-Setting $r 'Normalize' @()) "$path.Normalize" $Result
                Split       = [string](Get-Setting $r 'Split' '')
            })
    }
    if ($matchRules.Count -eq 0) { & $err 'Profile key Match.Rules needs at least one rule.' }
    $preferEnabled = Get-Setting $m 'PreferEnabled' $true
    if ($preferEnabled -isnot [bool]) { & $err 'Profile key Match.PreferEnabled must be $true or $false.' }

    # Directory
    $a = $p.Ad
    $ad = [ordered]@{
        IdAttribute         = & $str $a 'IdAttribute' 'Ad.IdAttribute'
        EnabledColumn       = & $str $a 'EnabledColumn' 'Ad.EnabledColumn'
        EnabledValue        = & $str $a 'EnabledValue' 'Ad.EnabledValue'
        ManagerAttribute    = & $str $a 'ManagerAttribute' 'Ad.ManagerAttribute'
        ManagerKeyAttribute = & $str $a 'ManagerKeyAttribute' 'Ad.ManagerKeyAttribute'
        DisplayAttribute    = & $str $a 'DisplayAttribute' 'Ad.DisplayAttribute'
        Attributes          = @(Get-Setting $a 'Attributes' @() | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
        ManagerColumns      = @(Get-Setting $a 'ManagerColumns' @() | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
        CostCenter          = $null
        ManagerInfo         = @()
    }
    # Extra manager columns for the summary, statements, roll-ups and dashboard (DECISIONS D83). An array keeps the order.
    $labels = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($col in 'Status', 'Manager', 'ManagerId', 'People', 'Rows', 'SeatTotal', 'TokenTotal', 'Total') { [void]$labels.Add($col) }
    $ad.ManagerInfo = @(foreach ($mi in @(Get-Setting $a 'ManagerInfo' @())) {
            if ($mi -isnot [System.Collections.IDictionary]) { & $err 'Profile key Ad.ManagerInfo items must be @{ Label = ...; Attribute = ... }.'; continue }
            $label = & $str $mi 'Label' 'Ad.ManagerInfo.Label'
            $attr = & $str $mi 'Attribute' 'Ad.ManagerInfo.Attribute'
            if (-not $label -or -not $attr) { continue }
            if (-not $labels.Add($label.Trim())) { & $err "Profile key Ad.ManagerInfo: label '$($label.Trim())' is used twice or clashes with a summary column."; continue }
            @{ Label = $label.Trim(); Attribute = $attr.Trim() }
        })
    $cc = Get-Setting $a 'CostCenter' $null
    if ($null -ne $cc) {
        if ($cc -isnot [System.Collections.IDictionary]) { & $err 'Profile key Ad.CostCenter must be a @{ } table.' }
        else {
            $replace = foreach ($rep in @(Get-Setting $cc 'Replace' @())) {
                if ($rep -isnot [System.Collections.IDictionary] -or [string]::IsNullOrEmpty([string](Get-Setting $rep 'From' ''))) { & $err 'Profile key Ad.CostCenter.Replace items need From (and To).'; continue }
                @{ From = [string]$rep.From; To = [string](Get-Setting $rep 'To' '') }
            }
            $ad.CostCenter = @{ Attribute = & $str $cc 'Attribute' 'Ad.CostCenter.Attribute'; Replace = @($replace) }
        }
    }

    # Overrides
    $o = $p.Overrides
    $keyRules = [System.Collections.Generic.List[object]]::new()
    $i = 0
    foreach ($r in @(Get-Setting $o 'KeyRules' @())) {
        $i++
        $path = "Overrides.KeyRules[$i]"
        if ($r -isnot [System.Collections.IDictionary]) { & $err "Profile $path is not a @{ } table."; continue }
        $uf = [string](Get-Setting $r 'UsageField' ''); $aa = [string](Get-Setting $r 'AdAttribute' '')
        if ([bool]$uf -eq [bool]$aa) { & $err "Profile $path needs exactly one of UsageField or AdAttribute."; continue }
        $keyRules.Add([pscustomobject]@{
                Number = $i; UsageField = $uf.Trim(); AdAttribute = $aa.Trim()
                Normalize = Get-NormalizeSteps (Get-Setting $r 'Normalize' @()) "$path.Normalize" $Result
            })
    }
    if ($keyRules.Count -eq 0) { & $err 'Profile key Overrides.KeyRules needs at least one rule.' }
    $ml = Get-Setting $o 'ManagerLookup' $null
    $managerLookup = $null
    if ($ml -isnot [System.Collections.IDictionary]) { & $err 'Profile key Overrides.ManagerLookup is missing.' }
    else {
        $managerLookup = [pscustomobject]@{
            AdAttribute = & $str $ml 'AdAttribute' 'Overrides.ManagerLookup.AdAttribute'
            Normalize   = Get-NormalizeSteps (Get-Setting $ml 'Normalize' @()) 'Overrides.ManagerLookup.Normalize' $Result
        }
    }

    # Every canonical field the rule, the match rules, and the key rules read must be mapped.
    $needed = @(if ($rule) { $rule.RequiredFields }) + @($matchRules | ForEach-Object UsageField) + @($keyRules | ForEach-Object UsageField)
    foreach ($f in $needed | Where-Object { $_ } | Sort-Object -Unique) {
        if (-not $columns.Contains($f)) { & $err "Canonical field '$f' is used but not mapped in Usage.Columns." }
    }

    $charge = Get-Setting $p 'Charge' @{}
    $policy = Get-Setting $p 'Policy' @{}
    $rollup = Get-Setting $p 'Rollup' @{}
    [ordered]@{
        Vendor    = $vendor
        Rule      = $rule
        Usage     = [ordered]@{
            HeaderRow = $headerRow; Encoding = [string](Get-Setting $u 'Encoding' 'utf8'); Sheet = [string](Get-Setting $u 'Sheet' '')
            Columns = $columns; AccessOptionValues = $access; OfferingAliases = $aliases
        }
        Match     = [ordered]@{
            PreferEnabled   = [bool]$preferEnabled
            DisabledSoloHit = & $oneOf $m 'DisabledSoloHit' 'Match.DisabledSoloHit' 'TryNextRule', 'Stop'
            Rules           = $matchRules.ToArray()
        }
        Ad        = $ad
        Charge    = [ordered]@{ Owner = & $oneOf $charge 'Owner' 'Charge.Owner' 'DirectManager' }
        Policy    = [ordered]@{
            UnusedQuoteOffering = & $oneOf $policy 'UnusedQuoteOffering' 'Policy.UnusedQuoteOffering' 'Stop', 'Ignore'
            DuplicateSeatRows   = & $oneOf $policy 'DuplicateSeatRows' 'Policy.DuplicateSeatRows' 'ChargeEach', 'ChargeOnce'
            BadOverride         = & $oneOf $policy 'BadOverride' 'Policy.BadOverride' 'Draft', 'Warn'
        }
        Rollup    = [ordered]@{
            Enabled = [bool](Get-Setting $rollup 'Enabled' $true); Depth = [int](Get-Setting $rollup 'Depth' 0); MaxTabs = [int](Get-Setting $rollup 'MaxTabs' 50)
        }
        Overrides = [ordered]@{ KeyRules = $keyRules.ToArray(); ManagerLookup = $managerLookup }
    }
}

function Import-DivvyQuote {
    param([Parameter(Mandatory)] $Source, [Parameter(Mandatory)] $Result)
    $q = if ($Source -is [System.Collections.IDictionary]) { $Source } else { Import-PowerShellDataFile -LiteralPath $Source }
    $err = { param([string]$msg) Add-Issue $Result Error QuoteInvalid $msg }
    $moneyHint = "Use a whole number, a quoted string like '12000.50', or 12000.50d. At most 2 decimals."

    $currency = [string](Get-Setting $q 'Currency' '')
    if ($currency.Trim() -ne 'USD') { & $err "Quote Currency must be USD. Found '$currency'." }

    # Offering name -> price. Lookup ignores case. The quote's spelling is the canonical name.
    $prices = [System.Collections.Generic.Dictionary[string, decimal]]::new([StringComparer]::OrdinalIgnoreCase)
    $names = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    $seat = Get-Setting $q 'SeatPrices' $null
    if ($seat -isnot [System.Collections.IDictionary]) { & $err 'Quote SeatPrices is missing.' }
    else {
        foreach ($k in Get-OrdinalSorted @($seat.Keys)) {
            $name = ([string]$k).Trim()
            $d = ConvertTo-Money $seat[$k]
            if ($null -eq $d) { & $err "Quote SeatPrices['$name'] is not a valid amount. $moneyHint"; continue }
            if ($prices.ContainsKey($name)) { & $err "Quote SeatPrices lists '$name' twice (names ignore case)."; continue }
            $prices[$name] = $d; $names[$name] = $name
        }
    }
    $token = $null
    if ($q.Contains('TokenPoolPrice')) {
        $token = ConvertTo-Money $q.TokenPoolPrice
        if ($null -eq $token) { & $err "Quote TokenPoolPrice is not a valid amount. $moneyHint" }
    }
    [ordered]@{
        Period         = [string](Get-Setting $q 'Period' '')
        Currency       = $currency.Trim()
        SeatPrices     = $prices
        OfferingNames  = $names
        TokenPoolPrice = $token
    }
}
