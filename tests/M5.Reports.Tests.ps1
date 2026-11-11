# M5: run status, summary by manager, not-found, overrides template, exceptions, CSV safety. Fake data only.
BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    function Seat { param([string]$Email, [string]$Team = 'Team A') New-TestUsageRow $Email 'Off A' 'Seats' '' '' $Team }
    function Run {
        param([object[]]$AdUsers, [object[]]$UsageRows, [hashtable]$Quote, [object[]]$Overrides, [string]$Name = 'r', [switch]$AllowUnrecovered)
        $s = New-TestRun -AdUsers $AdUsers -UsageRows $UsageRows -Quote $Quote -Overrides $Overrides -Name $Name
        $r = Invoke-DivvyOut @s -PassThru -AllowUnrecovered:$AllowUnrecovered 6>$null
        $r | Add-Member Folder (Get-RunFolder $s).FullName -PassThru
    }
    function Csv { param($Result, [string]$Name) @(Import-Csv (Join-Path $Result.Folder $Name)) }
    $script:Ad = @(
        New-TestAdUser boss
        New-TestAdUser lead -Manager boss
        New-TestAdUser ann -Manager lead
        New-TestAdUser bob -Manager lead
        New-TestAdUser cid -Manager boss
        New-TestAdUser orphan
        New-TestAdUser gone -Manager lead -Disabled
    )
    $script:Quote = @{ Period = '2027'; Currency = 'USD'; SeatPrices = @{ 'Off A' = '1000.00' }; TokenPoolPrice = '300.00' }
}

Describe 'Run status (spec 7.4)' {
    It 'is FINAL with no NeedsOwner rows, nothing unrecovered, and no bad override' {
        # (A TokenPoolPrice with no token rows would be unrecoverable, so this quote has none.)
        $q = $Quote.Clone(); $q.Remove('TokenPoolPrice')
        $r = Run $Ad @(Seat 'ann@test.example'; Seat 'cid@test.example') $q -Name 'final2'
        $r.Status | Should -Be 'FINAL'
        $r.DraftReasons | Should -BeNullOrEmpty
        Get-Content (Join-Path $r.Folder 'diagnostics.txt') -Raw | Should -Match 'Status:\s+FINAL'
    }

    It 'is DRAFT when rows need an owner, and says why' {
        $q = $Quote.Clone(); $q.Remove('TokenPoolPrice')
        $r = Run $Ad @(Seat 'ann@test.example'; Seat 'orphan@test.example') $q -Name 'needs'
        $r.Status | Should -Be 'DRAFT'
        $r.DraftReasons[0] | Should -Be '1 rows need an owner'
    }

    It 'is DRAFT when an override is bad' {
        $q = $Quote.Clone(); $q.Remove('TokenPoolPrice')
        $ov = [pscustomobject]@{ Key = 'typo@test.example'; Exclude = 'Y' }
        $r = Run $Ad @(Seat 'ann@test.example') $q -Overrides @($ov) -Name 'badov'
        $r.Status | Should -Be 'DRAFT'
    }
}

Describe 'Summary by manager (spec 9.2)' {
    BeforeAll {
        $usage = @(
            Seat 'ann@test.example'                                      # lead
            Seat 'bob@test.example'                                      # lead
            New-TestUsageRow 'bob@test.example' 'Off A' 'Tokens' 100      # lead, same person
            Seat 'cid@test.example'                                      # boss
            Seat 'orphan@test.example'                                   # NO OWNER
            Seat 'gone@test.example'                                     # NotHere
            New-TestUsageRow 'x@test.example' 'Off A' 'Tokens' 200        # NotHere
        )
        $r = Run $Ad $usage $Quote -Name 'sum'
        $sum = Csv $r 'summary-by-manager.csv'
    }

    It 'has one line per manager, then NO OWNER' {
        $sum.Manager | Should -Be @('Person boss', 'Person lead', 'NO OWNER')
        $sum.Status | Select-Object -Unique | Should -Be 'DRAFT'
    }

    It 'counts people once and splits seat and token totals' {
        $lead = $sum | Where-Object Manager -eq 'Person lead'
        $lead.People | Should -Be 2
        $lead.Rows | Should -Be 3
        $lead.SeatTotal | Should -Be '500.00'
        $lead.TokenTotal | Should -Be '300.00'
        $lead.Total | Should -Be '800.00'
    }

    It 'adds up to the allocated total' {
        (Get-DecimalSum ($sum | ForEach-Object { [decimal]::Parse($_.Total, [cultureinfo]::InvariantCulture) })) | Should -Be $r.Reconciliation.Allocated
        $r.Reconciliation.Allocated | Should -Be 1300
    }

    It 'adds an UNRECOVERED line when -AllowUnrecovered leaves money unallocated' {
        $q = @{ Period = '2027'; Currency = 'USD'; SeatPrices = @{ 'Off A' = 100; 'Off B' = 40 } }
        $u = @(Seat 'ann@test.example'; New-TestUsageRow 'gone@test.example' 'Off B' 'Seats')
        $x = Run $Ad $u $q -Name 'unrec' -AllowUnrecovered
        $line = Csv $x 'summary-by-manager.csv' | Where-Object Manager -like 'UNRECOVERED*'
        $line.Total | Should -Be '40.00'
    }

    It 'writes a free-text override manager as its own line with no ID' {
        $q = $Quote.Clone(); $q.Remove('TokenPoolPrice')
        $ov = [pscustomobject]@{ Key = 'orphan@test.example'; Manager = 'Outside Person' }
        $x = Run $Ad @(Seat 'orphan@test.example') $q -Overrides @($ov) -Name 'free'
        $line = Csv $x 'summary-by-manager.csv'
        $line.Manager | Should -Be 'Outside Person'
        $line.ManagerId | Should -Be ''
    }
}

Describe 'Not-found report and overrides template (spec 9.3)' {
    BeforeAll {
        $usage = @(
            Seat 'ann@test.example'
            Seat 'gone@test.example'                    # Disabled
            Seat 'nobody@test.example'                  # NoMatch
            Seat 'nobody@test.example'                  # NoMatch, same key
            Seat 'orphan@test.example'                  # NeedsOwner
            Seat 'cid@test.example'                     # Excluded
            Seat '' ''                                  # NoMatch, blank key
        )
        $q = $Quote.Clone(); $q.Remove('TokenPoolPrice')
        $r = Run $Ad $usage $q -Overrides @([pscustomobject]@{ Key = 'cid@test.example'; Exclude = 'Y'; Reason = 'Left' }) -Name 'nf'
        $nf = Csv $r 'not-found.csv'
        $tpl = Csv $r 'overrides-template.csv'
    }

    It 'lists every NotHere row with its reason' {
        $nf.Row | Should -Be @('3', '4', '5', '7', '8')
        $nf.Reason | Should -Be @('Disabled', 'NoMatch', 'NoMatch', 'Excluded', 'NoMatch')
        ($nf | Where-Object Row -eq 3).DirectoryName | Should -Be 'Person gone'
        ($nf | Where-Object Row -eq 7).OverrideReason | Should -Be 'Left'
    }

    It 'shows the usage identifiers, team, offering, access, and tokens' {
        $nf[0].PSObject.Properties.Name | Should -Be @('Row', 'Email', 'UserKey', 'Team', 'Offering', 'OfferingInQuote', 'Access', 'Tokens', 'Reason', 'DirectoryId', 'DirectoryName', 'OverrideReason')
        $nf[1].Email | Should -Be 'nobody@test.example'
    }

    It 'writes one template line per NoMatch / NeedsOwner key, with only Key filled' {
        $tpl.Key | Should -Be @('nobody@test.example', 'orphan@test.example')
        $tpl[0].Problem | Should -Be 'NoMatch (row 4); NoMatch (row 5)'
        foreach ($c in 'Manager', 'CostCenter', 'Exclude', 'Include', 'LinkTo', 'Reason', 'By', 'Date') { $tpl.$c | Select-Object -Unique | Should -Be '' }
    }

    It 'reads its own template back as an overrides file without column warnings' {
        $s = New-TestRun -AdUsers $Ad -UsageRows @(Seat 'orphan@test.example') -Quote @{ Period = '2027'; Currency = 'USD'; SeatPrices = @{ 'Off A' = 1 } } -Name 'tplback'
        $s.Overrides = Join-Path $r.Folder 'overrides-template.csv'
        $s.Remove('OutputRoot')
        $x = Test-DivvyOutInput @s 6>$null
        $x.Issues | Where-Object Code -eq 'OverrideColumns' | Should -BeNullOrEmpty
    }
}

Describe 'Exceptions report (spec 10)' {
    BeforeAll {
        $repo = Split-Path -Parent $PSScriptRoot
        $s = @{
            Profile = Join-Path $repo 'config/profiles/autodesk_profile_2027.psd1'; Quote = Join-Path $repo 'config/quotes/autodesk_quote_2027.psd1'
            Usage = Join-Path $repo 'samples/autodesk_usage_2027.csv'; Ad = Join-Path $repo 'samples/ad-snapshot.csv'
            Overrides = Join-Path $repo 'samples/overrides.csv'; OutputRoot = Join-Path $TestDrive 'sample'
        }
        $r = Invoke-DivvyOut @s -PassThru 6>$null
        $ex = @(Import-Csv (Join-Path $r.OutputDir 'exceptions.csv'))
    }

    It 'lists the planted case <Code>' -ForEach @(
        @{ Code = 'NoMatch' }, @{ Code = 'DisabledUser' }, @{ Code = 'Excluded' }, @{ Code = 'AmbiguousMatch' }
        @{ Code = 'NeedsOwnerNoManager' }, @{ Code = 'NeedsOwnerManagerDisabled' }, @{ Code = 'NeedsOwnerManagerNotFound' }
        @{ Code = 'FallbackRule' }, @{ Code = 'PreferEnabled' }, @{ Code = 'SeatTokensIgnored' }, @{ Code = 'DuplicateSeatRows' }
        @{ Code = 'MixedAccess' }, @{ Code = 'OverrideNoHit' }
    ) {
        @($ex | Where-Object Code -eq $Code).Count | Should -BeGreaterThan 0
    }

    It 'shows the identifier for usage rows and the key for override rows' {
        ($ex | Where-Object Code -eq 'NoMatch' | Select-Object -First 1).Identifier | Should -Match '@'
        ($ex | Where-Object Code -eq 'OverrideNoHit').Identifier | Should -Be 'nobody.here@corp.example'
        ($ex | Where-Object Code -eq 'OverrideNoHit').File | Should -Be 'overrides'
    }

    It 'reconciles the sample: summary total = allocated = quote total' {
        $sum = @(Import-Csv (Join-Path $r.OutputDir 'summary-by-manager.csv'))
        (Get-DecimalSum ($sum | ForEach-Object { [decimal]::Parse($_.Total, [cultureinfo]::InvariantCulture) })) | Should -Be $r.Reconciliation.QuoteTotal
    }
}

Describe 'CSV safety (NFR-7, NFR-8)' {
    BeforeAll {
        $usage = @(
            Seat 'ann@test.example'
            Seat 'n1@test.example' '=HYPERLINK("x")'
            Seat 'n2@test.example' '+SUM(1)'
            Seat 'n3@test.example' '-1+2'
            Seat 'n4@test.example' '@cmd'
            Seat 'n5@test.example' 'Zoë Ørsted, "Ltd"'
        )
        $q = $Quote.Clone(); $q.Remove('TokenPoolPrice')
        $r = Run $Ad $usage $q -Name 'csv'
    }

    It 'writes text that starts with = + - @ as text' {
        $teams = (Csv $r 'not-found.csv').Team
        $teams | Should -Be @("'=HYPERLINK(""x"")", "'+SUM(1)", "'-1+2", "'@cmd", 'Zoë Ørsted, "Ltd"')
    }

    It 'writes every CSV as UTF-8 with BOM' {
        foreach ($f in Get-ChildItem $r.Folder -Filter *.csv) {
            [IO.File]::ReadAllBytes($f.FullName)[0..2] | Should -Be @(0xEF, 0xBB, 0xBF) -Because $f.Name
        }
    }
}
