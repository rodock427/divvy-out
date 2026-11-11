# Seat vs token comparison on the dashboard (DECISIONS D84). Report only: charges never change. Fake data only.
BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    function Get-Data { param($Splat)
        $html = Get-Content (Join-Path (Get-RunFolder $Splat).FullName 'dashboard.html') -Raw
        [regex]::Match($html, '<script id="divvy-data" type="application/json">(.*?)</script>', 'Singleline').Groups[1].Value | ConvertFrom-Json
    }
    $script:Ad = @('boss', 'ann', 'bob', 'cid', 'dee', 'eve' | ForEach-Object { if ($_ -eq 'boss') { New-TestAdUser boss } else { New-TestAdUser $_ -Manager boss } })
    $script:Usage = @(
        New-TestUsageRow 'ann@test.example' 'Off A' 'Seats'
        New-TestUsageRow 'bob@test.example' 'Off A' 'Tokens' 900     # 900 x 0.30 = 270.00 = 108% of a 250.00 seat -> flagged
        New-TestUsageRow 'cid@test.example' 'Off A' 'Tokens' 500     # 150.00 = 60%
        New-TestUsageRow 'dee@test.example' 'Off A' 'Seats'
        New-TestUsageRow 'dee@test.example' 'Off A' 'Tokens' 1000    # 120%, but dee has a seat -> not flagged
        New-TestUsageRow 'eve@test.example' 'Off X' 'Tokens' 100     # offering not bought: cost, no comparison
    )
    $script:Base = @{ Period = '2027'; Currency = 'USD'; SeatPrices = @{ 'Off A' = '1000.00' }; TokenPoolPrice = '300.00' }
    $script:Quote = $Base.Clone(); $Quote.SeatCounts = @{ 'off a' = 4 }; $Quote.TokensPurchased = 1000
    $script:S = New-TestRun -AdUsers $Ad -UsageRows $Usage -Quote $Quote -Name 'cmp'
    $script:R = Invoke-DivvyOut @S -PassThru 6>$null
    $script:D = Get-Data $S
    $script:OffA = $D.offerings | Where-Object name -eq 'Off A'
}

Describe 'Seat vs token comparison' {
    It 'works out the vendor unit prices from what was bought' {
        $OffA.seats | Should -Be '4'
        $OffA.perSeat | Should -Be '250.00'
        $D.seatCompare.tokenPrice | Should -Be '0.30'
        $D.seatCompare.tokensBought | Should -Be '1000'
        $D.seatCompare.percent | Should -Be '100'
    }

    It 'lists every user of the offering with token cost, % of a seat, and the flag' {
        $OffA.users.person | Sort-Object | Should -Be @('Person ann', 'Person bob', 'Person cid', 'Person dee')
        $bob = $OffA.users | Where-Object person -eq 'Person bob'
        $bob.access | Should -Be 'Token'; $bob.tokenCost | Should -Be '270.00'; $bob.share | Should -Be '108'; $bob.flag | Should -BeTrue
        $cid = $OffA.users | Where-Object person -eq 'Person cid'
        $cid.share | Should -Be '60'; $cid.flag | Should -BeFalse
        $dee = $OffA.users | Where-Object person -eq 'Person dee'
        $dee.access | Should -Be 'Seat + token'; $dee.share | Should -Be '120'; $dee.flag | Should -BeFalse
        $ann = $OffA.users | Where-Object person -eq 'Person ann'
        $ann.access | Should -Be 'Seat'; $ann.tokenCost | Should -BeNullOrEmpty; $ann.flag | Should -BeFalse
    }

    It 'shows token cost but no comparison on an offering with no seat count' {
        $eve = ($D.offerings | Where-Object name -eq 'Off X').users[0]
        $eve.tokenCost | Should -Be '30.00'; $eve.share | Should -BeNullOrEmpty; $eve.flag | Should -BeFalse
        ($D.offerings | Where-Object name -eq 'Off X').perSeat | Should -BeNullOrEmpty
    }

    It 'adds the flagged users to the attention list' {
        $a = $D.attention | Where-Object label -like 'Token users whose token cost reaches 100%*'
        $a.count | Should -Be 1
        $D.rows[$a.rows[0]].person | Should -Be 'Person bob'
    }

    It 'flags at the profile percentage' {
        $p = Get-TestProfile; $p.Dashboard = @{ SeatCandidatePercent = 50 }
        $s = New-TestRun -AdUsers $Ad -UsageRows $Usage -Quote $Quote -TestProfile $p -Name 'pct'
        $null = Invoke-DivvyOut @s 6>$null
        $d = Get-Data $s
        @(($d.offerings | Where-Object name -eq 'Off A').users | Where-Object flag).person | Sort-Object | Should -Be @('Person bob', 'Person cid')
    }

    It 'never changes the charges' {
        $s = New-TestRun -AdUsers $Ad -UsageRows $Usage -Quote $Base -Name 'base'
        $x = Invoke-DivvyOut @s -PassThru 6>$null
        $a = Get-Content (Join-Path (Get-RunFolder $S).FullName 'summary-by-manager.csv') -Raw
        $b = Get-Content (Join-Path (Get-RunFolder $s).FullName 'summary-by-manager.csv') -Raw
        $a | Should -Be $b
        @($x.Rows | ForEach-Object RowTotal) | Should -Be @($R.Rows | ForEach-Object RowTotal)
        $d = Get-Data $s
        $d.seatCompare.tokenPrice | Should -BeNullOrEmpty
        @($d.offerings.users | Where-Object flag).Count | Should -Be 0
    }

    It 'rejects bad seat counts and tokens bought' -ForEach @(
        @{ Case = 'unknown offering'; Set = @{ SeatCounts = @{ 'Off Z' = 3 } }; Msg = "'Off Z', which is not in SeatPrices" }
        @{ Case = 'not whole'; Set = @{ SeatCounts = @{ 'Off A' = '2.5' } }; Msg = 'whole number above 0' }
        @{ Case = 'zero'; Set = @{ SeatCounts = @{ 'Off A' = 0 } }; Msg = 'whole number above 0' }
        @{ Case = 'bad tokens'; Set = @{ TokensPurchased = '1,000' }; Msg = 'TokensPurchased must be a number above 0' }
    ) {
        $q = $Base.Clone(); foreach ($k in $Set.Keys) { $q[$k] = $Set[$k] }
        $s = New-TestRun -AdUsers $Ad -UsageRows $Usage -Quote $q -Name "bad$Case"; $s.Remove('OutputRoot')
        $x = Test-DivvyOutInput @s 6>$null
        ($x.Issues | Where-Object Code -eq 'QuoteInvalid').Message | Should -Match ([regex]::Escape($Msg))
    }
}
