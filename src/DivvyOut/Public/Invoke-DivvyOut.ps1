function Invoke-DivvyOut {
    <#
    .SYNOPSIS
    Runs the chargeback: reads the inputs, matches users, charges managers, writes all outputs to output/<run-id>/.
    .EXAMPLE
    Invoke-DivvyOut -Profile config/profiles/autodesk_profile_2027.psd1 -Quote inputs/autodesk_quote_2027.psd1 -Usage inputs/autodesk_usage_2027.xlsx -Ad inputs/ad-snapshot.csv -Overrides inputs/overrides.csv
    .EXAMPLE
    Invoke-DivvyOut ... -Skip Statements, Rollups, Inputs      # numbers only, no Excel files, no input copies
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Profile,     # path to .psd1, or a hashtable
        [Parameter(Mandatory)] [object]$Quote,       # path to .psd1, or a hashtable
        [Parameter(Mandatory)] [string]$Usage,
        [Parameter(Mandatory)] [string]$Ad,
        [string]$Overrides,
        [string]$OutputRoot = 'output',
        [switch]$AllowUnrecovered,
        [switch]$IncludeAmounts,
        # Outputs not to write. diagnostics.txt and manifest.json are always written.
        [ValidateSet('Summary', 'NotFound', 'Exceptions', 'Statements', 'Rollups', 'Audit', 'Dashboard', 'Inputs')]
        [string[]]$Skip = @(),
        [switch]$PassThru
    )
    $result = New-DivvyResult -Options @{ AllowUnrecovered = [bool]$AllowUnrecovered; IncludeAmounts = [bool]$IncludeAmounts; Skip = @($Skip | Sort-Object -Unique) }
    $want = { param([string]$Name) $Skip -notcontains $Name }
    $runDir = Join-Path $OutputRoot $result.RunId
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    $result.OutputDir = (Resolve-Path -LiteralPath $runDir).Path
    $runDir = $result.OutputDir
    try {
        Read-DivvyInput -Result $result -ProfileSource $Profile -QuoteSource $Quote -UsagePath $Usage -AdPath $Ad -OverridesPath $Overrides
        Assert-NoError $result 'Input validation failed'
        Resolve-UserMatch -Result $result
        Resolve-Override -Result $result
        Assert-NoError $result 'Override file check failed'
        Resolve-Mapping -Result $result
        foreach ($line in $result.MatchReport.Lines) { Write-Host "  $line" }
        Invoke-Allocation -Result $result
        Set-RunStatus -Result $result
        [void](Get-OrgTree -Result $result)
        Assert-RollupCheck -Result $result
        # Writers: each takes the result object only (spec 9).
        if (& $want 'Summary') { Write-Summary -Result $result -Path (Join-Path $runDir 'summary-by-manager.csv') }
        if (& $want 'NotFound') {
            Write-NotFound -Result $result -Path (Join-Path $runDir 'not-found.csv')
            Write-OverridesTemplate -Result $result -Path (Join-Path $runDir 'overrides-template.csv')
        }
        if (& $want 'Exceptions') { Write-Exceptions -Result $result -Path (Join-Path $runDir 'exceptions.csv') }
        if ((& $want 'Statements') -or (& $want 'Rollups')) {
            Write-Statement -Result $result -Dir $runDir -NoStatements:(-not (& $want 'Statements')) -NoRollups:(-not (& $want 'Rollups'))
        }
        if (& $want 'Audit') { Write-Audit -Result $result -Path (Join-Path $runDir 'audit.csv') }
        if (& $want 'Dashboard') { Write-Dashboard -Result $result -Path (Join-Path $runDir 'dashboard.html') }
        if (& $want 'Inputs') { Copy-RunInput -Result $result -Dir $runDir }
        Write-Manifest -Result $result -Path (Join-Path $runDir 'manifest.json')
    }
    catch {
        $result.Status = 'FAILED'
        $result.Fatal = $_
        throw
    }
    finally {
        Write-Diagnostics -Result $result -Path (Join-Path $runDir 'diagnostics.txt')
    }
    $rec = $result.Reconciliation
    Write-Host "DivvyOut run $($result.RunId): $($result.Status)"
    foreach ($reason in $result.DraftReasons) { Write-Host "  DRAFT because: $reason" }
    Write-Host ('  Quote {0}  Allocated {1}  Unrecovered {2}' -f (Format-Money $rec.QuoteTotal), (Format-Money $rec.Allocated), (Format-Money $rec.Unrecovered))
    Write-Host "  Output: $($result.OutputDir)"
    if ($PassThru) { $result }
}
