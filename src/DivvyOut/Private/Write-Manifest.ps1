# inputs/ (copies of every input file) and manifest.json (spec 9): run ID, tool version, status,
# input names, SHA-256 hashes and row counts, match report, reconciliation. Owner-only (has amounts).

# Copies each input file into <run>/inputs/ so the numbers can be rebuilt later. Same names; a clash
# between two inputs gets the role as a prefix.
function Copy-RunInput {
    param([Parameter(Mandatory)] $Result, [Parameter(Mandatory)] [string]$Dir)
    $target = Join-Path $Dir 'inputs'
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    $used = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($role in $Result.Inputs.Keys) {
        $i = $Result.Inputs[$role]
        if (-not $i.Path) { continue }
        $name = if ($used.Add($i.Name)) { $i.Name } else { "$($role.ToLowerInvariant())-$($i.Name)" }
        [void]$used.Add($name)
        Copy-Item -LiteralPath $i.Path -Destination (Join-Path $target $name)
        $i['Copy'] = "inputs/$name"
    }
}

function Write-Manifest {
    param([Parameter(Mandatory)] $Result, [Parameter(Mandatory)] [string]$Path)
    $counts = @{ Usage = $Result.Usage.RowCount; Directory = $Result.Directory.RowCount; Overrides = @($Result.Overrides.Items).Count }
    $inputs = [ordered]@{}
    foreach ($role in $Result.Inputs.Keys) {
        $i = $Result.Inputs[$role]
        $inputs[$role] = [ordered]@{
            Name   = $i.Name
            Sha256 = if ($i.Path) { (Get-FileHash -LiteralPath $i.Path -Algorithm SHA256).Hash } else { $null }
            Rows   = $counts[$role]
            Copy   = $i['Copy']
        }
    }
    $rec = $Result.Reconciliation
    $issues = [ordered]@{}
    foreach ($g in $Result.Issues | Group-Object Code | Sort-Object Name) { $issues[$g.Name] = $g.Count }
    $manifest = [ordered]@{
        RunId          = $Result.RunId
        Started        = $Result.Started.ToString('yyyy-MM-ddTHH:mm:sszzz')
        ToolVersion    = $Result.ToolVersion
        PowerShell     = $Result.PSVersion
        Modules        = $Result.ModuleVersions
        Vendor         = $Result.Config.Vendor
        Period         = $Result.Quote.Period
        Status         = $Result.Status
        DraftReasons   = @($Result.DraftReasons)
        Options        = [ordered]@{ AllowUnrecovered = [bool]$Result.Options.AllowUnrecovered; IncludeAmounts = [bool]$Result.Options.IncludeAmounts }
        Inputs         = $inputs
        MatchReport    = [ordered]@{ Lines = @($Result.MatchReport.Lines); Counts = $Result.MatchReport.Counts }
        RowStates      = [ordered]@{}
        Reconciliation = [ordered]@{
            QuoteTotal = Format-Money $rec.QuoteTotal; Allocated = Format-Money $rec.Allocated; Unrecovered = Format-Money $rec.Unrecovered
            Balanced = $rec.Balanced
            Pools = @($Result.Pools | ForEach-Object {
                    [ordered]@{ Name = $_.Name; Price = Format-Money $_.Price; Rows = $_.RowCount; Units = $_.Units.ToString([cultureinfo]::InvariantCulture)
                        Rate = if ($null -ne $_.Rate) { $_.Rate.ToString([cultureinfo]::InvariantCulture) } else { $null }
                        Allocated = Format-Money $_.Allocated; Unrecoverable = $_.Unrecoverable; Ignored = $_.Ignored }
                })
        }
        Issues         = $issues
    }
    foreach ($g in $Result.Rows | Group-Object State, Reason | Sort-Object Name) { $manifest.RowStates[$g.Name] = $g.Count }
    [IO.File]::WriteAllText($Path, ($manifest | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}
