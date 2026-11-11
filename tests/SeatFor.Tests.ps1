# SeatFor override (DECISIONS D85): a person's token rows on an offering become one seat of it. Fake data only.
# Worked by hand:
#   Quote: Off A seats 1000.00, Off Y seats 600.00, token pool 300.00.
#   ann  seat  Off A                SeatFor Off A  -> already has a seat: no change (warning)
#   bob  token Off Y 900            SeatFor Off Y  -> seat of Off Y
#   cid  token Off Y 500            (no override)  -> stays a token user
#   dee  token Off Y 300 + 200      SeatFor off y  -> ONE seat of Off Y (first row by sort key); 2nd row MovedToSeat
#   fay  token Off A 100            SeatFor Off Y  -> no token row on Off Y: no change (warning)
#   Off A: 1000.00 / 1 seat (ann)             = ann 1000.00
#   Off Y:  600.00 / 2 seats (bob, dee)       = 300.00 each
#   Tokens: 300.00 / 600 tokens (cid 500, fay 100) = cid 250.00, fay 50.00
#   Total 1900.00 = quote.
BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    $script:Ad = @('ann', 'bob', 'cid', 'dee', 'fay' | ForEach-Object { New-TestAdUser $_ -Manager boss }) + @(New-TestAdUser boss)
    $script:Usage = @(
        New-TestUsageRow 'ann@test.example' 'Off A' 'Seats'
        New-TestUsageRow 'bob@test.example' 'Off Y' 'Tokens' 900
        New-TestUsageRow 'cid@test.example' 'Off Y' 'Tokens' 500
        New-TestUsageRow 'dee@test.example' 'Off Y' 'Tokens' 300
        New-TestUsageRow 'dee@test.example' 'Off Y' 'Tokens' 200
        New-TestUsageRow 'fay@test.example' 'Off A' 'Tokens' 100
    )
    $script:Quote = @{ Period = '2028'; Currency = 'USD'; SeatPrices = @{ 'Off A' = '1000.00'; 'Off Y' = '600.00' }; TokenPoolPrice = '300.00' }
    $script:Ov = @(
        [pscustomobject]@{ Key = 'ann@test.example'; SeatFor = 'Off A'; Reason = 'r'; By = ''; Date = '' }
        [pscustomobject]@{ Key = 'bob@test.example'; SeatFor = 'Off Y'; Reason = 'Bought a seat in the new quote'; By = 'owner'; Date = '2027-11-01' }
        [pscustomobject]@{ Key = 'dee@test.example'; SeatFor = 'off y'; Reason = 'r' }
        [pscustomobject]@{ Key = 'fay@test.example'; SeatFor = 'Off Y'; Reason = 'r' }
    )
    function Run { param([object[]]$Overrides, [hashtable]$TestProfile = (Get-TestProfile), [string]$Name = 'sf', [switch]$AllowUnrecovered)
        $s = New-TestRun -AdUsers $Ad -UsageRows $Usage -Quote $Quote -Overrides $Overrides -TestProfile $TestProfile -Name $Name
        $r = Invoke-DivvyOut @s -PassThru -AllowUnrecovered:$AllowUnrecovered 6>$null
        $r | Add-Member Folder (Get-RunFolder $s).FullName -PassThru
    }
    function Row { param($R, [int]$N) $R.Rows | Where-Object RowNumber -eq $N }
    $script:R = Run $Ov
}

Describe 'SeatFor override' {
    It 'charges the worked example' {
        (Row $R 2).RowTotal | Should -Be 1000.00              # ann
        (Row $R 3).SeatCharge | Should -Be 300.00             # bob
        (Row $R 3).TokenCharge | Should -Be 0
        (Row $R 4).TokenCharge | Should -Be 250.00            # cid
        ((Row $R 5).RowTotal + (Row $R 6).RowTotal) | Should -Be 300.00   # dee: one seat
        (Row $R 7).TokenCharge | Should -Be 50.00             # fay
        $R.Reconciliation.Allocated | Should -Be 1900.00
        $R.Reconciliation.Unrecovered | Should -Be 0
    }

    It 'turns the rows into one seat and takes their tokens out of the token pool' {
        (Row $R 3).Access | Should -Be 'Seat'; (Row $R 3).MovedToSeat | Should -BeTrue; (Row $R 3).TokensBeforeSeat | Should -Be 900
        $dee = @((Row $R 5), (Row $R 6))
        @($dee | Where-Object Access -eq 'Seat').Count | Should -Be 1
        $extra = $dee | Where-Object State -eq 'NotHere'
        $extra.Reason | Should -Be 'MovedToSeat'; $extra.Tokens | Should -Be 0
        ($R.Pools | Where-Object Name -eq 'Token pool').Units | Should -Be 600
        ($R.Pools | Where-Object Name -eq 'Seats: Off Y').RowCount | Should -Be 2
    }

    It 'warns when SeatFor changes nothing (already a seat, or no token row on the offering)' {
        $w = $R.Issues | Where-Object Code -eq 'SeatForNoEffect'
        $w.Rows | Should -Be @(2, 5)    # override rows for ann and fay
        (Row $R 2).MovedToSeat | Should -BeFalse
        (Row $R 7).Access | Should -Be 'Token'
        $R.Status | Should -Be 'FINAL'
    }

    It 'records it in the audit and on the statement' {
        $a = @(Import-Csv (Join-Path $R.Folder 'audit.csv'))
        $bob = $a | Where-Object Row -eq 3
        $bob.Access | Should -Be 'Seat'; $bob.MovedToSeat | Should -Be 'Y'; $bob.TokensBeforeSeat | Should -Be '900'
        $bob.OverrideReason | Should -Be 'Bought a seat in the new quote'
        $bob.'usage_Access Options' | Should -Be 'Tokens'
        $f = Get-ChildItem (Join-Path $R.Folder 'statements') -Filter 'Person boss*.xlsx'
        $pkg = Open-ExcelPackage -Path $f.FullName
        try {
            $ws = $pkg.Workbook.Worksheets['How this was calculated']
            $text = @(1..$ws.Dimension.End.Row | ForEach-Object { [string]$ws.Cells[$_, 1].Value }) -join "`n"
        }
        finally { Close-ExcelPackage $pkg -NoSave }
        $text | Should -Match 'Person bob, Off Y: moved to a seat instead of 900 tokens\. Bought a seat in the new quote \(owner, 2027-11-01\)'
        $text | Should -Match 'Person dee, Off Y: moved to a seat instead of 500 tokens'   # both rows
    }

    It 'without the overrides, the new seat offering has nobody to charge' {
        $x = Run @() -Name 'none' -AllowUnrecovered
        $x.Reconciliation.Unrecovered | Should -Be 600.00
    }

    It 'accepts an offering name from Usage.OfferingAliases, and several names with ;' {
        $p = Get-TestProfile; $p.Usage.OfferingAliases = @{ 'Y Old' = 'Off Y' }
        $ov = @([pscustomobject]@{ Key = 'fay@test.example'; SeatFor = 'Y Old; Off A' })
        $x = Run $ov -TestProfile $p -Name 'alias' -AllowUnrecovered
        (Row $x 7).Access | Should -Be 'Seat'                       # fay's Off A tokens -> Off A seat
        ($x.Issues | Where-Object Code -eq 'SeatForNoEffect').Rows | Should -Be @(2)   # no token row on Off Y
    }

    It 'makes the run DRAFT when SeatFor names an offering with no seat price' {
        $ov = @([pscustomobject]@{ Key = 'bob@test.example'; SeatFor = 'Off Z' })
        $x = Run $ov -Name 'bad' -AllowUnrecovered
        ($x.Issues | Where-Object { $_.Code -eq 'OverrideBadValue' -and $_.Message -like '*SeatFor*' }).Rows | Should -Be @(2)
        $x.Status | Should -Be 'DRAFT'
        (Row $x 3).Access | Should -Be 'Token'
    }

    It 'warns when the person is not here (disabled)' {
        $ad = @($Ad | Where-Object sAMAccountName -ne 'bob') + @(New-TestAdUser bob -Manager boss -Disabled)
        $s = New-TestRun -AdUsers $ad -UsageRows $Usage -Quote $Quote -Overrides $Ov -Name 'gone'
        $x = Invoke-DivvyOut @s -PassThru -AllowUnrecovered 6>$null
        ($x.Issues | Where-Object Code -eq 'OverrideNoEffect').Rows | Should -Contain 3
        (Row $x 3).MovedToSeat | Should -BeFalse
    }
}
