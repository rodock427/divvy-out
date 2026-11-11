# M3: overrides, row states, owner, cost center. Fake data only.
BeforeAll {
    . $PSScriptRoot/TestHelpers.ps1
    $script:Quote = @{ Period = '2027'; Currency = 'USD'; SeatPrices = @{ 'Offering One' = 1000 }; TokenPoolPrice = 500 }
    function Seat { param([string]$Email, [string]$UserKey = '') New-TestUsageRow $Email 'Offering One' 'Seats' '' $UserKey }
    function Ov {
        param([string]$Key, [string]$Manager = '', [string]$CostCenter = '', [string]$Exclude = '', [string]$Include = '', [string]$LinkTo = '')
        [pscustomobject][ordered]@{ Key = $Key; Manager = $Manager; CostCenter = $CostCenter; Exclude = $Exclude; Include = $Include
            LinkTo = $LinkTo; Reason = 'test'; By = 'tester'; Date = '2026-11-10' }
    }
    function Invoke-States {
        param([object[]]$AdUsers, [object[]]$UsageRows, [object[]]$Overrides, [hashtable]$TestProfile = (Get-TestProfile), [string]$Name = 's')
        $s = New-TestRun -AdUsers $AdUsers -UsageRows $UsageRows -Quote $script:Quote -TestProfile $TestProfile -Overrides $Overrides -Name $Name
        $s.Remove('OutputRoot')
        Test-DivvyOutInput @s 6>$null
    }
    $script:Dir = @(
        New-TestAdUser boss
        New-TestAdUser ann -Manager boss
        New-TestAdUser bob -Manager boss
        New-TestAdUser gone -Manager boss -Disabled
        New-TestAdUser orphan                                  # no manager
        New-TestAdUser exboss -Disabled
        New-TestAdUser underex -Manager exboss                 # manager disabled
        New-TestAdUser far -Manager nobodyhere                 # manager not in the snapshot
        New-TestAdUser two1 -Mail 'two@test.example' -Manager boss
        New-TestAdUser two2 -Mail 'two@test.example' -Manager boss
        New-TestAdUser idle -Manager boss                      # no usage rows
        New-TestAdUser dupA -Manager boss -Upn 'dupA@one.example'
        New-TestAdUser dupB -Manager boss -Upn 'dupB@two.example'
    )
    $script:Dir[-1].sAMAccountName = 'dupA'                    # two users share a logon name (two domains)
}

Describe 'Row states without overrides (spec 7.1, 10)' {
    BeforeAll {
        $usage = @(
            Seat 'ann@test.example'          # 2 Charged
            Seat 'nobody@test.example'       # 3 NotHere NoMatch
            Seat 'gone@test.example'         # 4 NotHere Disabled
            Seat 'two@test.example'          # 5 NeedsOwner AmbiguousMatch
            Seat 'orphan@test.example'       # 6 NeedsOwner NoManager
            Seat 'underex@test.example'      # 7 NeedsOwner ManagerDisabled
            Seat 'far@test.example'          # 8 NeedsOwner ManagerNotFound
        )
        $r = Invoke-States $Dir $usage
        $st = { param([int]$n) $x = $r.Rows | Where-Object RowNumber -eq $n; "$($x.State)/$($x.Reason)" }
    }

    It 'row <N> is <Expected>' -ForEach @(
        @{ N = 2; Expected = 'Charged/' }
        @{ N = 3; Expected = 'NotHere/NoMatch' }
        @{ N = 4; Expected = 'NotHere/Disabled' }
        @{ N = 5; Expected = 'NeedsOwner/AmbiguousMatch' }
        @{ N = 6; Expected = 'NeedsOwner/NoManager' }
        @{ N = 7; Expected = 'NeedsOwner/ManagerDisabled' }
        @{ N = 8; Expected = 'NeedsOwner/ManagerNotFound' }
    ) {
        & $st $N | Should -Be $Expected
    }

    It 'sets the owner from the directory manager' {
        $ann = $r.Rows | Where-Object RowNumber -eq 2
        $ann.ManagerId | Should -Be 'id-boss'
        $ann.ManagerName | Should -Be 'Person boss'
        $ann.ManagerSource | Should -Be 'Directory'
        $ann.ManagerDirId | Should -Be 'id-boss'
    }

    It 'records the disabled directory manager for the audit trail' {
        ($r.Rows | Where-Object RowNumber -eq 7).ManagerDirId | Should -Be 'id-exboss'
    }
}

Describe 'Overrides (spec 5.3)' {
    BeforeAll {
        $usage = @(
            Seat 'ann@test.example'          # 2 Exclude
            Seat 'nobody@test.example'       # 3 LinkTo bob
            Seat 'two@test.example'          # 4 LinkTo two1 (fixes ambiguous)
            Seat 'orphan@test.example'       # 5 Manager by mail (directory key)
            Seat 'underex@test.example'      # 6 Manager free text
            Seat 'gone@test.example'         # 7 Include
            Seat 'far@test.example'          # 8 Exclude + Manager: Exclude wins
            Seat 'bob@test.example'          # 9 Manager override beats directory
        )
        $ovs = @(
            Ov 'ann@test.example' -Exclude 'Y'
            Ov 'nobody@test.example' -LinkTo 'bob'
            Ov 'two@test.example' -LinkTo 'CORP\two1'
            Ov 'orphan' -Manager 'ann@test.example'
            Ov 'underex@test.example' -Manager 'Someone Outside'
            Ov 'gone' -Include 'yes'
            Ov 'far@test.example' -Exclude 'y' -Manager 'ann@test.example'
            Ov 'bob@test.example' -Manager 'orphan@test.example'
            Ov 'idle' -Manager 'ann@test.example'      # no usage: org tree fix, not stale
        )
        $r = Invoke-States $Dir $usage $ovs
        $row = { param([int]$n) $r.Rows | Where-Object RowNumber -eq $n }
    }

    It 'Exclude = Y makes the row NotHere/Excluded' {
        (& $row 2).State | Should -Be 'NotHere'
        (& $row 2).Reason | Should -Be 'Excluded'
    }

    It 'LinkTo fixes a NoMatch' {
        (& $row 3).State | Should -Be 'Charged'
        (& $row 3).MatchStatus | Should -Be 'Linked'
        (& $row 3).User.Id | Should -Be 'id-bob'
    }

    It 'LinkTo fixes an AmbiguousMatch (DOMAIN\sam form)' {
        (& $row 4).State | Should -Be 'Charged'
        (& $row 4).User.Id | Should -Be 'id-two1'
    }

    It 'Manager (found with ManagerLookup) fixes NoManager' {
        (& $row 5).State | Should -Be 'Charged'
        (& $row 5).ManagerId | Should -Be 'id-ann'
        (& $row 5).ManagerSource | Should -Be 'Override'
    }

    It 'Manager not in the directory: warn and use the text as given' {
        (& $row 6).State | Should -Be 'Charged'
        (& $row 6).ManagerName | Should -Be 'Someone Outside'
        (& $row 6).ManagerId | Should -BeNullOrEmpty
        ($r.Issues | Where-Object Code -eq 'OverrideManagerText').Rows | Should -Be @(6)
    }

    It 'Include = Y charges a disabled user' {
        (& $row 7).State | Should -Be 'Charged'
        (& $row 7).ManagerId | Should -Be 'id-boss'
    }

    It 'Exclude wins over Manager' {
        (& $row 8).Reason | Should -Be 'Excluded'
    }

    It 'an override manager beats the directory manager' {
        (& $row 9).ManagerId | Should -Be 'id-orphan'
        (& $row 9).ManagerDirId | Should -Be 'id-boss'
    }

    It 'a manager fix for a person with no usage row is not stale' {
        ($r.Overrides.Items | Where-Object Key -eq 'idle').Status | Should -Be 'TreeOnly'
        $r.Issues | Where-Object Code -eq 'OverrideStale' | Should -BeNullOrEmpty
    }

    It 'every applied override is on its row' {
        @($r.Rows | Where-Object Override).Count | Should -Be 8
        $r.DraftReasons | Should -BeNullOrEmpty
    }
}

Describe 'Override validation (spec 5.3)' {
    BeforeAll {
        $usage = @(
            Seat 'ann@test.example'          # 2
            Seat 'bob@test.example'          # 3
        )
        $ovs = @(
            Ov 'nobody@x.example' -Exclude 'Y'          # 2 finds nobody
            Ov 'dupA' -Manager 'ann@test.example'       # 3 finds two users
            Ov 'ANN@test.example' -CostCenter 'A'       # 4 duplicate key (case ignored)
            Ov 'ann@test.example' -CostCenter 'B'       # 5 duplicate key
            Ov 'idle'                                   # 6 stale: no usage row, no manager
            Ov 'bob@test.example' -CostCenter 'C'       # 7 conflict with 8 (same person)
            Ov 'bob' -CostCenter 'D'                    # 8
            Ov 'orphan' -Exclude 'maybe'                # 9 bad value
            Ov 'CORP\bob' -LinkTo 'ann'                 # 10 LinkTo needs a usage-field key
        )
        $r = Invoke-States $Dir $usage $ovs
        $status = { param([int]$n) ($r.Overrides.Items | Where-Object RowNumber -eq $n).Status }
    }

    It 'override row <N> is <Expected>' -ForEach @(
        @{ N = 2; Expected = 'OverrideNoHit' }
        @{ N = 3; Expected = 'OverrideMultipleHits' }
        @{ N = 4; Expected = 'OverrideDuplicateKey' }
        @{ N = 5; Expected = 'OverrideDuplicateKey' }
        @{ N = 6; Expected = 'Stale' }
        @{ N = 7; Expected = 'OverrideConflict' }
        @{ N = 9; Expected = 'OverrideBadValue' }
        @{ N = 10; Expected = 'OverrideLinkFailed' }
    ) {
        & $status $N | Should -Be $Expected
    }

    It 'applies none of the conflicting overrides' {
        ($r.Rows | Where-Object RowNumber -eq 3).Override | Should -BeNullOrEmpty
    }

    It 'forces DRAFT with Policy.BadOverride = Draft' {
        $r.DraftReasons.Count | Should -BeGreaterThan 0
        ($r.DraftReasons -join ' ') | Should -Match 'OverrideNoHit'
    }

    It 'only warns with Policy.BadOverride = Warn' {
        $p = Get-TestProfile; $p.Policy = @{ BadOverride = 'Warn' }
        $w = Invoke-States $Dir $usage $ovs $p 'warn'
        $w.DraftReasons | Should -BeNullOrEmpty
        @($w.Issues | Where-Object Code -eq 'OverrideNoHit').Count | Should -Be 1
    }

    It 'stops when the overrides file has no Key column' {
        $s = New-TestRun -AdUsers $Dir -UsageRows $usage -Quote $script:Quote -Overrides @([pscustomobject]@{ Email = 'ann@test.example'; Exclude = 'Y' }) -Name 'nokey'
        $s.Remove('OutputRoot')
        $x = Test-DivvyOutInput @s 6>$null
        ($x.Issues | Where-Object Code -eq 'OverrideInvalid').Message | Should -Match 'needs a Key column'
    }

    It 'keeps keys out of diagnostics-safe messages' {
        ($r.Issues | Where-Object Code -like 'Override*' | ForEach-Object Message) -join ' ' | Should -Not -Match '@'
    }
}

Describe 'Cost center' {
    BeforeAll {
        $p = Get-TestProfile
        $p.Ad.CostCenter = @{ Attribute = 'costCenter'; Replace = @(@{ From = ','; To = '-' }) }
        $ad = @($Dir | ForEach-Object { $_.PSObject.Copy() })
        foreach ($u in $ad) { $u | Add-Member costCenter $(if ($u.sAMAccountName -eq 'bob') { '' } else { ' 4410, Finance, Corp ' }) }
        $usage = @(Seat 'ann@test.example'; Seat 'bob@test.example'; Seat 'two@test.example'; Seat 'orphan@test.example')
        $r = Invoke-States $ad $usage @(Ov 'orphan@test.example' -CostCenter 'Project X') $p
    }

    It 'replaces , with - and trims, keeping the raw value' {
        $r.Rows[0].CostCenterRaw | Should -Be ' 4410, Finance, Corp '
        $r.Rows[0].CostCenter | Should -Be '4410- Finance- Corp'
    }

    It 'leaves a missing cost center blank, with no exception' {
        $r.Rows[1].CostCenter | Should -Be ''
        $r.Rows[1].State | Should -Be 'Charged'
    }

    It 'uses an override cost center as the final value' {
        $r.Rows[3].CostCenter | Should -Be 'Project X'
        $r.Rows[3].CostCenterRaw | Should -Be ' 4410, Finance, Corp '
    }

    It 'shows nothing when the profile defines no cost center' {
        $plain = Invoke-States $Dir @(Seat 'ann@test.example') -Name 'nocc'
        $plain.Rows[0].CostCenter | Should -BeNullOrEmpty
    }
}

Describe 'Duplicate and mixed rows (spec 10, DECISIONS D14)' {
    BeforeAll {
        $usage = @(
            Seat 'ann@test.example'                                           # 2
            Seat 'ann@test.example'                                           # 3 duplicate seat
            New-TestUsageRow 'bob@test.example' 'Offering One' 'Seats'        # 4
            New-TestUsageRow 'bob@test.example' 'Offering One' 'Tokens' 100   # 5 mixed access
        )
    }

    It 'ChargeEach charges both seat rows and warns' {
        $r = Invoke-States $Dir $usage
        @($r.Rows | Where-Object State -eq 'Charged').Count | Should -Be 4
        ($r.Issues | Where-Object Code -eq 'DuplicateSeatRows').Rows | Should -Be @(2, 3)
        ($r.Issues | Where-Object Code -eq 'MixedAccess').Rows | Should -Be @(4, 5)
    }

    It 'ChargeOnce keeps the first seat row and makes the rest NotHere/Duplicate' {
        $p = Get-TestProfile; $p.Policy = @{ DuplicateSeatRows = 'ChargeOnce' }
        $r = Invoke-States $Dir $usage -TestProfile $p -Name 'once'
        ($r.Rows | Where-Object RowNumber -eq 2).State | Should -Be 'Charged'
        ($r.Rows | Where-Object RowNumber -eq 3).Reason | Should -Be 'Duplicate'
    }
}
