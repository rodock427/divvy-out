# not-found.csv (spec 9.3): every NotHere row. overrides-template.csv: one line per NoMatch / NeedsOwner key.

function Write-NotFound {
    param([Parameter(Mandatory)] $Result, [Parameter(Mandatory)] [string]$Path)
    $ids = Get-IdentifierField $Result
    $hasTeam = $Result.Config.Usage.Columns.Contains('Team')
    $columns = @('Row') + $ids + @(if ($hasTeam) { 'Team' }) + @('Offering', 'OfferingInQuote', 'Access', 'Tokens', 'Reason', 'DirectoryId', 'DirectoryName', 'OverrideReason')
    $lines = foreach ($row in $Result.Rows | Where-Object State -eq 'NotHere') {
        $line = [ordered]@{ Row = $row.RowNumber }
        foreach ($f in $ids) { $line[$f] = ([string]$row.Fields[$f]).Trim() }
        if ($hasTeam) { $line['Team'] = $row.Fields['Team'] }
        $line.Offering = $row.PackageRaw; $line.OfferingInQuote = $row.Package; $line.Access = $row.AccessText
        $line.Tokens = ([string]$row.Fields['Tokens']).Trim(); $line.Reason = $row.Reason
        $line.DirectoryId = if ($row.User) { $row.User.Id } else { ($row.Candidates -join ';') }
        $line.DirectoryName = if ($row.User) { $row.User.Display } else { '' }
        $line.OverrideReason = if ($row.Override) { $row.Override.Reason } else { '' }
        $line
    }
    Export-DivvyCsv -Path $Path -Columns $columns -Rows @($lines)
}

function Write-OverridesTemplate {
    param([Parameter(Mandatory)] $Result, [Parameter(Mandatory)] [string]$Path)
    $rule = @($Result.Config.Overrides.KeyRules | Where-Object UsageField)[0]
    $byKey = [ordered]@{}
    $blank = 0
    foreach ($row in $Result.Rows | Where-Object { $_.Reason -eq 'NoMatch' -or $_.State -eq 'NeedsOwner' }) {
        $key = if ($rule) { ([string]$row.Fields[$rule.UsageField]).Trim() } else { '' }
        if (-not $key) { $blank++; continue }
        $norm = ConvertTo-NormalizedValue $key $rule.Normalize
        if (-not $byKey.Contains($norm)) { $byKey[$norm] = [ordered]@{ Key = $key; Problems = [System.Collections.Generic.List[string]]::new() } }
        $p = "$($row.Reason) (row $($row.RowNumber))"
        $byKey[$norm].Problems.Add($p)
    }
    if ($blank) { Add-Issue $Result Info TemplateBlankKey "$blank NoMatch/NeedsOwner rows have no value for the first usage-field key rule and are not in overrides-template.csv." }
    $lines = foreach ($e in $byKey.Values) {
        [ordered]@{ Key = $e.Key; Manager = ''; CostCenter = ''; Exclude = ''; Include = ''; LinkTo = ''; Reason = ''; By = ''; Date = ''; Problem = $e.Problems -join '; ' }
    }
    Export-DivvyCsv -Path $Path -Columns $script:OverrideColumns -Rows @($lines)
}
