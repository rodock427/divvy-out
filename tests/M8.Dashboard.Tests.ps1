# M8: owner dashboard (spec 9.6, 9.7, NFR-9). Fake data only.
BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    function Read-Dashboard {
        param([string]$Dir)
        $html = Get-Content (Join-Path $Dir 'dashboard.html') -Raw
        $m = [regex]::Match($html, '<script id="divvy-data" type="application/json">(.*?)</script>', 'Singleline')
        [pscustomobject]@{ Html = $html; Data = $m.Groups[1].Value | ConvertFrom-Json }
    }
    $repo = Split-Path -Parent $PSScriptRoot
    $s = @{
        Profile = Join-Path $repo 'config/profiles/autodesk.psd1'; Quote = Join-Path $repo 'config/quotes/2027-autodesk.psd1'
        Usage = Join-Path $repo 'samples/usage.csv'; Ad = Join-Path $repo 'samples/ad-snapshot.csv'
        Overrides = Join-Path $repo 'samples/overrides.csv'; OutputRoot = Join-Path $TestDrive 'dash'
    }
    $script:R = Invoke-DivvyOut @s -PassThru 6>$null
    $script:Dash = Read-Dashboard $R.OutputDir
    $script:Money = { param([string]$x) [decimal]::Parse($x, [cultureinfo]::InvariantCulture) }
}

Describe 'Dashboard is self-contained (NFR-9)' {
    It 'makes no external calls and loads nothing from the internet' {
        $h = $Dash.Html
        $h | Should -Not -Match 'https?:'
        $h | Should -Not -Match '//[a-z0-9.-]+\.[a-z]{2,}/'
        $h | Should -Not -Match '<link\b'
        $h | Should -Not -Match '\ssrc\s*='
        $h | Should -Not -Match '@import|url\('
        $h | Should -Not -Match '\bfetch\(|XMLHttpRequest|WebSocket|sendBeacon|import\('
    }

    It 'follows the system light/dark setting and has a print stylesheet that hides the search box' {
        $Dash.Html | Should -Match 'prefers-color-scheme: dark'
        $Dash.Html | Should -Match '@media print \{\s*\.controls, #search'
        $Dash.Html | Should -Match 'tabular-nums'
        $Dash.Html | Should -Match 'repeat\(2, minmax'
    }

    It 'cannot be broken out of by a value that closes the script tag' {
        $ad = @(New-TestAdUser boss; New-TestAdUser ann -Manager boss)
        $ad[1].displayName = '</script><script>alert(1)</script>'
        $x = New-TestRun -AdUsers $ad -UsageRows @(New-TestUsageRow 'ann@test.example' 'Off A' 'Seats') -Quote @{ Period = '2027'; Currency = 'USD'; SeatPrices = @{ 'Off A' = 10 } } -Name 'xss'
        $r = Invoke-DivvyOut @x -PassThru 6>$null
        $d = Read-Dashboard $r.OutputDir
        ([regex]::Matches($d.Html, '</script>')).Count | Should -Be 2
        $d.Data.rows[0].person | Should -Be '</script><script>alert(1)</script>'
    }
}

Describe 'Dashboard data (spec 9.6)' {
    It 'shows the run status and reasons' {
        $Dash.Data.run.status | Should -Be $R.Status
        @($Dash.Data.run.reasons) | Should -Be @($R.DraftReasons)
    }

    It 'reconciles: tiles, pools, split, and managers all match the run' {
        $d = $Dash.Data
        (& $Money $d.rec.allocated) | Should -Be $R.Reconciliation.Allocated
        (& $Money $d.rec.quote) | Should -Be $R.Reconciliation.QuoteTotal
        (& $Money $d.tiles.allocated) | Should -Be $R.Reconciliation.Allocated
        ((& $Money $d.split.seat) + (& $Money $d.split.token)) | Should -Be $R.Reconciliation.Allocated
        $direct = Get-DecimalSum ($d.managers | ForEach-Object { & $Money $_.direct })
        $noOwner = Get-DecimalSum ($R.Rows | Where-Object State -eq 'NeedsOwner' | ForEach-Object RowTotal)
        ($direct + $noOwner) | Should -Be $R.Reconciliation.Allocated
        $off = Get-DecimalSum ($d.offerings | ForEach-Object { & $Money $_.total })
        $off | Should -Be $R.Reconciliation.Allocated
    }

    It 'has every usage row, and every list points at real rows' {
        @($Dash.Data.rows).Count | Should -Be $R.Rows.Count
        foreach ($m in $Dash.Data.managers) { foreach ($i in @($m.rows)) { $i | Should -BeLessThan $R.Rows.Count } }
        foreach ($a in $Dash.Data.attention) { @($a.rows).Count | Should -BeLessOrEqual $a.count }
    }

    It 'lists the attention items: not found, need an owner, fallback rule, loop' {
        $att = @{}; foreach ($a in $Dash.Data.attention) { $att[$a.label] = $a.count }
        $att['Not found or not here (not charged)'] | Should -Be @($R.Rows | Where-Object State -eq 'NotHere').Count
        $att['Rows that need an owner'] | Should -Be 13
        $att['Rows matched by a fallback rule'] | Should -Be 15
        $att.Keys | Should -Contain 'Rows under a manager loop (left out of roll-ups)'
    }

    It 'shows cost centers only when the profile defines them' {
        @($Dash.Data.costCenters).Count | Should -BeGreaterThan 0
        $x = New-TestRun -AdUsers @(New-TestAdUser boss; New-TestAdUser ann -Manager boss) -UsageRows @(New-TestUsageRow 'ann@test.example' 'Off A' 'Seats') -Quote @{ Period = '2027'; Currency = 'USD'; SeatPrices = @{ 'Off A' = 10 } } -Name 'nocc'
        $r = Invoke-DivvyOut @x -PassThru 6>$null
        (Read-Dashboard $r.OutputDir).Data.costCenters | Should -BeNullOrEmpty
    }

    It 'keeps lists as JSON arrays when they have one item' {
        $x = New-TestRun -AdUsers @(New-TestAdUser boss; New-TestAdUser ann -Manager boss) -UsageRows @(New-TestUsageRow 'ann@test.example' 'Off A' 'Tokens' 5) -Quote @{ Period = '2027'; Currency = 'USD'; SeatPrices = @{}; TokenPoolPrice = 10 } -Name 'one'
        $r = Invoke-DivvyOut @x -PassThru 6>$null
        $raw = (Read-Dashboard $r.OutputDir).Html
        $raw | Should -Match '"managers":\[\{'
        $raw | Should -Match '"rows":\[0\]'
        $raw | Should -Match '"topTokens":\[\{'
        $raw | Should -Match '"offerings":\[\{'
    }
}
