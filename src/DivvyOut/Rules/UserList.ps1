# UserList: the report is only a list of the people who used one product. No product, access, or token columns.
# The profile sets the product name and the access text with Usage.FixedValues.
#
# Equal per person: the product's price / the people on the list who are here. A person listed twice
# still pays one share (split over their rows). Each pool is rounded to cents with the largest-remainder method.
$script:VendorRules['UserList'] = @{
    Name           = 'UserList'
    RequiredFields = @('Package', 'AccessOption')
    AccessKinds    = @('Seat')
    Allocate       = 'Invoke-PerPersonAllocation'
}

# Also used by ExampleVendor. PoolRows: rows that are not NotHere, in the deterministic order.
function Invoke-PerPersonAllocation {
    param([object[]]$PoolRows, [object[]]$AllRows, $Quote, $Policy)
    foreach ($offering in Get-OrdinalSorted @($Quote.SeatPrices.Keys)) {
        $price = $Quote.SeatPrices[$offering]
        $pool = New-ChargePool "Seats: $offering" 'Seat' $offering $price
        $rows = @($PoolRows | Where-Object { $_.Access -eq 'Seat' -and $_.Package -eq $offering })
        if (-not $rows.Count) { if ($price -gt 0) { $pool.Unrecoverable = $true }; $pool; continue }
        # People in the order of their first row (PoolRows is already in the deterministic order).
        $people = [ordered]@{}
        foreach ($r in $rows) {
            $k = if ($r.User) { $r.User.Id } else { "row:$($r.RowNumber)" }
            if (-not $people.Contains($k)) { $people[$k] = [System.Collections.Generic.List[object]]::new() }
            $people[$k].Add($r)
        }
        $share = $price / $people.Count
        $perPerson = Invoke-LargestRemainder $price @($people.Keys | ForEach-Object { $share })
        $i = 0
        foreach ($k in $people.Keys) {
            $mine = $people[$k]
            $each = $perPerson[$i] / $mine.Count
            $split = Invoke-LargestRemainder $perPerson[$i] @($mine | ForEach-Object { $each })
            for ($j = 0; $j -lt $mine.Count; $j++) {
                $mine[$j].SeatCharge = $split[$j]; $mine[$j].OfferingPrice = $price; $mine[$j].PoolSeatRows = $people.Count
                $pool.Allocated += $split[$j]
            }
            $i++
        }
        $pool.RowCount = $rows.Count; $pool.Units = [decimal]$people.Count
        $pool
    }
}
