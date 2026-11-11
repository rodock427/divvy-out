# exceptions.csv (spec 10): one line per problem row (or per issue with no rows). Owner-only: shows values.
function Write-Exceptions {
    param([Parameter(Mandatory)] $Result, [Parameter(Mandatory)] [string]$Path)
    $ids = Get-IdentifierField $Result
    $usage = @{}; foreach ($r in $Result.Rows) { $usage[$r.RowNumber] = $r }
    $ovr = @{}; foreach ($o in $Result.Overrides.Items) { $ovr[$o.RowNumber] = $o }
    $lines = foreach ($i in $Result.Issues) {
        $base = [ordered]@{ Level = $i.Level; Code = $i.Code; File = $i.Source; Row = ''; Identifier = ''; Offering = ''; Message = $i.Message; Detail = $i.Detail }
        if (-not $i.Rows.Count) { $base; continue }
        foreach ($n in $i.Rows) {
            $line = [ordered]@{} + $base
            $line.Row = $n
            if ($i.Source -eq 'usage' -and $usage.ContainsKey($n)) {
                $r = $usage[$n]
                $vals = @($ids | ForEach-Object { ([string]$r.Fields[$_]).Trim() } | Where-Object { $_ })
                $line.Identifier = if ($vals.Count) { $vals[0] } else { '' }
                $line.Offering = $r.PackageRaw
                if ($r.State) { $line.Detail = (@($i.Detail, "$($r.State) $($r.Reason)".Trim()) | Where-Object { $_ }) -join ' | ' }
            }
            elseif ($i.Source -eq 'overrides' -and $ovr.ContainsKey($n)) { $line.Identifier = $ovr[$n].Key; $line.Detail = '' }
            $line
        }
    }
    Export-DivvyCsv -Path $Path -Columns 'Level', 'Code', 'File', 'Row', 'Identifier', 'Offering', 'Message', 'Detail' -Rows @($lines)
}
