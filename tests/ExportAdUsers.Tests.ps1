# Export-AdUsers.ps1 with a mocked Get-ADUser (the real one cannot run here). Fake data only.
BeforeAll {
    $script:Script = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Export-AdUsers.ps1'
    $script:ProfilePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'config/profiles/autodesk_profile_2027.psd1'
    # Stub so Pester can mock a command that does not exist on this machine.
    if (-not (Get-Command Get-ADUser -ErrorAction SilentlyContinue)) {
        function global:Get-ADUser { param($Filter, $Properties, $SearchBase, $Server, $Identity) }
    }
    function New-FakeAdObject {
        param([string]$Sam, [string]$ManagerDn, [bool]$Enabled = $true, [string[]]$Proxy = @())
        [pscustomobject]@{
            objectGUID = [guid]::new(('{0:x32}' -f [Math]::Abs($Sam.GetHashCode())).PadLeft(32, '0').Substring(0, 32))
            sAMAccountName = $Sam; userPrincipalName = "$Sam@ad.test.example"; mail = "$Sam@test.example"
            displayName = "Person $Sam"; manager = $ManagerDn; distinguishedName = "CN=$Sam,OU=Users,DC=test,DC=example"
            Enabled = $Enabled; proxyAddresses = $Proxy; costCenter = "4100, Fake, Corp"
        }
    }
}

Describe 'Export-AdUsers.ps1' {
    BeforeAll {
        $boss = New-FakeAdObject 'boss'
        $ann = New-FakeAdObject 'ann' $boss.distinguishedName -Proxy 'SMTP:ann@test.example', 'smtp:a.alias@test.example'
        $gone = New-FakeAdObject 'gone' $boss.distinguishedName -Enabled $false
        $far = New-FakeAdObject 'far' 'CN=outsider,OU=Other,DC=test,DC=example'
        $lost = New-FakeAdObject 'lost' 'CN=nobody,OU=Other,DC=test,DC=example'
        $outsider = New-FakeAdObject 'outsider'
        Mock Get-ADUser -ParameterFilter { $Server -eq 'dc1' -and $Filter } { $boss, $ann, $gone }
        Mock Get-ADUser -ParameterFilter { $Server -eq 'dc2' -and $Filter } { $ann, $far, $lost }   # ann twice: kept once
        Mock Get-ADUser -ParameterFilter { $Identity -eq 'CN=outsider,OU=Other,DC=test,DC=example' } { $outsider }
        Mock Get-ADUser -ParameterFilter { $Identity -eq 'CN=nobody,OU=Other,DC=test,DC=example' } { throw 'not found' }
        $out = Join-Path $TestDrive 'ad.csv'
        & $Script -ProfilePath $ProfilePath -OutFile $out -Server 'dc1', 'dc2' 6>$null
        $rows = Import-Csv $out
        $bySam = @{}; foreach ($r in $rows) { $bySam[$r.sAMAccountName] = $r }
    }

    It 'exports enabled and disabled users once each' {
        $rows.Count | Should -Be 5
        $bySam['gone'].Enabled | Should -Be 'False'
    }

    It 'writes every profile attribute as a column, then manager_<name> columns' {
        $cfg = (Import-PowerShellDataFile $ProfilePath).Ad
        $expected = @($cfg.Attributes) + @($cfg.ManagerColumns | ForEach-Object { "manager_$_" })
        $rows[0].PSObject.Properties.Name | Should -Be $expected
    }

    It 'resolves the manager DN inside the export' {
        $bySam['ann'].manager_mail | Should -Be 'boss@test.example'
        $bySam['ann'].manager_objectGUID | Should -Be $bySam['boss'].objectGUID
        $bySam['ann'].manager_displayName | Should -Be 'Person boss'
    }

    It 'looks up a manager outside the export by DN, and leaves blanks if not found' {
        $bySam['far'].manager_mail | Should -Be 'outsider@test.example'
        $bySam['lost'].manager_mail | Should -Be ''
        $bySam['boss'].manager_mail | Should -Be ''
    }

    It 'joins multi-valued attributes with ;' {
        $bySam['ann'].proxyAddresses | Should -Be 'SMTP:ann@test.example;smtp:a.alias@test.example'
    }

    It 'writes UTF-8 with BOM, sorted by ID' {
        $bytes = [IO.File]::ReadAllBytes($out)
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        $ids = [string[]]$rows.objectGUID; $sorted = $ids.Clone(); [Array]::Sort($sorted, [StringComparer]::Ordinal)
        $ids | Should -Be $sorted
    }

    It 'passes SearchBase, and uses port 3268 for the Global Catalog' {
        Mock Get-ADUser -ParameterFilter { $Server -eq 'gc1:3268' -and $SearchBase -eq 'DC=test,DC=example' } { $boss }
        & $Script -ProfilePath $ProfilePath -OutFile (Join-Path $TestDrive 'gc.csv') -Server 'gc1' -UseGlobalCatalog -SearchBase 'DC=test,DC=example' 6>$null
        Should -Invoke Get-ADUser -ParameterFilter { $Server -eq 'gc1:3268' -and $SearchBase -eq 'DC=test,DC=example' } -Times 1 -Exactly
    }
}
