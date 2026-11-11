# Largest-remainder rounding to cents (spec 7.3). The results add up to $Total exactly.
# $Shares must be in the deterministic row order; remainder ties go to the earlier share.
function Invoke-LargestRemainder {
    param([Parameter(Mandatory)] [decimal]$Total, [Parameter(Mandatory)] [decimal[]]$Shares)
    $n = $Shares.Count
    $out = [decimal[]]::new($n)
    $rem = [decimal[]]::new($n)
    $sum = [decimal]0
    for ($i = 0; $i -lt $n; $i++) {
        $out[$i] = [decimal]::Floor($Shares[$i] * 100) / 100
        $rem[$i] = $Shares[$i] - $out[$i]
        $sum += $out[$i]
    }
    $left = ($Total - $sum) * 100
    if ($left -ne [decimal]::Truncate($left) -or $left -lt 0 -or $left -gt $n) {
        Stop-Divvy "Internal error: rounding cannot reach the pool total ($left cents left over $n rows)."
    }
    # Indexes by remainder (largest first), then by position.
    $order = [int[]](0..($n - 1))
    if ($n -gt 1) {
        $cmp = [System.Comparison[int]] { param($a, $b) $c = $rem[$b].CompareTo($rem[$a]); if ($c) { $c } else { $a.CompareTo($b) } }
        [Array]::Sort($order, $cmp)
    }
    for ($k = 0; $k -lt [int]$left; $k++) { $out[$order[$k]] += 0.01 }
    , $out
}

# A charge pool: one offering's seat price, or the token pool.
function New-ChargePool {
    param([string]$Name, [string]$Kind, [string]$Key, [decimal]$Price)
    [pscustomobject]@{
        Name = $Name; Kind = $Kind; Key = $Key; Price = $Price
        RowCount = 0; Units = [decimal]0; Rate = $null; Allocated = [decimal]0
        Unrecoverable = $false; Ignored = $false
    }
}

# Runs the vendor rule on the pool rows and checks the money (spec 7.2-7.4).
function Invoke-Allocation {
    param([Parameter(Mandatory)] $Result)
    $rule = $Result.Config.Rule
    $poolRows = @(Get-SortedByKey @($Result.Rows | Where-Object State -ne 'NotHere') { param($r) Get-RowSortKey $r $Result })
    $pools = @(& $rule.Allocate -PoolRows $poolRows -AllRows $Result.Rows -Quote $Result.Quote -Policy $Result.Config.Policy)
    foreach ($row in $Result.Rows) { $row.RowTotal = $row.SeatCharge + $row.TokenCharge }
    $Result.Pools = $pools

    $quoteTotal = [decimal]0; $unrecovered = [decimal]0; $allocated = [decimal]0
    foreach ($p in $pools | Where-Object { -not $_.Ignored }) {
        $quoteTotal += $p.Price
        if ($p.Unrecoverable) { $unrecovered += $p.Price }
        elseif ($p.Allocated -ne $p.Price) { Stop-Divvy "Internal error: pool '$($p.Name)' does not add up to its price." }
    }
    foreach ($row in $Result.Rows) { $allocated += $row.RowTotal }
    $bad = @($pools | Where-Object Unrecoverable)
    $ignored = @($pools | Where-Object Ignored)
    $Result.Reconciliation = [ordered]@{
        QuoteTotal = $quoteTotal; Allocated = $allocated; Unrecovered = $unrecovered
        PoolCount = $pools.Count; UnrecoveredPools = $bad.Count; IgnoredPools = $ignored.Count
        Balanced = ($allocated + $unrecovered) -eq $quoteTotal
    }
    if (-not $Result.Reconciliation.Balanced) { Stop-Divvy 'Internal error: charges + unrecovered do not equal the quote total.' }

    if ($ignored.Count) {
        Add-Issue $Result Warning UnusedQuoteOffering "Quote offerings with no usage rows, left out of the total (Policy.UnusedQuoteOffering = Ignore): $(($ignored | ForEach-Object Key) -join ', ')."
    }
    if ($bad.Count) {
        $names = ($bad | ForEach-Object Name) -join ', '
        if (-not $Result.Options.AllowUnrecovered) {
            Stop-Divvy "$($bad.Count) pool(s) have a price but nobody to charge: $names. Fix the inputs (overrides, OfferingAliases, quote), or run again with -AllowUnrecovered."
        }
        Add-Issue $Result Warning Unrecovered "$($bad.Count) pool(s) have a price but nobody to charge: $names. Not recovered (-AllowUnrecovered)."
        $Result.DraftReasons.Add("$($bad.Count) pool(s) not recovered: $names")
    }
}
