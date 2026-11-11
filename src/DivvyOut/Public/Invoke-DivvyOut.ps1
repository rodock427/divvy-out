function Invoke-DivvyOut {
    <#
    .SYNOPSIS
    Runs the chargeback: reads the inputs, matches users, charges managers, writes all outputs to output/<run-id>/.
    .EXAMPLE
    Invoke-DivvyOut -Profile config/profiles/autodesk.psd1 -Quote inputs/2027-autodesk.psd1 -Usage inputs/usage.xlsx -Ad inputs/ad-snapshot.csv -Overrides inputs/overrides.csv
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
        [switch]$PassThru
    )
    $result = New-DivvyResult -Options @{ AllowUnrecovered = [bool]$AllowUnrecovered; IncludeAmounts = [bool]$IncludeAmounts }
    $runDir = Join-Path $OutputRoot $result.RunId
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    $result.OutputDir = (Resolve-Path -LiteralPath $runDir).Path
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
        # Writers: each takes the result object only (spec 9).
        Write-Summary -Result $result -Path (Join-Path $runDir 'summary-by-manager.csv')
        Write-NotFound -Result $result -Path (Join-Path $runDir 'not-found.csv')
        Write-OverridesTemplate -Result $result -Path (Join-Path $runDir 'overrides-template.csv')
        Write-Exceptions -Result $result -Path (Join-Path $runDir 'exceptions.csv')
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
