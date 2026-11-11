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

function Write-Summary {
    param([Parameter(Mandatory)] $Result, [Parameter(Mandatory)] [string]$Path)
    $lines = foreach ($g in Get-ManagerSummary $Result) {
        [ordered]@{
            Status = $Result.Status; Manager = $g.Name; ManagerId = $g.Id; People = $g.People.Count; Rows = $g.Rows.Count
            SeatTotal = Format-Money $g.Seat; TokenTotal = Format-Money $g.Token; Total = Format-Money $g.Total
        }
    }
    $un = $Result.Reconciliation.Unrecovered
    if ($un -gt 0) {
        $lines = @($lines) + [ordered]@{ Status = $Result.Status; Manager = 'UNRECOVERED (nobody to charge)'; ManagerId = ''; People = 0; Rows = 0
            SeatTotal = ''; TokenTotal = ''; Total = Format-Money $un }
    }
    Export-DivvyCsv -Path $Path -Columns 'Status', 'Manager', 'ManagerId', 'People', 'Rows', 'SeatTotal', 'TokenTotal', 'Total' -Rows @($lines)
}
