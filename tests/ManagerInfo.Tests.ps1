# Ad.ManagerInfo (DECISIONS D83): extra manager columns in the summary, statements, roll-ups, dashboard. Fake data only.
BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    function With { param($User, [string]$Region, [string]$Site) $User | Add-Member region $Region -PassThru | Add-Member site $Site -PassThru }
    function Get-InfoProfile {
        $p = Get-TestProfile
        $p.Ad.Attributes = @($p.Ad.Attributes) + 'region', 'site'
        $p.Ad.ManagerInfo = @(@{ Label = 'Region'; Attribute = 'region' }, @{ Label = 'Site'; Attribute = 'site' })
        $p
    }
    function Get-Cell { param([string]$Path, [string]$Sheet, [int]$R, [int]$C)
        $pkg = Open-ExcelPackage -Path $Path
        try { [string]$pkg.Workbook.Worksheets[$Sheet].Cells[$R, $C].Value } finally { Close-ExcelPackage $pkg -NoSave }
    }
    $script:Ad = @(
        With (New-TestAdUser boss) 'North' 'HQ'
        With (New-TestAdUser lead -Manager boss) '' 'Annex'
        With (New-TestAdUser ann -Manager lead) 'South' 'Home'
        With (New-TestAdUser bob -Manager lead) 'South' 'Home'
        With (New-TestAdUser orphan) 'West' ''
    )
    $script:Usage = @('ann', 'bob', 'lead', 'orphan' | ForEach-Object { New-TestUsageRow "$_@test.example" 'Off A' 'Seats' })
    $script:Quote = @{ Period = '2027'; Currency = 'USD'; SeatPrices = @{ 'Off A' = '400.00' } }
    $s = New-TestRun -AdUsers $Ad -UsageRows $Usage -Quote $Quote -TestProfile (Get-InfoProfile) -Name 'info'
    $script:R = Invoke-DivvyOut @s -PassThru 6>$null
    $script:Dir = (Get-RunFolder $s).FullName
}

Describe 'Ad.ManagerInfo' {
    It 'adds the labels after ManagerId in summary-by-manager.csv, from each manager''s own record' {
        $header = (Get-Content (Join-Path $Dir 'summary-by-manager.csv') -TotalCount 1).TrimStart([char]0xFEFF)
        $header | Should -Be '"Status","Manager","ManagerId","Region","Site","People","Rows","SeatTotal","TokenTotal","Total"'
        $sum = @(Import-Csv (Join-Path $Dir 'summary-by-manager.csv'))
        $boss = $sum | Where-Object Manager -eq 'Person boss'
        $boss.Region | Should -Be 'North'; $boss.Site | Should -Be 'HQ'
        $lead = $sum | Where-Object Manager -eq 'Person lead'
        $lead.Region | Should -Be ''; $lead.Site | Should -Be 'Annex'
        $none = $sum | Where-Object Manager -eq 'NO OWNER'
        $none.Region | Should -Be ''; $none.Site | Should -Be ''
    }

    It 'shows a line under the subtitle on the statement, leaving out blank values' {
        $f = Get-ChildItem (Join-Path $Dir 'statements') -Filter 'Person lead*.xlsx'
        Get-Cell $f.FullName 'Statement' 3 1 | Should -Be 'Site: Annex'
        $f = Get-ChildItem (Join-Path $Dir 'statements') -Filter 'Person boss*.xlsx'
        Get-Cell $f.FullName 'Statement' 3 1 | Should -Be 'Region: North · Site: HQ'
    }

    It 'adds a column per label to the roll-up table and a line on each sheet' {
        $f = Get-ChildItem (Join-Path $Dir 'statements/rollup') -Filter 'Person boss*.xlsx'
        Get-Cell $f.FullName 'Summary' 3 1 | Should -Be 'Region: North · Site: HQ'
        $pkg = Open-ExcelPackage -Path $f.FullName
        try {
            $ws = $pkg.Workbook.Worksheets['Summary']
            $head = @(1..$ws.Dimension.End.Row | Where-Object { [string]$ws.Cells[$_, 1].Value -eq 'Manager' })[0]
            @(5, 6 | ForEach-Object { [string]$ws.Cells[$head, $_].Value }) | Should -Be @('Region', 'Site')
            @(5, 6 | ForEach-Object { [string]$ws.Cells[($head + 2), $_].Value }) | Should -Be @('', 'Annex')   # lead, under boss
        }
        finally { Close-ExcelPackage $pkg -NoSave }
    }

    It 'puts the labels and values in the dashboard data' {
        $html = Get-Content (Join-Path $Dir 'dashboard.html') -Raw
        $data = [regex]::Match($html, '<script id="divvy-data" type="application/json">(.*?)</script>', 'Singleline').Groups[1].Value | ConvertFrom-Json
        $data.managerInfo | Should -Be @('Region', 'Site')
        ($data.managers | Where-Object name -eq 'Person boss').info | Should -Be @('North', 'HQ')
        ($data.managers | Where-Object name -eq 'Person lead').info | Should -Be @('', 'Annex')
    }

    It 'writes blank counts, never values, to diagnostics.txt' {
        $d = Get-Content (Join-Path $Dir 'diagnostics.txt') -Raw
        $d | Should -Match "Manager info 'Region' = region: blank for 1 of 2 managers"
        $d | Should -Match "Manager info 'Site' = site: blank for 0 of 2 managers"
        $d | Should -Not -Match 'North|Annex'
    }

    It 'stops when the snapshot lacks the attribute, or a label clashes' {
        $p = Get-InfoProfile; $p.Ad.ManagerInfo = @(@{ Label = 'Region'; Attribute = 'nothere' })
        $s = New-TestRun -AdUsers $Ad -UsageRows $Usage -Quote $Quote -TestProfile $p -Name 'missing'
        $s.Remove('OutputRoot'); $x = Test-DivvyOutInput @s 6>$null
        ($x.Issues | Where-Object Code -eq 'MissingDirectoryColumn').Message | Should -Match "'nothere' \(used by Ad.ManagerInfo\)"
        $p = Get-InfoProfile; $p.Ad.ManagerInfo = @(@{ Label = 'Total'; Attribute = 'region' })
        $s = New-TestRun -AdUsers $Ad -UsageRows $Usage -Quote $Quote -TestProfile $p -Name 'clash'
        $s.Remove('OutputRoot'); $x = Test-DivvyOutInput @s 6>$null
        ($x.Issues | Where-Object Code -eq 'ProfileInvalid').Message | Should -Match "label 'Total'"
    }

    It 'changes nothing when the profile has no ManagerInfo' {
        $s = New-TestRun -AdUsers $Ad -UsageRows $Usage -Quote $Quote -Name 'plain'
        $x = Invoke-DivvyOut @s -PassThru 6>$null
        $header = (Get-Content (Join-Path (Get-RunFolder $s).FullName 'summary-by-manager.csv') -TotalCount 1).TrimStart([char]0xFEFF)
        $header | Should -Be '"Status","Manager","ManagerId","People","Rows","SeatTotal","TokenTotal","Total"'
        $x.Reconciliation.Allocated | Should -Be $R.Reconciliation.Allocated
    }
}
