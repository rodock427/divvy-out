# M9: a second vendor works with a new profile + a new rule file and no core change. Fake data only.
BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    $repo = Split-Path -Parent $PSScriptRoot
    $s = @{
        Profile = Join-Path $repo 'config/profiles/example-vendor_profile_2027.psd1'; Quote = Join-Path $repo 'config/quotes/example-vendor_quote_2027.psd1'
        Usage = Join-Path $repo 'samples/example-vendor/example-vendor_usage_2027.csv'; Ad = Join-Path $repo 'samples/example-vendor/hr-directory.csv'
        OutputRoot = Join-Path $TestDrive 'ev'
    }
    $script:R = Invoke-DivvyOut @s -PassThru 6>$null
    $script:ByRow = @{}; foreach ($x in $R.Rows) { $ByRow[$x.RowNumber] = $x }
}

Describe 'Second vendor: ExampleVendor (spec M9)' {
    It 'keeps vendor logic out of the core' {
        foreach ($f in Get-ChildItem (Join-Path $repo 'src/DivvyOut') -Recurse -File | Where-Object { $_.DirectoryName -notmatch '[\\/]Rules$' }) {
            Get-Content $f.FullName -Raw | Should -Not -Match 'ExampleVendor' -Because $f.Name
        }
    }

    It 'reads a different layout and an HR directory (employee numbers, Status = Active)' {
        $ByRow[2].User.Id | Should -Be 'E111'
        $ByRow[3].User.Id | Should -Be 'E111'           # upper case + trailing space, normalized
        $ByRow[5].Reason | Should -Be 'Disabled'        # Terminated
        $ByRow[11].Reason | Should -Be 'NoMatch'
        $ByRow[9].Reason | Should -Be 'ManagerNotFound' # manager E999 not in the directory
        $ByRow[2].ManagerId | Should -Be 'E110'
        $ByRow[2].CostCenter | Should -Be 'CC 110 - Build'
    }

    It 'uses its own math: one share per person, split over that person''s rows' {
        $ByRow[2].SeatCharge | Should -Be 125
        $ByRow[3].SeatCharge | Should -Be 125
        foreach ($n in 4, 6, 7) { $ByRow[$n].SeatCharge | Should -Be 250 }
        foreach ($n in 8, 9, 10) { $ByRow[$n].SeatCharge | Should -Be 30 }
        $ByRow[5].RowTotal | Should -Be 0
    }

    It 'reconciles and writes the full output set' {
        $R.Reconciliation.QuoteTotal | Should -Be 1090
        $R.Reconciliation.Allocated | Should -Be 1090
        $R.Status | Should -Be 'DRAFT'
        foreach ($f in 'summary-by-manager.csv', 'not-found.csv', 'exceptions.csv', 'audit.csv', 'dashboard.html', 'manifest.json', 'statements/Bram Fakename.xlsx', 'statements/rollup/Ada Fakename.xlsx') {
            Test-Path (Join-Path $R.OutputDir $f) | Should -BeTrue -Because $f
        }
    }

    It 'rejects an access text that this vendor does not know' {
        $p = Import-PowerShellDataFile (Join-Path $repo 'config/profiles/example-vendor_profile_2027.psd1')
        $p.Usage.AccessOptionValues = @{ Token = 'Named User' }
        $x = Test-DivvyOutInput -Profile $p -Quote (Join-Path $repo 'config/quotes/example-vendor_quote_2027.psd1') -Usage (Join-Path $repo 'samples/example-vendor/example-vendor_usage_2027.csv') -Ad (Join-Path $repo 'samples/example-vendor/hr-directory.csv') 6>$null
        ($x.Issues | Where-Object Code -eq 'ProfileInvalid').Message | Should -Match "not an access kind of vendor 'ExampleVendor'"
    }
}
