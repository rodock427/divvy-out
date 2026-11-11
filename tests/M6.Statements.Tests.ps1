# M6: statements, NO OWNER, org tree, roll-ups (spec 8, 9.1, 9.7). Fake data only.
BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    function Seat { param([string]$Who, [string]$Offering = 'Off A') New-TestUsageRow "$Who@test.example" $Offering 'Seats' }
    function Tok { param([string]$Who, $Tokens) New-TestUsageRow "$Who@test.example" 'Off A' 'Tokens' $Tokens }
    function Run {
        param([object[]]$AdUsers, [object[]]$UsageRows, [hashtable]$TestProfile = (Get-TestProfile), [object[]]$Overrides, [string]$Name = 'st', [hashtable]$Quote = $script:Quote)
        $s = New-TestRun -AdUsers $AdUsers -UsageRows $UsageRows -Quote $Quote -TestProfile $TestProfile -Overrides $Overrides -Name $Name
        $r = Invoke-DivvyOut @s -PassThru 6>$null
        $r
    }
    # Reads a workbook: sheet name -> list of row texts (cells joined with |), plus the package facts we check.
    function Read-Xl {
        param([string]$Path)
        $pkg = Open-ExcelPackage -Path $Path
        try {
            $out = [ordered]@{}
            foreach ($ws in $pkg.Workbook.Worksheets) {
                $rows = @()
                if ($ws.Dimension) {
                    for ($r = 1; $r -le $ws.Dimension.End.Row; $r++) {
                        $rows += , (@(for ($c = 1; $c -le $ws.Dimension.End.Column; $c++) { [string]$ws.Cells[$r, $c].Value }) -join '|').TrimEnd('|')
                    }
                }
                $out[$ws.Name] = [pscustomobject]@{ Rows = $rows; Grid = $ws.View.ShowGridLines; Ws = $null }
            }
            $first = $pkg.Workbook.Worksheets[1]
            $out['_big'] = $null
            $out
        }
        finally { Close-ExcelPackage $pkg -NoSave }
    }
    function Get-Cell { param([string]$Path, [string]$Sheet, [int]$R, [int]$C, [string]$What = 'Value')
        $pkg = Open-ExcelPackage -Path $Path
        try { $cell = $pkg.Workbook.Worksheets[$Sheet].Cells[$R, $C]; if ($What -eq 'Format') { $cell.Style.Numberformat.Format } else { $cell.Value } }
        finally { Close-ExcelPackage $pkg -NoSave }
    }
    $script:Quote = @{ Period = '2027'; Currency = 'USD'; SeatPrices = @{ 'Off A' = '1000.00' }; TokenPoolPrice = '300.00' }
    # ceo -> vp -> dirx (disabled) -> mgr -> a, b
    #        vp -> mgr2 -> c ; ceo -> d ; loop l1 <-> l2, e under l1 ; orphan has no manager
    $script:Org = @(
        New-TestAdUser ceo
        New-TestAdUser vp -Manager ceo
        New-TestAdUser dirx -Manager vp -Disabled
        New-TestAdUser mgr -Manager dirx
        New-TestAdUser mgr2 -Manager vp
        New-TestAdUser a -Manager mgr
        New-TestAdUser b -Manager mgr
        New-TestAdUser c -Manager mgr2
        New-TestAdUser d -Manager ceo
        New-TestAdUser l1 -Manager l2
        New-TestAdUser l2 -Manager l1
        New-TestAdUser e -Manager l1
        New-TestAdUser orphan
    )
    $script:Usage = @(Seat a; Seat b; Tok b 100; Seat c; Tok c 200; Seat d; Seat e; Seat orphan)
}

Describe 'File and sheet names' {
    It 'follows Windows file name rules' {
        InModuleScope DivvyOut {
            ConvertTo-SafeFileName 'Ann: Lee?' | Should -Be 'Ann_ Lee_'
            ConvertTo-SafeFileName 'a/b\c<d>e|f*"g' | Should -Be 'a_b_c_d_e_f__g'
            ConvertTo-SafeFileName 'CON' | Should -Be '_CON'
            ConvertTo-SafeFileName 'lpt1.txt' | Should -Be '_lpt1.txt'
            ConvertTo-SafeFileName 'Name. . ' | Should -Be 'Name'
            (ConvertTo-SafeFileName ('x' * 300)).Length | Should -Be 100
            ConvertTo-SafeFileName '...' | Should -Be '_'
        }
    }

    It 'adds a short ID when two managers share a name (ignoring case)' {
        InModuleScope DivvyOut {
            $n = Get-UniqueFileName @([pscustomobject]@{ Key = 'id:1'; Name = 'Ann Lee' }, [pscustomobject]@{ Key = 'id:2'; Name = 'ANN LEE' }, [pscustomobject]@{ Key = 'id:3'; Name = 'Bo' })
            $n['id:1'] | Should -Match '^Ann Lee \([0-9a-f]{6}\)$'
            $n['id:2'] | Should -Match '^ANN LEE \([0-9a-f]{6}\)$'
            $n['id:1'] | Should -Not -Be $n['id:2']
            $n['id:3'] | Should -Be 'Bo'
        }
    }

    It 'follows Excel sheet name rules' {
        InModuleScope DivvyOut {
            $used = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $a = ConvertTo-SheetName ('A very long manager name that goes on' ) $used 'k1'
            $a.Length | Should -BeLessOrEqual 31
            ConvertTo-SheetName "'[Q1]: a*b?c/d\e'" $used 'k2' | Should -Be '_Q1__ a_b_c_d_e'
            $b = ConvertTo-SheetName 'a very long manager name that goes on' $used 'k3'
            $b | Should -Not -Be $a
            $b.Length | Should -BeLessOrEqual 31
        }
    }
}

Describe 'Org tree and roll-up checks (spec 8)' {
    BeforeAll { $r = Run $Org $Usage -Name 'tree'; $t = $r.OrgTree }

    It 'skips a disabled manager: mgr attaches to vp' {
        $t.Nodes['id:id-mgr'].Parent.Key | Should -Be 'id:id-vp'
        $t.Nodes.Contains('id:id-dirx') | Should -BeFalse
    }

    It 'warns about the loop and leaves its members out of roll-ups' {
        $t.Loop.Contains('id:id-l1') | Should -BeTrue
        $t.Nodes['id:id-l1'].Parent | Should -BeNullOrEmpty
        $t.Nodes['id:id-l1'].InLoop | Should -BeTrue
        @($r.Issues | Where-Object Code -eq 'ManagerLoop').Count | Should -Be 1
    }

    It 'check 1: the direct charges of every manager (and NO OWNER) add up to the grand total' {
        InModuleScope DivvyOut -Parameters @{ R = $r } {
            $sum = [decimal]0; foreach ($g in Get-ManagerSummary $R) { $sum += $g.Total }
            $sum | Should -Be $R.Reconciliation.Allocated
            $sum | Should -Be 1300
        }
    }

    It 'check 2: a roll-up total equals the direct charges in its subtree' {
        InModuleScope DivvyOut -Parameters @{ T = $t } {
            foreach ($n in $T.Nodes.Values) {
                $sub = [decimal]0; foreach ($s in Get-SubtreeNodes $n) { $sub += $s.Node.DirectTotal }
                $n.TeamTotal | Should -Be $sub
            }
            $T.Nodes['id:id-ceo'].TeamTotal | Should -Be ($T.Nodes['id:id-ceo'].DirectTotal + $T.Nodes['id:id-vp'].TeamTotal)
        }
    }

    It 'check 3: no usage row is counted twice' {
        $rows = @($t.Nodes.Values | Where-Object Direct | ForEach-Object { $_.Direct.Rows } | ForEach-Object RowNumber)
        $rows.Count | Should -Be (@($rows | Select-Object -Unique).Count)
        $rows.Count | Should -Be 7     # all charged rows except the NO OWNER one
    }

    It 'holds all three checks on random org charts with disabled managers and loops (seed <Seed>)' -ForEach @(1..15 | ForEach-Object { @{ Seed = $_ } }) {
        $rnd = [System.Random]::new($Seed * 31)
        $n = $rnd.Next(5, 40)
        $ad = @(1..$n | ForEach-Object {
                $m = if ($_ -gt 1 -and $rnd.NextDouble() -lt 0.9) { "p$($rnd.Next(1, $n + 1))" } else { '' }
                New-TestAdUser "p$_" -Manager $m -Disabled:($rnd.NextDouble() -lt 0.1)
            })
        $usage = @(1..$n | Where-Object { $rnd.NextDouble() -lt 0.7 } | ForEach-Object { Seat "p$_" })
        if (-not $usage.Count) { $usage = @(Seat 'p1') }
        $q = @{ Period = '2027'; Currency = 'USD'; SeatPrices = @{ 'Off A' = '999.99' } }
        $s = New-TestRun -AdUsers $ad -UsageRows $usage -Quote $q -Name "rt$Seed"
        $x = Invoke-DivvyOut @s -PassThru -AllowUnrecovered 6>$null       # Assert-RollupCheck runs inside
        InModuleScope DivvyOut -Parameters @{ X = $x } {
            $sum = [decimal]0; foreach ($g in Get-ManagerSummary $X) { $sum += $g.Total }
            $sum | Should -Be $X.Reconciliation.Allocated
            $seen = @{}
            foreach ($node in $X.OrgTree.Nodes.Values) {
                $sub = [decimal]0; foreach ($s in Get-SubtreeNodes $node) { $sub += $s.Node.DirectTotal }
                $node.TeamTotal | Should -Be $sub
                if ($node.Direct) { foreach ($row in $node.Direct.Rows) { $seen.ContainsKey($row.RowNumber) | Should -BeFalse; $seen[$row.RowNumber] = 1 } }
            }
        }
    }
}

Describe 'Statements (spec 9.1, 9.7)' {
    BeforeAll {
        $r = Run $Org $Usage -Name 'files'
        $st = Join-Path $r.OutputDir 'statements'
        $sum = @(Import-Csv (Join-Path $r.OutputDir 'summary-by-manager.csv'))
    }

    It 'writes one statement per manager with direct charges, plus NO-OWNER' {
        (Get-ChildItem $st -Filter *.xlsx).Name | Sort-Object | Should -Be @('NO-OWNER.xlsx', 'Person ceo.xlsx', 'Person l1.xlsx', 'Person mgr.xlsx', 'Person mgr2.xlsx')
    }

    It 'has the Statement sheet first, then How this was calculated, with gridlines off' {
        $x = Read-Xl (Join-Path $st 'Person mgr.xlsx')
        @($x.Keys | Where-Object { $_ -ne '_big' }) | Should -Be @('Statement', 'How this was calculated')
        $x.Statement.Grid | Should -BeFalse
    }

    It 'shows the manager, the DRAFT chip with the reason, and the total as the big number' {
        $p = Join-Path $st 'Person mgr.xlsx'
        $x = Read-Xl $p
        $x.Statement.Rows[0] | Should -Match '^Person mgr\|.*DRAFT$'
        $x.Statement.Rows[1] | Should -Be ('Autodesk · 2027 renewal · run ' + $r.RunId)
        $x.Statement.Rows[2] | Should -Match '^Draft: 1 rows need an owner'
        $line = $sum | Where-Object Manager -eq 'Person mgr'
        Get-Cell $p 'Statement' 5 1 | Should -Be ([double]::Parse($line.Total, [cultureinfo]::InvariantCulture))
        Get-Cell $p 'Statement' 5 1 'Format' | Should -Be '$#,##0.00'
        $x.Statement.Rows[5] | Should -Match '^2 people · Seats \$\d'
    }

    It 'lists each direct report row and a total that matches the summary' {
        $x = Read-Xl (Join-Path $st 'Person mgr.xlsx')
        $table = @($x.Statement.Rows | Where-Object { $_ -match '^Person (a|b)\|' })
        $table.Count | Should -Be 3
        ($x.Statement.Rows | Where-Object { $_ -like 'Total|*' }) | Should -Match ([regex]::Escape(($sum | Where-Object Manager -eq 'Person mgr').Total.TrimEnd('0').TrimEnd('.')))
    }

    It 'keeps NO OWNER rows off manager statements and puts them on NO-OWNER' {
        foreach ($f in Get-ChildItem $st -Filter 'Person*.xlsx') { ((Read-Xl $f.FullName).Statement.Rows -join "`n") | Should -Not -Match 'Person orphan' }
        $no = Read-Xl (Join-Path $st 'NO-OWNER.xlsx')
        ($no.Statement.Rows -join "`n") | Should -Match 'Person orphan\|.*NoManager'
    }

    It 'explains the numbers in plain English' {
        $x = Read-Xl (Join-Path $st 'Person mgr.xlsx')
        $text = $x.'How this was calculated'.Rows -join "`n"
        $text | Should -Match 'Off A: price \$1,000\.00 ÷ 6 seats = \$166\.67 per seat\.'
        $text | Should -Match 'Token pool: price \$300\.00 ÷ 300 tokens used = \$1\.0000 per token'
    }

    It 'says FINAL with a check mark when the run is final' {
        $u = @(Seat a; Tok b 100)
        $x = Run $Org $u -Name 'final'
        $x.Status | Should -Be 'FINAL'
        (Read-Xl (Join-Path $x.OutputDir 'statements/Person mgr.xlsx')).Statement.Rows[0] | Should -Match ([string][char]0x2713 + ' FINAL$')
    }
}

Describe 'Roll-up workbooks (spec 8, 9.7)' {
    BeforeAll {
        $r = Run $Org $Usage -Name 'roll'
        $ru = Join-Path $r.OutputDir 'statements/rollup'
    }

    It 'writes one per manager with managers beneath (not for loop members or disabled managers)' {
        (Get-ChildItem $ru -Filter *.xlsx).Name | Sort-Object | Should -Be @('Person ceo.xlsx', 'Person vp.xlsx')
    }

    It 'has the Summary first, with the tree indented and the total of direct charges' {
        $x = Read-Xl (Join-Path $ru 'Person ceo.xlsx')
        @($x.Keys)[0] | Should -Be 'Summary'
        $s = $x.Summary.Rows
        $s[0] | Should -Match '^Person ceo\|\|\|.*DRAFT$'
        $s | Should -Contain '3 managers below you · 4 people'
        $table = @($s | Where-Object { $_ -match '^Person [^|]+\|\d+\|' })
        $table[0] | Should -Match '^Person ceo \(direct\)\|1\|'
        @($table | ForEach-Object { ($_ -split '\|')[0] }) | Should -Be @('Person ceo (direct)', 'Person vp', 'Person mgr', 'Person mgr2')
        $ceo = $r.OrgTree.Nodes['id:id-ceo']
        Get-Cell (Join-Path $ru 'Person ceo.xlsx') 'Summary' 5 1 | Should -Be ([double]$ceo.TeamTotal)
        ($s | Where-Object { $_ -like 'Total|*' }) | Should -Match ('^Total\|4\|' + [regex]::Escape(([double]$ceo.TeamTotal).ToString([cultureinfo]::InvariantCulture)))
        $s | Should -Contain 'These charges are assigned to the managers listed.'
    }

    It 'has one sheet per manager with rows, after the Summary' {
        $x = Read-Xl (Join-Path $ru 'Person ceo.xlsx')
        @($x.Keys | Where-Object { $_ -ne '_big' }) | Should -Be @('Summary', 'Person ceo (direct)', 'Person mgr', 'Person mgr2')
    }

    It 'limits sheets with Rollup.MaxTabs and says so' {
        $p = Get-TestProfile; $p.Rollup = @{ MaxTabs = 2 }
        $x = Run $Org $Usage -TestProfile $p -Name 'tabs'
        $wb = Read-Xl (Join-Path $x.OutputDir 'statements/rollup/Person ceo.xlsx')
        @($wb.Keys | Where-Object { $_ -ne '_big' }).Count | Should -Be 2
        $wb.Summary.Rows | Should -Contain '2 managers have no sheet in this file (Rollup.MaxTabs = 2). The table above lists everyone.'
    }

    It 'limits levels with Rollup.Depth' {
        $p = Get-TestProfile; $p.Rollup = @{ Depth = 1 }
        $x = Run $Org $Usage -TestProfile $p -Name 'depth'
        $s = (Read-Xl (Join-Path $x.OutputDir 'statements/rollup/Person ceo.xlsx')).Summary.Rows
        @($s | Where-Object { $_ -match '^Person [^|]+\|\d+\|' } | ForEach-Object { ($_ -split '\|')[0] }) | Should -Be @('Person ceo (direct)', 'Person vp')
    }

    It 'writes none with Rollup.Enabled = $false' {
        $p = Get-TestProfile; $p.Rollup = @{ Enabled = $false }
        $x = Run $Org $Usage -TestProfile $p -Name 'off'
        Test-Path (Join-Path $x.OutputDir 'statements/rollup') | Should -BeFalse
    }

    It 'follows an override that moves a manager in the tree (no usage row)' {
        $ov = [pscustomobject]@{ Key = 'mgr2'; Manager = 'ceo@test.example'; Reason = 'reorg' }
        $x = Run $Org $Usage -Overrides @($ov) -Name 'treefix'
        $x.OrgTree.Nodes['id:id-mgr2'].Parent.Key | Should -Be 'id:id-ceo'
        ($x.Overrides.Items[0]).Status | Should -Be 'TreeOnly'
    }
}
