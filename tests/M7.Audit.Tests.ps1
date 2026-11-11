# M7: audit trail, manifest, input copies, rebuild from the copies (spec 6, 9, 9.4, NFR-3). Fake data only.
BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    $repo = Split-Path -Parent $PSScriptRoot
    $script:Splat = @{
        Profile = Join-Path $repo 'config/profiles/autodesk_profile_2027.psd1'; Quote = Join-Path $repo 'config/quotes/autodesk_quote_2027.psd1'
        Usage = Join-Path $repo 'samples/autodesk_usage_2027.xlsx'; Ad = Join-Path $repo 'samples/ad-snapshot.csv'
        Overrides = Join-Path $repo 'samples/overrides.csv'; OutputRoot = Join-Path $TestDrive 'first'
    }
    $script:R = Invoke-DivvyOut @Splat -PassThru 6>$null
    $script:Audit = @(Import-Csv (Join-Path $R.OutputDir 'audit.csv'))
    $script:Manifest = Get-Content (Join-Path $R.OutputDir 'manifest.json') -Raw | ConvertFrom-Json
    $script:Money = { param([string]$s) if ($s) { [decimal]::Parse($s, [cultureinfo]::InvariantCulture) } else { [decimal]0 } }
}

Describe 'Audit trail (spec 9.4)' {
    It 'has one row per usage row' {
        $Audit.Count | Should -Be $R.Rows.Count
        $Audit.Count | Should -Be 371
        ($Audit.Row | ForEach-Object { [int]$_ }) | Should -Be @($R.Rows | ForEach-Object RowNumber)
    }

    It 'has the spec columns' {
        $cols = $Audit[0].PSObject.Properties.Name
        foreach ($c in 'Email', 'UserKey', 'Team', 'State', 'Reason', 'DirectoryId', 'MatchRule', 'MatchValue', 'DirectoryValue',
            'Offering', 'Access', 'OfferingPrice', 'PoolSeatRows', 'SeatCharge', 'Tokens', 'TokenRate', 'TokenCharge', 'RowTotal',
            'ManagerDirectory', 'ManagerFinal', 'CostCenterRaw', 'CostCenterFinal', 'Override', 'OverrideReason', 'OverrideBy', 'OverrideDate',
            'RunId', 'RunTimestamp', 'ToolVersion') { $cols | Should -Contain $c }
    }

    It 'carries every usage column (usage_) and every Ad.Attributes value (ad_)' {
        $cols = $Audit[0].PSObject.Properties.Name
        foreach ($h in $R.Usage.Headers) { $cols | Should -Contain "usage_$h" }
        foreach ($a in $R.Config.Ad.Attributes) { $cols | Should -Contain "ad_$a" }
        $row = $Audit | Where-Object { $_.State -eq 'Charged' } | Select-Object -First 1
        $row.ad_objectGUID | Should -Be $row.DirectoryId
        $row.'usage_Source Email' | Should -Be $row.Email
    }

    It 'traces every report number: the audit adds up to the summary, per manager (NFR-3)' {
        $sum = @(Import-Csv (Join-Path $R.OutputDir 'summary-by-manager.csv'))
        foreach ($line in $sum) {
            $rows = if ($line.Manager -eq 'NO OWNER') { $Audit | Where-Object State -eq 'NeedsOwner' }
            elseif ($line.ManagerId) { $Audit | Where-Object { $_.State -eq 'Charged' -and $_.ManagerFinalId -eq $line.ManagerId } }
            else { $Audit | Where-Object { $_.State -eq 'Charged' -and -not $_.ManagerFinalId -and $_.ManagerFinal -eq $line.Manager } }
            (Get-DecimalSum ($rows | ForEach-Object { & $Money $_.RowTotal })) | Should -Be (& $Money $line.Total) -Because $line.Manager
        }
        (Get-DecimalSum ($Audit | ForEach-Object { & $Money $_.RowTotal })) | Should -Be $R.Reconciliation.QuoteTotal
    }

    It 'rebuilds each charge from the row: seat = price split, token = tokens x rate (to the cent)' {
        foreach ($a in $Audit | Where-Object State -ne 'NotHere') {
            if ($a.Access -eq 'Seat') { [Math]::Abs((& $Money $a.SeatCharge) - (& $Money $a.OfferingPrice) / [int]$a.PoolSeatRows) | Should -BeLessThan 0.01 }
            else { [Math]::Abs((& $Money $a.TokenCharge) - (& $Money $a.Tokens) * (& $Money $a.TokenRate)) | Should -BeLessThan 0.01 }
        }
    }

    It 'records overrides and the rule that matched' {
        $ov = @($Audit | Where-Object Override -eq 'Y')
        $ov.Count | Should -Be @($R.Rows | Where-Object Override).Count
        $ov | ForEach-Object { $_.OverrideReason | Should -Not -BeNullOrEmpty }
        @($Audit | Where-Object MatchStatus -eq 'Linked' | ForEach-Object MatchRule | Select-Object -Unique) | Should -Be @('Override')
        @($Audit | Where-Object { $_.MatchStatus -eq 'Matched' -and $_.MatchRule -eq '3' }).Count | Should -BeGreaterThan 0
    }
}

Describe 'Manifest and input copies (spec 6, 9)' {
    It 'has the run ID, tool version, status, and reconciliation' {
        $Manifest.RunId | Should -Be $R.RunId
        $Manifest.ToolVersion | Should -Be $R.ToolVersion
        $Manifest.Status | Should -Be $R.Status
        $Manifest.Reconciliation.Balanced | Should -BeTrue
        $Manifest.Reconciliation.Allocated | Should -Be $R.Reconciliation.Allocated.ToString('0.00', [cultureinfo]::InvariantCulture)
        $Manifest.MatchReport.Lines[0] | Should -Be 'Usage rows: 371'
    }

    It 'hashes every input and counts rows' {
        foreach ($role in 'Profile', 'Quote', 'Usage', 'Directory', 'Overrides') {
            $src = @{ Profile = $Splat.Profile; Quote = $Splat.Quote; Usage = $Splat.Usage; Directory = $Splat.Ad; Overrides = $Splat.Overrides }[$role]
            $Manifest.Inputs.$role.Sha256 | Should -Be (Get-FileHash $src -Algorithm SHA256).Hash -Because $role
        }
        $Manifest.Inputs.Usage.Rows | Should -Be 371
        $Manifest.Inputs.Directory.Rows | Should -Be 326
    }

    It 'copies every input into inputs/ unchanged' {
        foreach ($role in 'Profile', 'Quote', 'Usage', 'Directory', 'Overrides') {
            $copy = Join-Path $R.OutputDir $Manifest.Inputs.$role.Copy
            (Get-FileHash $copy -Algorithm SHA256).Hash | Should -Be $Manifest.Inputs.$role.Sha256
        }
    }

    It 'gives the same numbers when run again from the copies' {
        $in = Join-Path $R.OutputDir 'inputs'
        $again = Invoke-DivvyOut -Profile (Join-Path $in 'autodesk_profile_2027.psd1') -Quote (Join-Path $in 'autodesk_quote_2027.psd1') -Usage (Join-Path $in 'autodesk_usage_2027.xlsx') `
            -Ad (Join-Path $in 'ad-snapshot.csv') -Overrides (Join-Path $in 'overrides.csv') -OutputRoot (Join-Path $TestDrive 'again') -PassThru 6>$null
        Get-Content (Join-Path $again.OutputDir 'summary-by-manager.csv') -Raw | Should -Be (Get-Content (Join-Path $R.OutputDir 'summary-by-manager.csv') -Raw)
        $a2 = @(Import-Csv (Join-Path $again.OutputDir 'audit.csv'))
        ($a2 | ForEach-Object { "$($_.Row):$($_.RowTotal):$($_.ManagerFinalId)" }) -join ',' | Should -Be (($Audit | ForEach-Object { "$($_.Row):$($_.RowTotal):$($_.ManagerFinalId)" }) -join ',')
    }

    It 'gives a clashing input name a role prefix' {
        $dir = Join-Path $TestDrive 'clash'; New-Item -ItemType Directory $dir | Out-Null
        New-Item -ItemType Directory (Join-Path $dir 'a'), (Join-Path $dir 'b') | Out-Null
        $ad = @(New-TestAdUser boss; New-TestAdUser ann -Manager boss)
        $ad | Export-Csv (Join-Path $dir 'a/data.csv') -Encoding utf8BOM
        @(New-TestUsageRow 'ann@test.example' 'Off A' 'Seats') | Export-Csv (Join-Path $dir 'b/data.csv') -Encoding utf8BOM
        $x = Invoke-DivvyOut -Profile (Get-TestProfile) -Quote @{ Period = '2027'; Currency = 'USD'; SeatPrices = @{ 'Off A' = 10 } } `
            -Usage (Join-Path $dir 'b/data.csv') -Ad (Join-Path $dir 'a/data.csv') -OutputRoot (Join-Path $dir 'out') -PassThru 6>$null
        (Get-ChildItem (Join-Path $x.OutputDir 'inputs')).Name | Sort-Object | Should -Be @('data.csv', 'directory-data.csv')
        $m = Get-Content (Join-Path $x.OutputDir 'manifest.json') -Raw | ConvertFrom-Json
        $m.Inputs.Profile.Name | Should -Be '(in memory)'
        $m.Inputs.Profile.Sha256 | Should -BeNullOrEmpty
    }
}
