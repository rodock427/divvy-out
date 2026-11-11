# summary-by-manager.csv (spec 9.2): one line per manager, then NO OWNER and UNRECOVERED lines.
# Every line carries the run status, since a CSV has no title.

# One entry per charge owner. NeedsOwner rows form the NO OWNER entry. Ordered by name, then ID (ordinal).
function Get-ManagerSummary {
    param([Parameter(Mandatory)] $Result)
    $groups = [ordered]@{}
    foreach ($row in $Result.Rows | Where-Object State -ne 'NotHere') {
        $key = if ($row.State -eq 'NeedsOwner') { '~NO OWNER' } elseif ($row.ManagerId) { "id:$($row.ManagerId)" } else { "text:$($row.ManagerName)" }
        if (-not $groups.Contains($key)) {
            $groups[$key] = [pscustomobject]@{
                Key = $key; Name = if ($row.State -eq 'NeedsOwner') { 'NO OWNER' } else { $row.ManagerName }
                Id = if ($row.State -eq 'NeedsOwner') { '' } else { [string]$row.ManagerId }
                People = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                Rows = [System.Collections.Generic.List[object]]::new(); Seat = [decimal]0; Token = [decimal]0; Total = [decimal]0
            }
        }
        $g = $groups[$key]
        $person = if ($row.User) { $row.User.Id } else { "row:$($row.RowNumber)" }
        [void]$g.People.Add($person)
        $g.Rows.Add($row)
        $g.Seat += $row.SeatCharge; $g.Token += $row.TokenCharge; $g.Total += $row.RowTotal
    }
    $managers = @($groups.Values | Where-Object Key -ne '~NO OWNER')
    $sorted = @(Get-SortedByKey $managers { param($g) "$($g.Name)`0$($g.Id)" })
    @($sorted) + @($groups.Values | Where-Object Key -eq '~NO OWNER')
}

# Ad.ManagerInfo values for one manager, from the manager's own directory record: ordered Label -> text.
# Blank when the manager has no directory record (free-text override manager, NO OWNER).
function Get-ManagerInfo {
    param([Parameter(Mandatory)] $Result, [string]$Id)
    $out = [ordered]@{}
    $user = $null
    $found = $Id -and $Result.Directory.ById -and $Result.Directory.ById.TryGetValue($Id, [ref]$user)
    foreach ($mi in $Result.Config.Ad.ManagerInfo) { $out[$mi.Label] = if ($found) { ([string]$user.Record.($mi.Attribute)).Trim() } else { '' } }
    $out
}

# 'Region: West · Site: HQ' (blank values left out). Empty text when there is nothing to show.
function Format-ManagerInfo {
    param($Info)
    (@($Info.Keys | Where-Object { $Info[$_] } | ForEach-Object { "${_}: $($Info[$_])" }) -join ' · ')
}

function Write-Summary {
    param([Parameter(Mandatory)] $Result, [Parameter(Mandatory)] [string]$Path)
    $infoCols = @($Result.Config.Ad.ManagerInfo | ForEach-Object Label)
    $lines = foreach ($g in Get-ManagerSummary $Result) {
        $line = [ordered]@{ Status = $Result.Status; Manager = $g.Name; ManagerId = $g.Id }
        $info = Get-ManagerInfo $Result $g.Id
        foreach ($c in $infoCols) { $line[$c] = $info[$c] }
        $line.People = $g.People.Count; $line.Rows = $g.Rows.Count
        $line.SeatTotal = Format-Money $g.Seat; $line.TokenTotal = Format-Money $g.Token; $line.Total = Format-Money $g.Total
        $line
    }
    $un = $Result.Reconciliation.Unrecovered
    if ($un -gt 0) {
        $line = [ordered]@{ Status = $Result.Status; Manager = 'UNRECOVERED (nobody to charge)'; ManagerId = '' }
        foreach ($c in $infoCols) { $line[$c] = '' }
        $line.People = 0; $line.Rows = 0; $line.SeatTotal = ''; $line.TokenTotal = ''; $line.Total = Format-Money $un
        $lines = @($lines) + $line
    }
    $columns = @('Status', 'Manager', 'ManagerId') + $infoCols + @('People', 'Rows', 'SeatTotal', 'TokenTotal', 'Total')
    Export-DivvyCsv -Path $Path -Columns $columns -Rows @($lines)
}
