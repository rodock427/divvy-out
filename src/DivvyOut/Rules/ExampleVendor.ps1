# ExampleVendor: a FAKE second vendor. It proves that a new vendor needs only a profile and a rule file
# (spec M9): no change to the core. Keep it as the template for the next real vendor.
#
# Named-user licences: each offering's price is split equally per PERSON (not per row). A person with
# several rows in one offering pays one share, split over those rows. No tokens.
$script:VendorRules['ExampleVendor'] = @{
    Name           = 'ExampleVendor'
    RequiredFields = @('Package', 'AccessOption')
    AccessKinds    = @('Seat')
    Allocate       = 'Invoke-ExampleVendorAllocation'
}

function Invoke-ExampleVendorAllocation {
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
