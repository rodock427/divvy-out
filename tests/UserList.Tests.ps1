# UserList: a report that is only a list of users of one product (DECISIONS D86). Fake data only.
# Sample: 40 live people, one listed twice, one disabled, one not in the directory. Quote 12000.00.
#   12000.00 / 40 people = 300.00 each. The extra row of the person listed twice is not charged.
BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    $repo = Split-Path -Parent $PSScriptRoot
    $script:S = @{
        Profile = Join-Path $repo 'config/profiles/userlist_profile_2027.psd1'; Quote = Join-Path $repo 'config/quotes/userlist_quote_2027.psd1'
        Usage = Join-Path $repo 'samples/userlist/userlist_usage_2027.csv'; Ad = Join-Path $repo 'samples/ad-snapshot.csv'
    }
    $script:R = Invoke-DivvyOut @S -OutputRoot (Join-Path $TestDrive 'ul') -PassThru 6>$null
    function Check { param([hashtable]$P) $s = $S.Clone(); $s.Profile = $P; Test-DivvyOutInput @s 6>$null }
    function Get-UlProfile { Import-PowerShellDataFile $S.Profile }
}

Describe 'User-only list (UserList)' {
    It 'charges an equal share per person and reconciles' {
        $R.Status | Should -Be 'FINAL'
        $R.Reconciliation.Allocated | Should -Be 12000.00
        $charged = @($R.Rows | Where-Object State -ne 'NotHere')
        $charged.Count | Should -Be 40
        foreach ($x in $charged) { $x.SeatCharge | Should -Be 300.00 }
        @($R.Rows | ForEach-Object Package | Select-Object -Unique) | Should -Be @('Product')
    }

    It 'charges a person listed twice once, and skips the disabled and the unknown' {
        ($R.Rows | Where-Object Reason -eq 'Duplicate').RowNumber | Should -Be 42
        ($R.Rows | Where-Object Reason -eq 'Disabled').RowNumber | Should -Be 43
        ($R.Rows | Where-Object Reason -eq 'NoMatch').RowNumber | Should -Be 44
    }

    It 'shows the fixed values in diagnostics' {
        $t = Get-Content (Join-Path $R.OutputDir 'diagnostics.txt') -Raw
        $t | Should -Match "Package\s+=  'Product' \(fixed, every row\)"
    }

    It 'rejects bad FixedValues' -ForEach @(
        @{ Case = 'also a column'; Set = { param($p) $p.Usage.Columns.Package = 'User Email' }; Msg = "'Package' is in both Usage.Columns and Usage.FixedValues" }
        @{ Case = 'empty'; Set = { param($p) $p.Usage.FixedValues.Package = ' ' }; Msg = 'Usage.FixedValues.Package is empty' }
        @{ Case = 'missing'; Set = { param($p) $p.Usage.FixedValues.Remove('Package') }; Msg = "'Package' is used but not mapped" }
        @{ Case = 'not a table'; Set = { param($p) $p.Usage.FixedValues = 'Product' }; Msg = 'Usage.FixedValues must be a @{ } table' }
    ) {
        $p = Get-UlProfile; & $Set $p
        @((Check $p).Issues | Where-Object { $_.Code -eq 'ProfileInvalid' -and $_.Message -like "*$Msg*" }).Count | Should -Be 1 -Because $Case
    }

    It 'stops when the fixed product name is not in the quote' {
        $p = Get-UlProfile; $p.Usage.FixedValues.Package = 'Other Product'
        @((Check $p).Issues | Where-Object Code -eq 'UnpricedOffering').Count | Should -Be 1
    }
}
