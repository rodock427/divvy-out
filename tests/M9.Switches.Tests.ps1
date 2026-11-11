# M9: output switches. Fake data only.
BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    $script:Ad = @(New-TestAdUser boss; New-TestAdUser lead -Manager boss; New-TestAdUser ann -Manager lead)
    $script:Usage = @(New-TestUsageRow 'ann@test.example' 'Off A' 'Seats')
    $script:Quote = @{ Period = '2027'; Currency = 'USD'; SeatPrices = @{ 'Off A' = 10 } }
}

Describe 'Output switches (-Skip)' {
    It 'writes everything by default' {
        $s = New-TestRun -AdUsers $Ad -UsageRows $Usage -Quote $Quote -Name 'all'
        $r = Invoke-DivvyOut @s -PassThru 6>$null
        (Get-ChildItem $r.OutputDir).Name | Sort-Object | Should -Be @('audit.csv', 'dashboard.html', 'diagnostics.txt', 'exceptions.csv', 'inputs', 'manifest.json', 'not-found.csv', 'overrides-template.csv', 'statements', 'summary-by-manager.csv')
        Test-Path (Join-Path $r.OutputDir 'statements/rollup/Person boss.xlsx') | Should -BeTrue
    }

    It 'leaves out what -Skip names, keeps diagnostics and manifest, and records the choice' {
        $s = New-TestRun -AdUsers $Ad -UsageRows $Usage -Quote $Quote -Name 'skip'
        $r = Invoke-DivvyOut @s -Skip Statements, Dashboard, Inputs, Audit -PassThru 6>$null
        (Get-ChildItem $r.OutputDir).Name | Sort-Object | Should -Be @('diagnostics.txt', 'exceptions.csv', 'manifest.json', 'not-found.csv', 'overrides-template.csv', 'statements', 'summary-by-manager.csv')
        (Get-ChildItem (Join-Path $r.OutputDir 'statements') -Filter *.xlsx) | Should -BeNullOrEmpty
        Test-Path (Join-Path $r.OutputDir 'statements/rollup/Person boss.xlsx') | Should -BeTrue
        (Get-Content (Join-Path $r.OutputDir 'manifest.json') -Raw | ConvertFrom-Json).Options.Skip | Should -Be @('Audit', 'Dashboard', 'Inputs', 'Statements')
    }

    It 'can skip roll-ups but keep statements' {
        $s = New-TestRun -AdUsers $Ad -UsageRows $Usage -Quote $Quote -Name 'norollup'
        $r = Invoke-DivvyOut @s -Skip Rollups -PassThru 6>$null
        Test-Path (Join-Path $r.OutputDir 'statements/Person lead.xlsx') | Should -BeTrue
        Test-Path (Join-Path $r.OutputDir 'statements/rollup') | Should -BeFalse
    }

    It 'rejects an unknown output name' {
        $s = New-TestRun -AdUsers $Ad -UsageRows $Usage -Quote $Quote -Name 'bad'
        { Invoke-DivvyOut @s -Skip Diagnostics 6>$null } | Should -Throw '*does not belong to the set*'
    }
}
