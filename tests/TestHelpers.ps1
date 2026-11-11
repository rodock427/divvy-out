# Shared test helpers. Fake data only.
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $script:RepoRoot 'src/DivvyOut/DivvyOut.psd1') -Force

# Standard-AD test profile. Returns a fresh hashtable each call so tests can change it.
function Get-TestProfile {
    @{
        Vendor = 'Autodesk'
        Usage  = @{
            HeaderRow          = 1
            Columns            = @{
                Team = 'Team Alias'; Package = 'Offering Name'; Email = 'Source Email'
                AccessOption = 'Access Options'; Tokens = 'Tokens Used'; UserKey = 'User Name'
            }
            AccessOptionValues = @{ Seat = 'Seats'; Token = 'Tokens' }
            OfferingAliases    = @{}
        }
        Match  = @{
            PreferEnabled = $true
            Rules         = @(
                @{ UsageField = 'Email'; AdAttribute = 'mail'; Normalize = 'Trim', 'ToLower' }
                @{ UsageField = 'Email'; AdAttribute = 'userPrincipalName'; Normalize = 'Trim', 'ToLower' }
                @{ UsageField = 'UserKey'; AdAttribute = 'userPrincipalName'; Normalize = 'Trim', 'ToLower' }
                @{ UsageField = 'UserKey'; AdAttribute = 'sAMAccountName'; Normalize = 'Trim', 'ToLower', 'StripDomainPrefix', 'StripUpnSuffix' }
            )
        }
        Ad     = @{
            Attributes          = 'objectGUID', 'sAMAccountName', 'userPrincipalName', 'mail', 'displayName', 'manager', 'distinguishedName', 'Enabled'
            IdAttribute         = 'objectGUID'
            EnabledColumn       = 'Enabled'
            EnabledValue        = 'True'
            ManagerAttribute    = 'manager'
            ManagerKeyAttribute = 'distinguishedName'
            DisplayAttribute    = 'displayName'
        }
        Charge    = @{ Owner = 'DirectManager' }
        Policy    = @{}
        Overrides = @{
            KeyRules      = @(
                @{ UsageField = 'Email'; Normalize = 'Trim', 'ToLower' }
                @{ AdAttribute = 'sAMAccountName'; Normalize = 'Trim', 'ToLower', 'StripDomainPrefix' }
            )
            ManagerLookup = @{ AdAttribute = 'mail'; Normalize = 'Trim', 'ToLower' }
        }
    }
}

function New-TestAdUser {
    param([string]$Sam, [string]$Manager, [switch]$Disabled, [string]$Mail, [string]$Upn, [string]$Id)
    [pscustomobject][ordered]@{
        objectGUID        = if ($Id) { $Id } else { "id-$Sam" }
        sAMAccountName    = $Sam
        userPrincipalName = if ($Upn) { $Upn } else { "$Sam@ad.test.example" }
        mail              = if ($PSBoundParameters.ContainsKey('Mail')) { $Mail } else { "$Sam@test.example" }
        displayName       = "Person $Sam"
        manager           = if ($Manager) { "CN=$Manager,OU=Users,DC=test,DC=example" } else { '' }
        distinguishedName = "CN=$Sam,OU=Users,DC=test,DC=example"
        Enabled           = if ($Disabled) { 'False' } else { 'True' }
    }
}

function New-TestUsageRow {
    param([string]$Email, [string]$Offering, [string]$Access, $Tokens = '', [string]$UserKey = '', [string]$Team = 'Team A')
    [pscustomobject][ordered]@{
        'Team Alias' = $Team; 'Offering Name' = $Offering; 'Source Email' = $Email
        'Access Options' = $Access; 'Tokens Used' = [string]$Tokens; 'User Name' = $UserKey
    }
}

# Writes the inputs under TestDrive and returns a splat for Invoke-DivvyOut.
function New-TestRun {
    param(
        [object[]]$AdUsers, [object[]]$UsageRows, [hashtable]$Quote,
        [hashtable]$TestProfile = (Get-TestProfile), [object[]]$Overrides,
        [string]$Name = 'run', [string]$UsageExtension = '.csv'
    )
    $dir = Join-Path $TestDrive $Name
    New-Item -ItemType Directory -Force $dir | Out-Null
    $adPath = Join-Path $dir 'ad.csv'
    $AdUsers | Export-Csv $adPath -Encoding utf8BOM
    $usagePath = Join-Path $dir "usage$UsageExtension"
    if ($UsageExtension -eq '.xlsx') { $UsageRows | Export-Excel $usagePath -WorksheetName 'Usage' }
    else { $UsageRows | Export-Csv $usagePath -Encoding utf8BOM }
    $splat = @{ Profile = $TestProfile; Quote = $Quote; Usage = $usagePath; Ad = $adPath; OutputRoot = (Join-Path $dir 'output') }
    if ($Overrides) {
        $ovPath = Join-Path $dir 'overrides.csv'
        $Overrides | Export-Csv $ovPath -Encoding utf8BOM
        $splat.Overrides = $ovPath
    }
    $splat
}

function Get-RunFolder { param([hashtable]$Splat) Get-ChildItem $Splat.OutputRoot -Directory | Sort-Object Name | Select-Object -Last 1 }

function Get-DecimalSum { param([object[]]$Values) $t = [decimal]0; foreach ($v in $Values) { $t += [decimal]$v }; $t }
