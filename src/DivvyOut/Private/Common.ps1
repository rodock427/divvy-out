# Small helpers shared by the core.

# Full path from a PowerShell path. .NET file methods resolve relative paths against the process
# directory, which does not follow Set-Location, so every path given to .NET goes through this.
function Get-FullPath { param([string]$Path) $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }

# Records a problem. Message must be safe to share (names of columns, counts, row numbers).
# Detail may hold values (emails, names) and goes only to owner-only reports.
function Add-Issue {
    param(
        [Parameter(Mandatory)] $Result,
        [Parameter(Mandatory)][ValidateSet('Error', 'Warning', 'Info')] [string]$Level,
        [Parameter(Mandatory)] [string]$Code,
        [Parameter(Mandatory)] [string]$Message,
        [int[]]$Rows = @(),
        [string]$Detail = ''
    )
    # Which file the row numbers point into.
    $source = if ($Code -like 'Override*') { 'overrides' } elseif ($Code -in 'BlankId', 'DuplicateId') { 'directory' } else { 'usage' }
    $Result.Issues.Add([pscustomobject]@{ Level = $Level; Code = $Code; Message = $Message; Rows = $Rows; Detail = $Detail; Source = $source })
}

function Get-IssueCount { param($Result, [string]$Level) @($Result.Issues | Where-Object Level -eq $Level).Count }

# Stops the run with a message that is safe to show in diagnostics.
function Stop-Divvy {
    param([string]$Message)
    $ex = [System.InvalidOperationException]::new($Message)
    $ex.Data['DivvyStop'] = $true
    throw $ex
}

# Quantity (tokens): digits with an optional decimal part. Returns [decimal], or $null if blank or invalid.
function ConvertTo-Quantity {
    param($Value)
    $s = ([string]$Value).Trim()
    if ($s -notmatch '^\d{1,15}(\.\d+)?$') { return $null }
    [decimal]::Parse($s, [cultureinfo]::InvariantCulture)
}

# Money from config: int/long/decimal, or a string like '12000.50'. Max 2 decimals, not negative.
# A double (bare 12000.50 in a .psd1) is rejected. Returns $null when invalid.
function ConvertTo-Money {
    param($Value)
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [decimal]) { $d = [decimal]$Value }
    elseif ($Value -is [string] -and $Value.Trim() -match '^\d{1,15}(\.\d{1,2})?$') { $d = [decimal]::Parse($Value.Trim(), [cultureinfo]::InvariantCulture) }
    else { return $null }
    if ($d -lt 0 -or $d -ne [decimal]::Round($d, 2)) { return $null }
    $d
}

# Shape of a value with the content hidden: a***@b***.com (len 22). For diagnostics only.
function Get-MaskedShape {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '(blank)' }
    $v = $Value.Trim()
    $at = $v.LastIndexOf('@')
    if ($at -gt 0 -and $at -lt $v.Length - 1) {
        $domain = $v.Substring($at + 1)
        $dot = $domain.LastIndexOf('.')
        $tld = if ($dot -gt 0) { $domain.Substring($dot) } else { '' }
        $shape = '{0}***@{1}***{2}' -f $v[0], $domain[0], $tld
    }
    elseif ($v.Contains('\')) { $shape = '{0}***\***' -f $v[0] }
    else { $shape = '{0}***' -f $v[0] }
    '{0} (len {1})' -f $shape, $v.Length
}

# Ordinal sort of strings. Culture-independent, so every machine gives the same order.
function Get-OrdinalSorted {
    param([string[]]$Values)
    if (-not $Values) { return }
    $a = [string[]]$Values.Clone()
    [Array]::Sort($a, [StringComparer]::Ordinal)
    $a
}

function Format-RowList {
    param([int[]]$Rows, [int]$Max = 50)
    if (-not $Rows) { return '' }
    $shown = ($Rows | Select-Object -First $Max) -join ', '
    if ($Rows.Count -gt $Max) { $shown += " ... (+$($Rows.Count - $Max) more)" }
    $shown
}

# Stops the run if any Error issue was recorded. The message lists the (safe) error texts.
function Assert-NoError {
    param($Result, [string]$What)
    $errors = @($Result.Issues | Where-Object Level -eq 'Error')
    if (-not $errors.Count) { return }
    $lines = $errors | ForEach-Object { " - [$($_.Code)] $($_.Message)" + $(if ($_.Rows.Count) { " Rows: $(Format-RowList $_.Rows 10)" } else { '' }) }
    Stop-Divvy ("$What with $($errors.Count) error(s):`n" + ($lines -join "`n"))
}

# Items sorted by a string key, ordinal (culture-independent). $Key is a scriptblock: param($item) -> string.
function Get-SortedByKey {
    param([object[]]$Items, [scriptblock]$Key)
    if (-not $Items -or $Items.Count -lt 2) { return $Items }
    $keys = [string[]]@(foreach ($i in $Items) { & $Key $i })
    $arr = [object[]]$Items.Clone()
    # Cast to [Array]/IComparer: otherwise PowerShell binds the generic overload and sorts a copy of $arr.
    [Array]::Sort([Array]$keys, [Array]$arr, [System.Collections.IComparer][StringComparer]::Ordinal)
    $arr
}

function Format-Money { param([decimal]$Value) $Value.ToString('0.00', [cultureinfo]::InvariantCulture) }

# Writes a CSV: UTF-8 with BOM (NFR-7), every cell quoted, header even when there are no rows.
# Text that starts with = + - @ (or tab/CR) gets a leading ' so Excel shows it as text (NFR-8).
# Rows are dictionaries keyed by column name. Decimals are written in invariant culture.
function Export-DivvyCsv {
    param([Parameter(Mandatory)] [string]$Path, [Parameter(Mandatory)] [string[]]$Columns, [object[]]$Rows = @())
    # Plain loops, no script block per cell: the audit file has over a million cells at work scale.
    $inv = [cultureinfo]::InvariantCulture
    $sb = [System.Text.StringBuilder]::new()
    $lines = [System.Collections.Generic.List[object]]::new()
    $header = [ordered]@{}; foreach ($c in $Columns) { $header[$c] = $c }
    $lines.Add($header)
    foreach ($r in $Rows) { $lines.Add($r) }
    foreach ($r in $lines) {
        $firstCell = $true
        foreach ($c in $Columns) {
            $v = $r[$c]
            $s = if ($null -eq $v) { '' } elseif ($v -is [decimal]) { $v.ToString($inv) } else { [string]$v }
            if ($s.Length -and '=+-@'.IndexOf($s[0]) -ge 0 -or $s.StartsWith("`t") -or $s.StartsWith("`r")) { $s = "'" + $s }
            if (-not $firstCell) { [void]$sb.Append(',') }
            [void]$sb.Append('"').Append($s.Replace('"', '""')).Append('"')
            $firstCell = $false
        }
        [void]$sb.Append([Environment]::NewLine)
    }
    [IO.File]::WriteAllText((Get-FullPath $Path), $sb.ToString(), [Text.UTF8Encoding]::new($true))
}

# Usage fields that identify a person (the match rules' usage fields, in rule order).
function Get-IdentifierField { param($Result) @($Result.Config.Match.Rules | ForEach-Object UsageField | Select-Object -Unique) }
