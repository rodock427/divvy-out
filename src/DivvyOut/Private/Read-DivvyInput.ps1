# The one result object every stage fills and every writer reads (spec Section 9).
function New-DivvyResult {
    param([hashtable]$Options = @{})
    $excel = Get-Module ImportExcel | Select-Object -First 1
    [ordered]@{
        RunId          = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N').Substring(0, 4)
        Started        = Get-Date
        ToolVersion    = $script:ToolVersion
        PSVersion      = $PSVersionTable.PSVersion.ToString()
        Os             = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
        ModuleVersions = [ordered]@{ ImportExcel = if ($excel) { $excel.Version.ToString() } else { 'not loaded' } }
        Options        = $Options
        Inputs         = [ordered]@{}
        Config         = $null
        Quote          = $null
        Usage          = [ordered]@{ Headers = @(); RowCount = 0 }
        Directory      = [ordered]@{ Columns = @(); RowCount = 0; Users = @(); ById = $null }
        Overrides      = [ordered]@{ Columns = @(); Items = @() }
        Rows           = @()
        Issues         = [System.Collections.Generic.List[object]]::new()
        MatchReport    = $null
        Pools          = @()
        Reconciliation = $null
        OrgTree        = $null
        Status         = 'STARTED'
        DraftReasons   = [System.Collections.Generic.List[string]]::new()
        Fatal          = $null
        OutputDir      = $null
    }
}

# Loads every input and runs the checks in spec Section 5.5. Problems go to $Result.Issues.
function Read-DivvyInput {
    param([Parameter(Mandatory)] $Result, $ProfileSource, $QuoteSource, [string]$UsagePath, [string]$AdPath, [string]$OverridesPath)

    $inputs = [ordered]@{ Profile = $ProfileSource; Quote = $QuoteSource; Usage = $UsagePath; Directory = $AdPath; Overrides = $OverridesPath }
    foreach ($role in $inputs.Keys) {
        $src = $inputs[$role]
        if ($null -eq $src -or ($src -is [string] -and -not $src)) {
            if ($role -ne 'Overrides') { Add-Issue $Result Error MissingInput "No $role input was given." }
            continue
        }
        if ($src -is [System.Collections.IDictionary]) { $Result.Inputs[$role] = [ordered]@{ Path = $null; Name = '(in memory)'; Extension = '' }; continue }
        $full = Get-FullPath ([string]$src)
        $Result.Inputs[$role] = [ordered]@{ Path = $full; Name = [IO.Path]::GetFileName($full); Extension = [IO.Path]::GetExtension($full).ToLowerInvariant() }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { Add-Issue $Result Error MissingInput "The $role file was not found." }
    }
    if (Get-IssueCount $Result Error) { return }

    $Result.Config = Import-DivvyProfile -Source $ProfileSource -Result $Result
    if (Get-IssueCount $Result Error) { return }
    $Result.Quote = Import-DivvyQuote -Source $QuoteSource -Result $Result
    if (Get-IssueCount $Result Error) { return }
    Import-UsageFile -Path $UsagePath -Config $Result.Config -Quote $Result.Quote -Result $Result
    Import-AdSnapshot -Path $AdPath -Config $Result.Config -Result $Result
}
