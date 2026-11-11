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
        Invoke-Allocation -Result $result
        foreach ($line in $result.MatchReport.Lines) { Write-Host "  $line" }
        $result.Status = 'VALIDATED'
    }
    catch {
        $result.Status = 'FAILED'
        $result.Fatal = $_
        throw
    }
    finally {
        Write-Diagnostics -Result $result -Path (Join-Path $runDir 'diagnostics.txt')
    }
    Write-Host "DivvyOut run $($result.RunId): $($result.Status). Output: $($result.OutputDir)"
    if ($PassThru) { $result }
}
