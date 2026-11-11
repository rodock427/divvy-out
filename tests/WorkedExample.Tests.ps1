# Spec Section 7.5. The first unit test. Fake data only.
BeforeAll { . $PSScriptRoot/TestHelpers.ps1 }

Describe 'Worked example (spec 7.5)' {
    BeforeAll {
        $ad = @(
            New-TestAdUser boss
            New-TestAdUser x -Manager boss
            1..9 | ForEach-Object { New-TestAdUser "s$_" -Manager boss }
            New-TestAdUser gone -Manager boss -Disabled
            New-TestAdUser t1 -Manager boss
            New-TestAdUser t2 -Manager boss
        )
        $usage = @(
            New-TestUsageRow 'x@test.example' 'Offering One' 'Seats'
            1..9 | ForEach-Object { New-TestUsageRow "s$_@test.example" 'Offering One' 'Seats' }
            New-TestUsageRow 'gone@test.example' 'Offering One' 'Seats'                # NotHere: disabled
            New-TestUsageRow 'x@test.example' 'Offering Two' 'Tokens' 2500
            New-TestUsageRow 't1@test.example' 'Offering Two' 'Tokens' 40000
            New-TestUsageRow 't2@test.example' 'Offering Two' 'Tokens' 57500
            New-TestUsageRow 'departed@test.example' 'Offering Two' 'Tokens' 10000     # NotHere: no match
        )
        # Offering Two has only token rows, so it has no seat price (see DECISIONS D10).
        $quote = @{ Period = '2027'; Currency = 'USD'; SeatPrices = @{ 'Offering One' = 12000 }; TokenPoolPrice = 30000 }
        $splat = New-TestRun -AdUsers $ad -UsageRows $usage -Quote $quote
        $r = Invoke-DivvyOut @splat -PassThru
        $rows = { param($email) @($r.Rows | Where-Object { $_.Fields['Email'] -eq $email }) }
    }

    It 'has 10 pool seat rows in Offering One at 1,200.00 each' {
        $seat = @($r.Rows | Where-Object { $_.Access -eq 'Seat' -and $_.State -ne 'NotHere' })
        $seat.Count | Should -Be 10
        $seat | ForEach-Object { $_.SeatCharge | Should -Be ([decimal]1200.00) }
        $seat[0].PoolSeatRows | Should -Be 10
    }

    It 'has 100,000 pool tokens and a token rate of 0.30' {
        $tok = @($r.Rows | Where-Object { $_.Access -eq 'Token' -and $_.State -ne 'NotHere' })
        $tok[0].PoolTokens | Should -Be ([decimal]100000)
        $tok[0].TokenRate | Should -Be ([decimal]0.30)
    }

    It 'charges user X 1,200.00 + 750.00 = 1,950.00' {
        $x = & $rows 'x@test.example'
        (Get-DecimalSum ($x | ForEach-Object SeatCharge)) | Should -Be ([decimal]1200.00)
        (Get-DecimalSum ($x | ForEach-Object TokenCharge)) | Should -Be ([decimal]750.00)
        (Get-DecimalSum ($x | ForEach-Object RowTotal)) | Should -Be ([decimal]1950.00)
    }

    It 'charges the NotHere seat user and the departed token user 0.00' {
        $gone = & $rows 'gone@test.example'
        $gone.State | Should -Be 'NotHere'
        $gone.Reason | Should -Be 'Disabled'
        $gone.RowTotal | Should -Be ([decimal]0)
        $dep = & $rows 'departed@test.example'
        $dep.State | Should -Be 'NotHere'
        $dep.Reason | Should -Be 'NoMatch'
        $dep.RowTotal | Should -Be ([decimal]0)
    }

    It 'allocates exactly the quote (42,000.00) and is FINAL' {
        (Get-DecimalSum ($r.Rows | ForEach-Object RowTotal)) | Should -Be ([decimal]42000)
        $r.Status | Should -Be 'FINAL'
    }

    It 'lists both NotHere users in the Not-found report' {
        $nf = Import-Csv (Join-Path (Get-RunFolder $splat).FullName 'not-found.csv')
        @($nf).Count | Should -Be 2
        ($nf | ForEach-Object Reason | Sort-Object) -join ',' | Should -Be 'Disabled,NoMatch'
    }
}
