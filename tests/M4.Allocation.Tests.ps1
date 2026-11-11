# M4: allocation engine, largest-remainder rounding, invariant, unrecoverable pools, ordering. Fake data only.
BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    $script:Boss = New-TestAdUser boss
    function Run {
        param([object[]]$AdUsers, [object[]]$UsageRows, [hashtable]$Quote, [hashtable]$TestProfile = (Get-TestProfile), [string]$Name = 'a', [switch]$AllowUnrecovered, [object[]]$Overrides)
        $s = New-TestRun -AdUsers $AdUsers -UsageRows $UsageRows -Quote $Quote -TestProfile $TestProfile -Name $Name -Overrides $Overrides
        Invoke-DivvyOut @s -PassThru -AllowUnrecovered:$AllowUnrecovered 6>$null
    }
    function Users { param([int]$N) @($Boss) + @(1..$N | ForEach-Object { New-TestAdUser "u$_" -Manager boss }) }
    function Assert-Money {
        param($Result)
        $rec = $Result.Reconciliation
        ($rec.Allocated + $rec.Unrecovered) | Should -Be $rec.QuoteTotal
        $sum = Get-DecimalSum ($Result.Rows | ForEach-Object RowTotal)
        $sum | Should -Be $rec.Allocated
        foreach ($row in $Result.Rows) {
            foreach ($c in $row.SeatCharge, $row.TokenCharge) {
                $c | Should -BeOfType [decimal]
                $c | Should -BeGreaterOrEqual 0
                $c | Should -Be ([decimal]::Round($c, 2))
            }
            if ($row.State -eq 'NotHere') { $row.RowTotal | Should -Be 0 }
        }
        foreach ($p in $Result.Pools | Where-Object { -not $_.Unrecoverable -and -not $_.Ignored }) {
            $rows = if ($p.Kind -eq 'Seat') { @($Result.Rows | Where-Object { $_.Access -eq 'Seat' -and $_.Package -eq $p.Key }) } else { @($Result.Rows | Where-Object Access -eq 'Token') }
            $charge = if ($p.Kind -eq 'Seat') { 'SeatCharge' } else { 'TokenCharge' }
            (Get-DecimalSum ($rows | ForEach-Object $charge)) | Should -Be $p.Price -Because "pool '$($p.Name)' adds up to its price"
            if ($p.Kind -eq 'Seat') {
                $c = @($rows | Where-Object State -ne 'NotHere' | ForEach-Object SeatCharge | Sort-Object)
                if ($c.Count) { ($c[-1] - $c[0]) | Should -BeLessOrEqual 0.01 }
            }
        }
    }
}

Describe 'Largest remainder (spec 7.3)' {
    It 'splits 100.00 three ways as 33.34, 33.33, 33.33' {
        InModuleScope DivvyOut {
            $third = [decimal]100 / 3
            $x = Invoke-LargestRemainder 100 @($third, $third, $third)
            $x | Should -Be @(33.34, 33.33, 33.33)
        }
    }

    It 'gives tie cents in the given order and adds up exactly' {
        InModuleScope DivvyOut {
            $s = [decimal]1 / 7
            $x = Invoke-LargestRemainder 1 @(1..7 | ForEach-Object { $s })
            $x | Should -Be @(0.15, 0.15, 0.14, 0.14, 0.14, 0.14, 0.14)
            $t = [decimal]0; foreach ($v in $x) { $t += $v }; $t | Should -Be 1
        }
    }

    It 'gives the extra cent to the largest remainder first' {
        InModuleScope DivvyOut {
            (Invoke-LargestRemainder 1 @([decimal]0.101, [decimal]0.105, [decimal]0.794)) | Should -Be @(0.10, 0.11, 0.79)
        }
    }

    It 'handles zero shares and exact shares' {
        InModuleScope DivvyOut {
            (Invoke-LargestRemainder 10 @([decimal]0, [decimal]10)) | Should -Be @(0, 10)
            (Invoke-LargestRemainder 0 @([decimal]0, [decimal]0)) | Should -Be @(0, 0)
        }
    }
}

Describe 'Seat and token charges (spec 7.2)' {
    It 'splits a seat price over 7 rows to the cent' {
        $u = @(1..7 | ForEach-Object { New-TestUsageRow "u$_@test.example" 'Off A' 'Seats' })
        $r = Run (Users 7) $u @{ Period = '2027'; Currency = 'USD'; SeatPrices = @{ 'Off A' = '1000.00' } }
        Assert-Money $r
        @($r.Rows | ForEach-Object SeatCharge) | Should -Be @(142.86, 142.86, 142.86, 142.86, 142.86, 142.85, 142.85)
    }

    It 'does not round the token rate, only the row charges' {
        $u = @(1..3 | ForEach-Object { New-TestUsageRow "u$_@test.example" 'Off A' 'Tokens' 1 })
        $r = Run (Users 3) $u @{ Period = '2027'; Currency = 'USD'; SeatPrices = @{}; TokenPoolPrice = 100 }
        Assert-Money $r
        $r.Rows[0].TokenRate | Should -Be ([decimal]100 / 3)
        @($r.Rows | ForEach-Object TokenCharge) | Should -Be @(33.34, 33.33, 33.33)
    }

    It 'charges NeedsOwner rows and leaves NotHere rows out of every divisor' {
        $ad = @(Users 2) + @(New-TestAdUser orphan) + @(New-TestAdUser gone -Disabled)
        $u = @(
            New-TestUsageRow 'u1@test.example' 'Off A' 'Seats'
            New-TestUsageRow 'orphan@test.example' 'Off A' 'Seats'          # NeedsOwner: in the pool
            New-TestUsageRow 'gone@test.example' 'Off A' 'Seats'            # NotHere
            New-TestUsageRow 'ghost@test.example' 'Off A' 'Seats'           # NotHere
            New-TestUsageRow 'u2@test.example' 'Off A' 'Tokens' 300
            New-TestUsageRow 'ghost@test.example' 'Off A' 'Tokens' 700       # NotHere
        )
        $r = Run $ad $u @{ Period = '2027'; Currency = 'USD'; SeatPrices = @{ 'Off A' = 900 }; TokenPoolPrice = 60 }
        Assert-Money $r
        @($r.Rows | ForEach-Object RowTotal) | Should -Be @(450, 450, 0, 0, 60, 0)
        $r.Rows[1].State | Should -Be 'NeedsOwner'
        $r.Rows[4].PoolTokens | Should -Be 300
    }
}

Describe 'Unrecoverable pools (spec 7.4)' {
    BeforeAll {
        $ad = @(Users 1) + @(New-TestAdUser gone -Disabled)
        $script:SeatGone = @(New-TestUsageRow 'u1@test.example' 'Off A' 'Seats'; New-TestUsageRow 'gone@test.example' 'Off B' 'Seats')
        $script:QuoteAB = @{ Period = '2027'; Currency = 'USD'; SeatPrices = @{ 'Off A' = 500; 'Off B' = 300 } }
        $script:AdGone = $ad
    }

    It 'stops when an offering has a price but every seat row is NotHere' {
        $s = New-TestRun -AdUsers $AdGone -UsageRows $SeatGone -Quote $QuoteAB -Name 'stop'
        { Invoke-DivvyOut @s 6>$null } | Should -Throw '*nobody to charge: Seats: Off B*-AllowUnrecovered*'
        Get-Content (Join-Path (Get-RunFolder $s).FullName 'diagnostics.txt') -Raw | Should -Match 'unrecoverable: 1'
    }

    It 'with -AllowUnrecovered, charges what it can, reports the rest, and is DRAFT' {
        $r = Run $AdGone $SeatGone $QuoteAB -Name 'allow' -AllowUnrecovered
        Assert-Money $r
        $r.Reconciliation.QuoteTotal | Should -Be 800
        $r.Reconciliation.Allocated | Should -Be 500
        $r.Reconciliation.Unrecovered | Should -Be 300
        $r.DraftReasons -join ' ' | Should -Match 'not recovered'
    }

    It 'stops when the token pool has a price but zero pool tokens' {
        $u = @(New-TestUsageRow 'u1@test.example' 'Off A' 'Tokens' 0)
        $s = New-TestRun -AdUsers (Users 1) -UsageRows $u -Quote @{ Period = '2027'; Currency = 'USD'; SeatPrices = @{}; TokenPoolPrice = 100 } -Name 'tok'
        { Invoke-DivvyOut @s 6>$null } | Should -Throw '*Token pool*'
    }

    It 'treats a quote offering with no usage rows as unrecoverable (Policy.UnusedQuoteOffering = Stop)' {
        $q = @{ Period = '2027'; Currency = 'USD'; SeatPrices = @{ 'Off A' = 500; 'Off Unused' = 50 } }
        $s = New-TestRun -AdUsers (Users 1) -UsageRows @($SeatGone[0]) -Quote $q -Name 'unused'
        { Invoke-DivvyOut @s 6>$null } | Should -Throw '*Seats: Off Unused*'
    }

    It 'leaves such an offering out of the total with Policy.UnusedQuoteOffering = Ignore' {
        $p = Get-TestProfile; $p.Policy = @{ UnusedQuoteOffering = 'Ignore' }
        $q = @{ Period = '2027'; Currency = 'USD'; SeatPrices = @{ 'Off A' = 500; 'Off Unused' = 50 } }
        $r = Run (Users 1) @($SeatGone[0]) $q -TestProfile $p -Name 'ignore'
        Assert-Money $r
        $r.Reconciliation.QuoteTotal | Should -Be 500
        ($r.Issues | Where-Object Code -eq 'UnusedQuoteOffering').Message | Should -Match 'Off Unused'
    }
}

Describe 'Ordering (FR-9)' {
    BeforeAll {
        $rnd = [System.Random]::new(7)
        $script:OrdAd = Users 30
        $script:OrdUsage = @(1..30 | ForEach-Object {
                New-TestUsageRow "u$_@test.example" 'Off A' 'Seats'
                if ($_ % 3 -eq 0) { New-TestUsageRow "u$_@test.example" 'Off B' 'Tokens' ($rnd.Next(1, 999)) }
            })
        $script:OrdQuote = @{ Period = '2027'; Currency = 'USD'; SeatPrices = @{ 'Off A' = '1000.01' }; TokenPoolPrice = '777.77' }
        function UserTotals { param($r) $h = [ordered]@{}; foreach ($row in $r.Rows | Sort-Object { $_.Fields.Email }) { $h[$row.Fields.Email] = [decimal]$h[$row.Fields.Email] + $row.RowTotal }; ($h.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';' }
    }

    It 'gives the same charges in the same order every run' {
        $a = Run $OrdAd $OrdUsage $OrdQuote -Name 'o1'
        $b = Run $OrdAd $OrdUsage $OrdQuote -Name 'o2'
        (@($a.Rows | ForEach-Object RowTotal) -join ',') | Should -Be (@($b.Rows | ForEach-Object RowTotal) -join ',')
    }

    It 'gives every user the same total when the input rows are shuffled' {
        $a = Run $OrdAd $OrdUsage $OrdQuote -Name 'o3'
        $shuffled = @($OrdUsage[($OrdUsage.Count - 1)..0])
        $b = Run $OrdAd $shuffled $OrdQuote -Name 'o4'
        UserTotals $b | Should -Be (UserTotals $a)
    }
}

Describe 'Reconciliation invariant with random data (spec 7.4)' {
    It 'holds for random case <Seed>' -ForEach @(1..30 | ForEach-Object { @{ Seed = $_ } }) {
        $rnd = [System.Random]::new($Seed * 7919)
        $n = $rnd.Next(1, 40)
        $ad = @($Boss) + @(1..$n | ForEach-Object {
                $mgr = if ($rnd.NextDouble() -lt 0.05) { '' } else { 'boss' }
                New-TestAdUser "u$_" -Manager $mgr -Disabled:($rnd.NextDouble() -lt 0.15)
            })
        $offers = 'Off A', 'Off B', 'Off C'
        $usage = @(1..$n | ForEach-Object {
                $id = $_
                1..($rnd.Next(1, 4)) | ForEach-Object {
                    $tok = $rnd.NextDouble() -lt 0.4
                    New-TestUsageRow "u$id@test.example" $offers[$rnd.Next(3)] $(if ($tok) { 'Tokens' } else { 'Seats' }) $(if ($tok) { $rnd.Next(0, 5000) } else { '' })
                }
            }) + @(0..($rnd.Next(0, 5)) | Where-Object { $_ } | ForEach-Object { New-TestUsageRow "ghost$_@test.example" $offers[$rnd.Next(3)] 'Seats' })
        $quote = @{ Period = '2027'; Currency = 'USD'; TokenPoolPrice = ([decimal]$rnd.Next(0, 5000000) / 100).ToString([cultureinfo]::InvariantCulture)
            SeatPrices = @{} }
        foreach ($o in $offers) { $quote.SeatPrices[$o] = ([decimal]$rnd.Next(0, 5000000) / 100).ToString([cultureinfo]::InvariantCulture) }
        # Some people moved to a seat by override (SeatFor, D85).
        $ov = @(1..$n | Where-Object { $rnd.NextDouble() -lt 0.2 } | ForEach-Object { [pscustomobject]@{ Key = "u$_@test.example"; SeatFor = $offers[$rnd.Next(3)] } })
        $r = Run $ad $usage $quote -Name "rand$Seed" -AllowUnrecovered -Overrides $ov
        Assert-Money $r
    }
}

Describe 'Rounding tie order (spec 7.3, DECISIONS D18)' {
    It 'gives tie cents by offering, then directory ID (ordinal), not by file order' {
        $ad = Users 12
        $u = @(12..1 | ForEach-Object { New-TestUsageRow "u$_@test.example" 'Off A' 'Seats' })    # file order reversed
        $r = Run $ad $u @{ Period = '2027'; Currency = 'USD'; SeatPrices = @{ 'Off A' = '100.04' } } -Name 'tie'
        # 100.04 / 12 = 8.3366..; floors 8.33 x 12 = 99.96; 8 cents go to the first 8 IDs in ordinal order:
        # id-u1, id-u10, id-u11, id-u12, id-u2, id-u3, id-u4, id-u5
        $got = @($r.Rows | Where-Object SeatCharge -eq 8.34 | ForEach-Object { $_.User.Id } | Sort-Object)
        $got | Should -Be @('id-u1', 'id-u10', 'id-u11', 'id-u12', 'id-u2', 'id-u3', 'id-u4', 'id-u5')
    }

    It 'sorts with ordinal compare in the helper' {
        InModuleScope DivvyOut {
            $items = @([pscustomobject]@{ k = 'b' }, [pscustomobject]@{ k = 'a10' }, [pscustomobject]@{ k = 'B' }, [pscustomobject]@{ k = 'a2' })
            (Get-SortedByKey $items { param($x) $x.k }) | ForEach-Object k | Should -Be @('B', 'a10', 'a2', 'b')
        }
    }
}
