function Test-DivvyOutInput {
    <#
    .SYNOPSIS
    Checks the profile, quote, usage file, and directory snapshot, and prints the match report.
    Charges nothing and writes no files.
    Returns the result object. Look at .Issues.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]$Profile,
        [Parameter(Mandatory)] [object]$Quote,
        [Parameter(Mandatory)] [string]$Usage,
        [Parameter(Mandatory)] [string]$Ad,
        [string]$Overrides
    )
    $result = New-DivvyResult
    Read-DivvyInput -Result $result -ProfileSource $Profile -QuoteSource $Quote -UsagePath $Usage -AdPath $Ad -OverridesPath $Overrides
    $result.Status = if (Get-IssueCount $result Error) { 'INVALID' } else { 'VALIDATED' }
    if ($result.Status -eq 'VALIDATED') {
        Resolve-UserMatch -Result $result
        foreach ($line in $result.MatchReport.Lines) { Write-Host "  $line" }
    }
    foreach ($i in $result.Issues) { Write-Host ('{0,-7} {1,-22} {2}' -f $i.Level.ToUpper(), $i.Code, $i.Message) }
    Write-Host "Inputs: $($result.Status)"
    $result
}
