# Small helpers shared by the core.

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
    $Result.Issues.Add([pscustomobject]@{ Level = $Level; Code = $Code; Message = $Message; Rows = $Rows; Detail = $Detail })
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
