<#
.SYNOPSIS
One-command run for non-developers. Loads the module from this repo and runs Invoke-DivvyOut.
.EXAMPLE
./scripts/Invoke-DivvyOut.ps1 -Profile config/profiles/autodesk.psd1 -Quote inputs/2027-autodesk.psd1 -Usage inputs/usage.xlsx -Ad inputs/ad-snapshot.csv -Overrides inputs/overrides.csv
#>
param(
    [Parameter(Mandatory)] [string]$Profile,
    [Parameter(Mandatory)] [string]$Quote,
    [Parameter(Mandatory)] [string]$Usage,
    [Parameter(Mandatory)] [string]$Ad,
    [string]$Overrides,
    [string]$OutputRoot = 'output',
    [switch]$AllowUnrecovered,
    [switch]$IncludeAmounts,
    [ValidateSet('Summary', 'NotFound', 'Exceptions', 'Statements', 'Rollups', 'Audit', 'Dashboard', 'Inputs')]
    [string[]]$Skip
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../src/DivvyOut/DivvyOut.psd1') -Force
Invoke-DivvyOut @PSBoundParameters
