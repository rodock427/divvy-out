# Autodesk charge rule. Only the charge math for this vendor lives here (spec Section 12).
#   seat_charge(row)  = offering price / pool seat rows in that offering
#   token_rate        = token pool price / pool tokens          (never rounded)
#   token_charge(row) = price x tokens / pool tokens            (= tokens x rate, less decimal error)
# Each pool is rounded to cents with the largest-remainder method, so it adds up to its price exactly.
$script:VendorRules['Autodesk'] = @{
    Name           = 'Autodesk'
    RequiredFields = @('Package', 'AccessOption', 'Tokens')
    AccessKinds    = @('Seat', 'Token')
    Allocate       = 'Invoke-AutodeskAllocation'
}

# PoolRows: rows that are not NotHere, in the deterministic order. Sets SeatCharge/TokenCharge and pool
# info on those rows. Returns the pools.
function Invoke-AutodeskAllocation {
    param([object[]]$PoolRows, [object[]]$AllRows, $Quote, $Policy)
    $pools = [System.Collections.Generic.List[object]]::new()

    foreach ($offering in Get-OrdinalSorted @($Quote.SeatPrices.Keys)) {
        $price = $Quote.SeatPrices[$offering]
        $pool = New-ChargePool "Seats: $offering" 'Seat' $offering $price
        $pools.Add($pool)
        $rows = @($PoolRows | Where-Object { $_.Access -eq 'Seat' -and $_.Package -eq $offering })
        if (-not $rows.Count) {
            $used = @($AllRows | Where-Object Package -eq $offering).Count
            if (-not $used -and $Policy.UnusedQuoteOffering -eq 'Ignore') { $pool.Ignored = $true }
            elseif ($price -gt 0) { $pool.Unrecoverable = $true }
            continue
        }
        $share = $price / $rows.Count
        $cents = Invoke-LargestRemainder $price @($rows | ForEach-Object { $share })
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $rows[$i].SeatCharge = $cents[$i]; $rows[$i].OfferingPrice = $price; $rows[$i].PoolSeatRows = $rows.Count
            $pool.Allocated += $cents[$i]
        }
        $pool.RowCount = $rows.Count; $pool.Units = [decimal]$rows.Count
    }

    $price = if ($null -ne $Quote.TokenPoolPrice) { [decimal]$Quote.TokenPoolPrice } else { [decimal]0 }
    $rows = @($PoolRows | Where-Object Access -eq 'Token')
    if ($price -gt 0 -or $rows.Count) {
        $pool = New-ChargePool 'Token pool' 'Token' '' $price
        $pools.Add($pool)
        $total = [decimal]0
        foreach ($r in $rows) { $total += $r.Tokens }
        $pool.RowCount = $rows.Count; $pool.Units = $total
        if ($total -eq 0) { if ($price -gt 0) { $pool.Unrecoverable = $true } }
        else {
            $rate = $price / $total
            $pool.Rate = $rate
            $cents = Invoke-LargestRemainder $price @($rows | ForEach-Object { $price * $_.Tokens / $total })
            for ($i = 0; $i -lt $rows.Count; $i++) {
                $rows[$i].TokenCharge = $cents[$i]; $rows[$i].TokenRate = $rate; $rows[$i].PoolTokens = $total
                $pool.Allocated += $cents[$i]
            }
        }
    }
    $pools.ToArray()
}
