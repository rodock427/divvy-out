# M1: profile loader and validator, usage reader, directory reader, diagnostics. Fake data only.
BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    $script:Ad = @(
        New-TestAdUser boss
        New-TestAdUser ann -Manager boss
        New-TestAdUser bob -Manager boss
    )
    $script:Usage = @(
        New-TestUsageRow 'ann@test.example' 'Offering One' 'Seats'
        New-TestUsageRow 'bob@test.example' 'Offering One' 'Tokens' 1200
    )
    $script:Quote = @{ Period = '2027'; Currency = 'USD'; SeatPrices = @{ 'Offering One' = 1000 }; TokenPoolPrice = 500 }
    function Test-Input {
        param([object[]]$AdUsers = $script:Ad, [object[]]$UsageRows = $script:Usage, [hashtable]$Quote = $script:Quote,
            [hashtable]$TestProfile = (Get-TestProfile), [string]$Name = 'in', [string]$UsageExtension = '.csv')
        $s = New-TestRun -AdUsers $AdUsers -UsageRows $UsageRows -Quote $Quote -TestProfile $TestProfile -Name $Name -UsageExtension $UsageExtension
        Test-DivvyOutInput -Profile $s.Profile -Quote $s.Quote -Usage $s.Usage -Ad $s.Ad 6>$null
    }
    function Get-Codes { param($Result, [string]$Level = 'Error') @($Result.Issues | Where-Object Level -eq $Level | ForEach-Object Code) }
}

Describe 'Profile and input validation (spec 5.5)' {
    It 'accepts good inputs' {
        $r = Test-Input
        Get-Codes $r | Should -BeNullOrEmpty
        $r.Status | Should -Be 'VALIDATED'
        $r.Rows.Count | Should -Be 2
    }

    It 'names a mapped header that is not in the usage file' {
        $p = Get-TestProfile; $p.Usage.Columns.Email = 'E-mail Address'
        $r = Test-Input -TestProfile $p
        Get-Codes $r | Should -Contain 'MissingUsageColumn'
        ($r.Issues | Where-Object Code -eq 'MissingUsageColumn').Message | Should -Match "'E-mail Address'"
    }

    It 'names a profile attribute that is not a directory column' {
        $p = Get-TestProfile; $p.Match.Rules[0].AdAttribute = 'workEmail'
        $r = Test-Input -TestProfile $p
        ($r.Issues | Where-Object Code -eq 'MissingDirectoryColumn').Message | Should -Match "'workEmail' \(used by Match.Rules\[1\].AdAttribute\)"
    }

    It 'stops on repeated IdAttribute values and gives the count' {
        $ad = @($script:Ad) + @(New-TestAdUser ann2 -Id 'id-ann') + @(New-TestAdUser bob2 -Id 'id-bob')
        $r = Test-Input -AdUsers $ad
        ($r.Issues | Where-Object Code -eq 'DuplicateId').Message | Should -Match 'has 2 repeated values'
    }

    It 'requires every canonical field the vendor rule needs' {
        $p = Get-TestProfile; $p.Usage.Columns.Remove('Tokens')
        $r = Test-Input -TestProfile $p
        ($r.Issues | Where-Object Code -eq 'ProfileInvalid').Message | Should -Contain "Canonical field 'Tokens' is used but not mapped in Usage.Columns."
    }

    It 'requires every UsageField used by a match rule to be mapped' {
        $p = Get-TestProfile; $p.Match.Rules += @{ UsageField = 'EmployeeNo'; AdAttribute = 'objectGUID'; Normalize = 'Trim' }
        $r = Test-Input -TestProfile $p
        ($r.Issues | Where-Object Code -eq 'ProfileInvalid').Message | Should -Contain "Canonical field 'EmployeeNo' is used but not mapped in Usage.Columns."
    }

    It 'rejects an unknown Normalize step and an unknown vendor' {
        $p = Get-TestProfile; $p.Match.Rules[0].Normalize = 'Trim', 'Lowercase'; $p.Vendor = 'Nobody'
        $r = Test-Input -TestProfile $p
        $msgs = ($r.Issues | ForEach-Object Message) -join "`n"
        $msgs | Should -Match "unknown Normalize step 'Lowercase'"
        $msgs | Should -Match "Vendor 'Nobody' has no rule module"
    }

    It 'stops on an access option value that is not in AccessOptionValues, with row numbers' {
        $u = @($script:Usage) + @(New-TestUsageRow 'ann@test.example' 'Offering One' 'Floating')
        $r = Test-Input -UsageRows $u
        $i = $r.Issues | Where-Object Code -eq 'UnknownAccessOption'
        $i.Message | Should -Match "'Floating'"
        $i.Rows | Should -Be @(4)
    }

    It 'stops on a token row with a bad token count: <Value>' -ForEach @(
        @{ Value = '' }, @{ Value = 'abc' }, @{ Value = '-5' }, @{ Value = '1,234' }
    ) {
        $u = @($script:Usage) + @(New-TestUsageRow 'ann@test.example' 'Offering One' 'Tokens' $Value)
        $r = Test-Input -UsageRows $u
        ($r.Issues | Where-Object Code -eq 'InvalidTokens').Rows | Should -Be @(4)
    }

    It 'accepts decimal tokens' {
        $u = @($script:Usage) + @(New-TestUsageRow 'ann@test.example' 'Offering One' 'Tokens' '12.5')
        $r = Test-Input -UsageRows $u
        Get-Codes $r | Should -BeNullOrEmpty
        $r.Rows[2].Tokens | Should -Be ([decimal]12.5)
    }

    It 'warns (not stops) on a seat row with tokens > 0' {
        $u = @($script:Usage) + @(New-TestUsageRow 'ann@test.example' 'Offering One' 'Seats' 300)
        $r = Test-Input -UsageRows $u
        Get-Codes $r | Should -BeNullOrEmpty
        ($r.Issues | Where-Object Code -eq 'SeatTokensIgnored').Rows | Should -Be @(4)
        $r.Rows[2].Tokens | Should -Be 0
    }

    It 'stops on a seat offering with no price, and OfferingAliases fixes it' {
        $u = @($script:Usage) + @(New-TestUsageRow 'ann@test.example' 'Offering 1 (Old)' 'Seats')
        $r = Test-Input -UsageRows $u
        ($r.Issues | Where-Object Code -eq 'UnpricedOffering').Message | Should -Match "'Offering 1 \(Old\)'"
        $p = Get-TestProfile; $p.Usage.OfferingAliases = @{ 'Offering 1 (Old)' = 'Offering One' }
        $r = Test-Input -UsageRows $u -TestProfile $p -Name 'alias'
        Get-Codes $r | Should -BeNullOrEmpty
        $r.Rows[2].Package | Should -Be 'Offering One'
        $r.Rows[2].PackageRaw | Should -Be 'Offering 1 (Old)'
    }

    It 'matches the quote offering name regardless of case' {
        $u = @(New-TestUsageRow 'ann@test.example' 'OFFERING ONE' 'Seats')
        $r = Test-Input -UsageRows $u
        Get-Codes $r | Should -BeNullOrEmpty
        $r.Rows[0].Package | Should -Be 'Offering One'
    }

    It 'requires USD' {
        $q = $script:Quote.Clone(); $q.Currency = 'EUR'
        $r = Test-Input -Quote $q
        ($r.Issues | Where-Object Code -eq 'QuoteInvalid').Message | Should -Match "must be USD"
    }

    It 'rejects a bare decimal price (it loads as [double]) and accepts string and d-suffix prices' {
        $q = $script:Quote.Clone(); $q.SeatPrices = @{ 'Offering One' = 1000.5 }
        (Get-Codes (Test-Input -Quote $q)) | Should -Contain 'QuoteInvalid'
        $q.SeatPrices = @{ 'Offering One' = '1000.50' }
        (Get-Codes (Test-Input -Quote $q -Name 'q2')) | Should -BeNullOrEmpty
        $q.SeatPrices = @{ 'Offering One' = 1000.50d }
        $r = Test-Input -Quote $q -Name 'q3'
        $r.Quote.SeatPrices['Offering One'] | Should -BeOfType [decimal]
        $q.SeatPrices = @{ 'Offering One' = '1000.505' }
        (Get-Codes (Test-Input -Quote $q -Name 'q4')) | Should -Contain 'QuoteInvalid'
    }

    It 'needs a TokenPoolPrice when there are token rows' {
        $q = $script:Quote.Clone(); $q.Remove('TokenPoolPrice')
        (Get-Codes (Test-Input -Quote $q)) | Should -Contain 'QuoteInvalid'
    }
}

Describe 'Usage reader' {
    It 'reads CSV and XLSX to the same rows' {
        $u = @($script:Usage) + @(New-TestUsageRow 'zoë.núñez@test.example' 'Offering One' 'Tokens' 2500 'CORP\zoe' 'Équipe Ünïcode')
        $csv = Test-Input -UsageRows $u -Name 'csv'
        $xlsx = Test-Input -UsageRows $u -Name 'xlsx' -UsageExtension '.xlsx'
        Get-Codes $xlsx | Should -BeNullOrEmpty
        foreach ($i in 0..2) {
            ($xlsx.Rows[$i].Fields | ConvertTo-Json) | Should -Be ($csv.Rows[$i].Fields | ConvertTo-Json)
            $xlsx.Rows[$i].Access | Should -Be $csv.Rows[$i].Access
            $xlsx.Rows[$i].Tokens | Should -Be $csv.Rows[$i].Tokens
            $xlsx.Rows[$i].RowNumber | Should -Be ($i + 2)
        }
    }

    It 'keeps non-English text intact (UTF-8)' {
        $u = @(New-TestUsageRow 'ann@test.example' 'Offering One' 'Seats' '' '' 'Søren Østergaard · 王 · Łukasz')
        $r = Test-Input -UsageRows $u
        $r.Rows[0].Fields.Team | Should -Be 'Søren Østergaard · 王 · Łukasz'
    }

    It 'maps by header name, so moving columns changes nothing' {
        $moved = $script:Usage | Select-Object 'Tokens Used', 'User Name', 'Source Email', 'Access Options', 'Offering Name', 'Team Alias'
        $a = Test-Input -Name 'a'
        $b = Test-Input -UsageRows $moved -Name 'b'
        ($b.Rows | ForEach-Object { $_.Fields | ConvertTo-Json }) -join '' | Should -Be (($a.Rows | ForEach-Object { $_.Fields | ConvertTo-Json }) -join '')
    }

    It 'matches headers ignoring case and outer spaces' {
        $p = Get-TestProfile; $p.Usage.Columns.Email = ' source email '
        Get-Codes (Test-Input -TestProfile $p) | Should -BeNullOrEmpty
    }

    It 'reads a CSV whose headers are not on row 1' {
        $dir = Join-Path $TestDrive 'hdr'; New-Item -ItemType Directory $dir | Out-Null
        $csv = ($script:Usage | ConvertTo-Csv) -join "`n"
        Set-Content (Join-Path $dir 'usage.csv') ("Exported by vendor portal`nReport period: fake`n" + $csv) -Encoding utf8
        $script:Ad | Export-Csv (Join-Path $dir 'ad.csv') -Encoding utf8BOM
        $p = Get-TestProfile; $p.Usage.HeaderRow = 3
        $r = Test-DivvyOutInput -Profile $p -Quote $script:Quote -Usage (Join-Path $dir 'usage.csv') -Ad (Join-Path $dir 'ad.csv') 6>$null
        Get-Codes $r | Should -BeNullOrEmpty
        $r.Rows[0].RowNumber | Should -Be 4
    }
}

Describe 'Diagnostics (spec 9.5)' {
    BeforeAll {
        $repo = Split-Path -Parent $PSScriptRoot
        $script:DiagSplat = @{
            Profile = Join-Path $repo 'config/profiles/autodesk.psd1'; Quote = Join-Path $repo 'config/quotes/2027-autodesk.psd1'
            Usage = Join-Path $repo 'samples/usage.xlsx'; Ad = Join-Path $repo 'samples/ad-snapshot.csv'
            Overrides = Join-Path $repo 'samples/overrides.csv'
            OutputRoot = Join-Path $TestDrive 'diag'
        }
        Invoke-DivvyOut @DiagSplat 6>$null
        $script:Diag = Get-Content (Join-Path (Get-RunFolder $DiagSplat).FullName 'diagnostics.txt') -Raw
    }

    It 'is written and lists header names and counts' {
        $Diag | Should -Match 'Usage\s+\.xlsx\s+rows=\d+ columns=24'
        $Diag | Should -Match "Email\s+<- 'Source Email'\s+found"
    }

    It 'contains no email, name, logon name, or price from the sample data' {
        $ad = Import-Csv $DiagSplat.Ad
        $usage = Import-Csv (Join-Path (Split-Path $DiagSplat.Usage) 'usage.csv')
        $secrets = @($ad.mail) + @($ad.displayName) + @($ad.sAMAccountName | Where-Object Length -ge 5) +
        @($usage.'Source Email') + @((Import-Csv $DiagSplat.Overrides) | ForEach-Object { $_.Key; $_.Manager; $_.LinkTo; $_.CostCenter }) + '48210.55', '48,210.55', '19333.33', '19,333.33', '7777.77', '7,777.77', '61777.77', '61,777.77'
        $leaks = @($secrets | Where-Object { $_ -and $Diag.Contains($_.Trim()) } | Select-Object -Unique)
        $leaks.Count | Should -Be 0 -Because "found: $($leaks -join ', ')"
    }

    It 'is written on a failed run, with the reason' {
        $p = Get-TestProfile; $p.Usage.Columns.Email = 'No Such Header'
        $s = New-TestRun -AdUsers $script:Ad -UsageRows $script:Usage -Quote $script:Quote -TestProfile $p -Name 'fail'
        { Invoke-DivvyOut @s 6>$null } | Should -Throw '*Input validation failed*'
        $d = Get-Content (Join-Path (Get-RunFolder $s).FullName 'diagnostics.txt') -Raw
        $d | Should -Match 'Status:\s+FAILED'
        $d | Should -Match "MissingUsageColumn.+'No Such Header'"
    }

    It 'masks values to their shape' {
        InModuleScope DivvyOut {
            Get-MaskedShape 'jsmith@corp.example' | Should -Be 'j***@c***.example (len 19)'
            Get-MaskedShape 'CORP\jsmith' | Should -Be 'C***\*** (len 11)'
            Get-MaskedShape 'jsmith' | Should -Be 'j*** (len 6)'
            Get-MaskedShape ' ' | Should -Be '(blank)'
        }
    }
}
