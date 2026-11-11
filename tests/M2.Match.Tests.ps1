# M2: normalize, ordered match rules, PreferEnabled, DisabledSoloHit, match report. Fake data only.
BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    $script:Quote = @{ Period = '2027'; Currency = 'USD'; SeatPrices = @{ 'Offering One' = 1000 }; TokenPoolPrice = 500 }
    # Match the given usage rows against the given directory; returns the result.
    function Invoke-Match {
        param([object[]]$AdUsers, [object[]]$UsageRows, [hashtable]$TestProfile = (Get-TestProfile), [string]$Name = 'm')
        $s = New-TestRun -AdUsers $AdUsers -UsageRows $UsageRows -Quote $script:Quote -TestProfile $TestProfile -Name $Name
        $r = Test-DivvyOutInput -Profile $s.Profile -Quote $s.Quote -Usage $s.Usage -Ad $s.Ad 6>$null
        @($r.Issues | Where-Object Level -eq 'Error') | Should -BeNullOrEmpty
        $r
    }
    function Seat { param([string]$Email, [string]$UserKey = '') New-TestUsageRow $Email 'Offering One' 'Seats' '' $UserKey }
    $script:Boss = New-TestAdUser boss
}

Describe 'Normalize options' {
    It '<Step> turns <In> into <Out>' -ForEach @(
        @{ Step = 'Trim'; In = '  a@b.c  '; Out = 'a@b.c' }
        @{ Step = 'ToLower'; In = 'Ann@Test.EXAMPLE'; Out = 'ann@test.example' }
        @{ Step = 'StripDomainPrefix'; In = 'CORP\jsmith'; Out = 'jsmith' }
        @{ Step = 'StripDomainPrefix'; In = 'jsmith'; Out = 'jsmith' }
        @{ Step = 'StripUpnSuffix'; In = 'jsmith@corp.com'; Out = 'jsmith' }
        @{ Step = 'StripUpnSuffix'; In = 'jsmith'; Out = 'jsmith' }
    ) {
        InModuleScope DivvyOut -Parameters @{ Step = $Step; In = $In; Out = $Out } {
            ConvertTo-NormalizedValue $In @($Step) | Should -BeExactly $Out
        }
    }

    It 'applies a Regex step and runs steps in the order given' {
        InModuleScope DivvyOut {
            ConvertTo-NormalizedValue ' SMTP:Ann@X.com ' @('Trim', 'ToLower', @{ Pattern = '^smtp:'; Replacement = '' }) | Should -BeExactly 'ann@x.com'
            ConvertTo-NormalizedValue 'CORP\Ann@x.com' @('StripDomainPrefix', 'StripUpnSuffix', 'ToLower') | Should -BeExactly 'ann'
        }
    }
}

Describe 'Match rules (spec 5.2)' {
    BeforeAll {
        $ad = @(
            $Boss
            New-TestAdUser ann -Manager boss
            New-TestAdUser bob -Manager boss -Mail ''                                  # no mail: found by UPN or username only
            New-TestAdUser live -Manager boss -Mail 'shared@test.example'
            New-TestAdUser old-live -Manager boss -Mail 'shared@test.example' -Disabled  # old disabled duplicate
            New-TestAdUser two1 -Manager boss -Mail 'two@test.example'
            New-TestAdUser two2 -Manager boss -Mail 'two@test.example'                  # two live accounts, one mail
            New-TestAdUser prev -Manager boss -Mail 'moved@test.example' -Disabled      # only mail hit is disabled
            New-TestAdUser moved -Manager boss -Mail 'moved2@test.example' -Upn 'moved@test.example'
            New-TestAdUser gone -Manager boss -Disabled
            New-TestAdUser dead1 -Manager boss -Mail 'dead@test.example' -Disabled
            New-TestAdUser dead2 -Manager boss -Mail 'dead@test.example' -Disabled
        )
        $usage = @(
            Seat 'ann@test.example'                 # 2  rule 1 (mail)
            Seat 'bob@ad.test.example'              # 3  rule 2 (UPN in the email column)
            Seat '' 'CORP\bob'                      # 4  rule 4 (DOMAIN\sam)
            Seat '' 'bob@ad.test.example'           # 5  rule 3 (username column holds UPN)
            Seat '' 'bob'                           # 6  rule 4 (bare sam)
            Seat 'shared@test.example'              # 7  PreferEnabled drops old-live
            Seat 'two@test.example'                 # 8  ambiguous
            Seat 'nobody@test.example'              # 9  no match
            Seat 'moved@test.example'               # 10 disabled on rule 1, live on rule 2
            Seat 'gone@test.example'                # 11 disabled user
            Seat 'dead@test.example'                # 12 two disabled users
            Seat '  ANN@Test.Example '              # 13 normalized to rule 1
            Seat '' ''                              # 14 nothing to match on
        )
        $r = Invoke-Match $ad $usage
        $row = { param([int]$n) $r.Rows | Where-Object RowNumber -eq $n }
    }

    It 'matches the email form on rule 1' {
        (& $row 2).MatchStatus | Should -Be 'Matched'
        (& $row 2).MatchRule | Should -Be 1
        (& $row 2).User.Id | Should -Be 'id-ann'
        (& $row 2).MatchValue | Should -Be 'ann@test.example'
        (& $row 2).MatchDirValue | Should -Be 'ann@test.example'
    }

    It 'matches the UPN form on rule 2' {
        (& $row 3).MatchRule | Should -Be 2
        (& $row 3).User.Id | Should -Be 'id-bob'
    }

    It 'matches the DOMAIN\sam, UPN, and bare sam username forms' {
        (& $row 4).MatchRule | Should -Be 4
        (& $row 5).MatchRule | Should -Be 3
        (& $row 6).MatchRule | Should -Be 4
        (& $row 4).User.Id, (& $row 5).User.Id, (& $row 6).User.Id | Should -Be @('id-bob', 'id-bob', 'id-bob')
    }

    It 'drops a disabled duplicate with PreferEnabled' {
        (& $row 7).MatchStatus | Should -Be 'Matched'
        (& $row 7).User.Id | Should -Be 'id-live'
        (& $row 7).PreferEnabledDropped | Should -BeTrue
    }

    It 'does not guess when two live users match' {
        (& $row 8).MatchStatus | Should -Be 'Ambiguous'
        (& $row 8).User | Should -BeNullOrEmpty
        (& $row 8).Candidates | Should -Be @('id-two1', 'id-two2')
    }

    It 'reports no match' {
        (& $row 9).MatchStatus | Should -Be 'NoMatch'
        (& $row 14).MatchStatus | Should -Be 'NoMatch'
    }

    It 'looks past a disabled-only hit to a live account (DisabledSoloHit = TryNextRule)' {
        (& $row 10).MatchStatus | Should -Be 'Matched'
        (& $row 10).User.Id | Should -Be 'id-moved'
        (& $row 10).MatchRule | Should -Be 2
        (& $row 10).DisabledSkipped | Should -BeTrue
    }

    It 'marks a disabled user, and several disabled users, as Disabled' {
        (& $row 11).MatchStatus | Should -Be 'Disabled'
        (& $row 11).User.Id | Should -Be 'id-gone'
        (& $row 12).MatchStatus | Should -Be 'Disabled'
        (& $row 12).User | Should -BeNullOrEmpty
        (& $row 12).Candidates.Count | Should -Be 2
    }

    It 'normalizes case and spaces on both sides' {
        (& $row 13).User.Id | Should -Be 'id-ann'
    }

    It 'writes a match report with counts per rule and per outcome' {
        $r.MatchReport.Lines | Should -Contain 'Rule 1 (Email -> mail): 3 matched'
        $r.MatchReport.Lines | Should -Contain 'Rule 2 (Email -> userPrincipalName): 2 matched'
        $r.MatchReport.Counts.Ambiguous | Should -Be 1
        $r.MatchReport.Counts.NoMatch | Should -Be 2
        $r.MatchReport.Counts.Disabled | Should -Be 2
        ($r.Issues | Where-Object Code -eq 'FallbackRule').Rows | Should -Be @(3, 4, 5, 6, 10)
        ($r.Issues | Where-Object Code -eq 'PreferEnabled').Rows | Should -Be @(7)
        ($r.Issues | Where-Object Code -eq 'AmbiguousMatch').Rows | Should -Be @(8)
    }
}

Describe 'Match settings' {
    It 'with PreferEnabled off, a live and a disabled account on one mail are ambiguous' {
        $p = Get-TestProfile; $p.Match.PreferEnabled = $false
        $ad = @($Boss; New-TestAdUser live -Mail 'shared@test.example'; New-TestAdUser old -Mail 'shared@test.example' -Disabled)
        $r = Invoke-Match $ad @(Seat 'shared@test.example') $p
        $r.Rows[0].MatchStatus | Should -Be 'Ambiguous'
    }

    It 'with DisabledSoloHit = Stop, stops at the disabled-only hit' {
        $p = Get-TestProfile; $p.Match.DisabledSoloHit = 'Stop'
        $ad = @($Boss; New-TestAdUser prev -Mail 'moved@test.example' -Disabled; New-TestAdUser moved -Mail 'x@test.example' -Upn 'moved@test.example')
        $r = Invoke-Match $ad @(Seat 'moved@test.example') $p
        $r.Rows[0].MatchStatus | Should -Be 'Disabled'
        $r.Rows[0].User.Id | Should -Be 'id-prev'
    }

    It 'rejects an unknown DisabledSoloHit value' {
        $p = Get-TestProfile; $p.Match.DisabledSoloHit = 'Maybe'
        $s = New-TestRun -AdUsers @($Boss) -UsageRows @(Seat 'boss@test.example') -Quote $script:Quote -TestProfile $p -Name 'bad'
        $s.Remove('OutputRoot')
        $r = Test-DivvyOutInput @s 6>$null
        ($r.Issues | Where-Object Code -eq 'ProfileInvalid').Message | Should -Match 'DisabledSoloHit must be one of'
    }

    It 'matches any usage field to any directory column, and splits joined values' {
        $p = Get-TestProfile
        $p.Match.Rules = @(@{ UsageField = 'Email'; AdAttribute = 'aliases'; Split = ';'; Normalize = 'Trim', 'ToLower', @{ Pattern = '^smtp:'; Replacement = '' } })
        $u = New-TestAdUser ann
        $u | Add-Member aliases 'SMTP:ann@test.example;smtp:Ann.Alias@Legacy.example'
        $r = Invoke-Match @($u) @(Seat 'ann.alias@legacy.example') $p
        $r.Rows[0].User.Id | Should -Be 'id-ann'
    }

    It 'builds each index once, so 4,000 rows against 4,000 users is fast' {
        $ad = @(1..4000 | ForEach-Object { New-TestAdUser "u$_" })
        $usage = @(1..4000 | ForEach-Object { Seat "u$_@test.example" })
        $t = Measure-Command { $script:big = Invoke-Match $ad $usage -Name 'big' }
        @($big.Rows | Where-Object MatchStatus -eq 'Matched').Count | Should -Be 4000
        $t.TotalSeconds | Should -BeLessThan 60
    }
}
