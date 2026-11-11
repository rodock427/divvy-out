# audit.csv (spec 9.4): one row per usage row, every number the reports use (NFR-3), then every usage
# column as it is (usage_<header>) and every Ad.Attributes value of the matched user (ad_<attribute>).
# Owner-only: it holds personal data.

function Write-Audit {
    param([Parameter(Mandatory)] $Result, [Parameter(Mandatory)] [string]$Path)
    $inv = [cultureinfo]::InvariantCulture
    $num = { param($d) if ($null -eq $d) { '' } else { ([decimal]$d).ToString($inv) } }
    $ids = Get-IdentifierField $Result
    $hasTeam = $Result.Config.Usage.Columns.Contains('Team')
    $adAttrs = @($Result.Config.Ad.Attributes)
    $headers = @($Result.Usage.Headers)
    $stamp = $Result.Started.ToString('yyyy-MM-ddTHH:mm:ss')

    $columns = @('Row') + $ids + @(if ($hasTeam) { 'Team' }) + @(
        'State', 'Reason', 'MatchStatus', 'MatchRule', 'MatchValue', 'DirectoryValue', 'DirectoryId', 'DirectoryName', 'Candidates',
        'PreferEnabledDropped', 'DisabledSkipped',
        'Offering', 'OfferingInQuote', 'Access', 'MovedToSeat', 'TokensBeforeSeat', 'OfferingPrice', 'PoolSeatRows', 'SeatCharge',
        'Tokens', 'PoolTokens', 'TokenRate', 'TokenCharge', 'RowTotal',
        'ManagerDirectoryId', 'ManagerDirectory', 'ManagerFinalId', 'ManagerFinal', 'ManagerSource',
        'CostCenterRaw', 'CostCenterFinal',
        'Override', 'OverrideRow', 'OverrideReason', 'OverrideBy', 'OverrideDate', 'LinkOverrideRow',
        'RunId', 'RunTimestamp', 'ToolVersion'
    ) + @($headers | ForEach-Object { "usage_$_" }) + @($adAttrs | ForEach-Object { "ad_$_" })

    $lines = foreach ($row in $Result.Rows) {
        $o = $row.Override
        $line = [ordered]@{ Row = $row.RowNumber }
        foreach ($f in $ids) { $line[$f] = [string]$row.Fields[$f] }
        if ($hasTeam) { $line.Team = [string]$row.Fields['Team'] }
        $line.State = $row.State; $line.Reason = $row.Reason
        $line.MatchStatus = $row.MatchStatus; $line.MatchRule = $(if ($row.MatchStatus -eq 'Linked') { 'Override' } else { $row.MatchRule })
        $line.MatchValue = $row.MatchValue; $line.DirectoryValue = $row.MatchDirValue
        $line.DirectoryId = if ($row.User) { $row.User.Id } else { '' }
        $line.DirectoryName = if ($row.User) { $row.User.Display } else { '' }
        $line.Candidates = @($row.Candidates) -join ';'
        $line.PreferEnabledDropped = if ($row.PreferEnabledDropped) { 'Y' } else { 'N' }
        $line.DisabledSkipped = if ($row.DisabledSkipped) { 'Y' } else { 'N' }
        $line.Offering = $row.PackageRaw; $line.OfferingInQuote = $row.Package; $line.Access = $row.Access
        $line.MovedToSeat = if ($row.MovedToSeat) { 'Y' } else { 'N' }; $line.TokensBeforeSeat = & $num $row.TokensBeforeSeat
        $line.OfferingPrice = if ($null -ne $row.OfferingPrice) { Format-Money $row.OfferingPrice } else { '' }
        $line.PoolSeatRows = $row.PoolSeatRows
        $line.SeatCharge = Format-Money $row.SeatCharge
        $line.Tokens = & $num $row.Tokens; $line.PoolTokens = & $num $row.PoolTokens; $line.TokenRate = & $num $row.TokenRate
        $line.TokenCharge = Format-Money $row.TokenCharge; $line.RowTotal = Format-Money $row.RowTotal
        $line.ManagerDirectoryId = $row.ManagerDirId; $line.ManagerDirectory = $row.ManagerDirName
        $line.ManagerFinalId = $row.ManagerId; $line.ManagerFinal = $row.ManagerName; $line.ManagerSource = $row.ManagerSource
        $line.CostCenterRaw = $row.CostCenterRaw; $line.CostCenterFinal = $row.CostCenter
        $line.Override = if ($o) { 'Y' } else { 'N' }
        $line.OverrideRow = if ($o) { $o.RowNumber } else { '' }
        $line.OverrideReason = if ($o) { $o.Reason } else { '' }
        $line.OverrideBy = if ($o) { $o.By } else { '' }
        $line.OverrideDate = if ($o) { $o.Date } else { '' }
        $line.LinkOverrideRow = if ($row.LinkOverride) { $row.LinkOverride.RowNumber } else { '' }
        $line.RunId = $Result.RunId; $line.RunTimestamp = $stamp; $line.ToolVersion = $Result.ToolVersion
        foreach ($h in $headers) { $line["usage_$h"] = $row.Source[$h] }
        foreach ($a in $adAttrs) { $line["ad_$a"] = if ($row.User) { [string]$row.User.Record.$a } else { '' } }
        $line
    }
    Export-DivvyCsv -Path $Path -Columns $columns -Rows @($lines)
}
