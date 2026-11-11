<#
.SYNOPSIS
Snapshots Active Directory users to a CSV for DivvyOut (spec Section 6).

.DESCRIPTION
- Reads the attribute list from the profile (Ad.Attributes). Nothing about your directory is hard-coded.
- Exports enabled AND disabled users (disabled ones are needed to find departed users and managers).
- Resolves the manager reference (a DN in AD) and adds manager_<name> columns for each name in Ad.ManagerColumns.
  A manager outside the search scope is looked up by DN. If that fails, the columns stay blank.
- Multi-valued attributes are joined with ';' (for example proxyAddresses).
- Users found through several servers are kept once (first one wins, by Ad.IdAttribute).
- Writes UTF-8 with BOM, sorted by Ad.IdAttribute, so the same directory gives the same file.

.EXAMPLE
./scripts/Export-AdUsers.ps1 -ProfilePath config/profiles/autodesk.psd1 -OutFile inputs/ad-snapshot.csv -Server dc1.corp.example
.EXAMPLE
./scripts/Export-AdUsers.ps1 -ProfilePath config/profiles/autodesk.psd1 -OutFile inputs/ad-snapshot.csv -UseGlobalCatalog
Several domains: use -UseGlobalCatalog, or list one -Server per domain. Some custom attributes are not in the
Global Catalog. If a column comes back blank, query each domain with -Server instead.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ProfilePath,
    [Parameter(Mandatory)] [string]$OutFile,
    [string[]]$Server,
    [string]$SearchBase,
    [switch]$UseGlobalCatalog
)
$ErrorActionPreference = 'Stop'

$adCfg = (Import-PowerShellDataFile -LiteralPath $ProfilePath).Ad
$attributes = @($adCfg.Attributes)
$idAttr = [string]$adCfg.IdAttribute
$managerAttr = [string]$adCfg.ManagerAttribute
$managerKey = [string]$adCfg.ManagerKeyAttribute
$managerColumns = @(if ($adCfg.ManagerColumns) { $adCfg.ManagerColumns } else { $idAttr })
foreach ($need in $idAttr, $managerAttr, $managerKey) {
    if ($attributes -notcontains $need) { throw "Ad.Attributes must include '$need' (named by the profile)." }
}

if (-not (Get-Command Get-ADUser -ErrorAction SilentlyContinue)) { Import-Module ActiveDirectory }

$servers = @(if ($Server) { $Server } elseif ($UseGlobalCatalog) { $env:USERDNSDOMAIN } else { $null })
if ($UseGlobalCatalog) { $servers = @($servers | ForEach-Object { if ($_ -match ':\d+$') { $_ } else { "${_}:3268" } }) }

function ConvertTo-CellText {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [datetime]) { return $Value.ToString('o') }
    if ($Value -is [System.Collections.IEnumerable]) { return (@($Value | ForEach-Object { [string]$_ }) -join ';') }
    [string]$Value
}

$query = @{ Filter = '*'; Properties = $attributes }
if ($SearchBase) { $query.SearchBase = $SearchBase }
$byId = [ordered]@{}
foreach ($s in $servers) {
    $q = $query.Clone()
    if ($s) { $q.Server = $s }
    foreach ($u in Get-ADUser @q) {
        $row = [ordered]@{}
        foreach ($a in $attributes) { $row[$a] = ConvertTo-CellText $u.$a }
        $id = $row[$idAttr]
        if ($id -and -not $byId.Contains($id)) { $byId[$id] = $row }
    }
}

# Manager reference -> manager record. In AD the reference is a DN, so ManagerKeyAttribute is distinguishedName.
$byKey = @{}
foreach ($row in $byId.Values) { if ($row[$managerKey]) { $byKey[$row[$managerKey]] = $row } }
$outside = @{}
foreach ($row in $byId.Values) {
    $ref = $row[$managerAttr]
    $mgr = if ($ref) { $byKey[$ref] } else { $null }
    if ($ref -and -not $mgr) {
        if (-not $outside.ContainsKey($ref)) {
            $outside[$ref] = $null
            foreach ($s in $servers) {
                try {
                    $q = @{ Identity = $ref; Properties = $managerColumns }
                    if ($s) { $q.Server = $s }
                    $m = Get-ADUser @q
                    $found = [ordered]@{}
                    foreach ($c in $managerColumns) { $found[$c] = ConvertTo-CellText $m.$c }
                    $outside[$ref] = $found
                    break
                }
                catch { Write-Verbose "Manager not found via server '$s'." }
            }
        }
        $mgr = $outside[$ref]
    }
    foreach ($c in $managerColumns) { $row["manager_$c"] = if ($mgr) { $mgr[$c] } else { '' } }
}

$ids = [string[]]@($byId.Keys)
[Array]::Sort($ids, [StringComparer]::Ordinal)
$dir = Split-Path -Parent $OutFile
if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$ids | ForEach-Object { [pscustomobject]$byId[$_] } | Export-Csv -LiteralPath $OutFile -Encoding utf8BOM
$enabledCol = [string]$adCfg.EnabledColumn
$off = @($byId.Values | Where-Object { $_.Contains($enabledCol) -and $_[$enabledCol] -ne [string]$adCfg.EnabledValue }).Count
Write-Host "Exported $($ids.Count) users ($off not enabled) to $OutFile"
