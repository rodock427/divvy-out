# Reads the usage report (CSV or XLSX), maps headers to canonical fields, applies offering aliases,
# maps access option text to access kinds, and parses tokens.

function Read-TabularFile {
    param([string]$Path, [int]$HeaderRow, [string]$Encoding, [string]$Sheet)
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($ext) {
        '.csv' {
            $rows = if ($HeaderRow -eq 1) { @(Import-Csv -LiteralPath $Path -Encoding $Encoding) }
            else { @(Get-Content -LiteralPath $Path -Encoding $Encoding | Select-Object -Skip ($HeaderRow - 1) | ConvertFrom-Csv) }
            $headers = if ($rows.Count) { @($rows[0].PSObject.Properties.Name) } else { @() }
            return @{ Headers = $headers; Rows = $rows }
        }
        '.xlsx' {
            $params = @{ Path = $Path; StartRow = $HeaderRow }
            if ($Sheet) { $params.WorksheetName = $Sheet }
            $rows = @(Import-Excel @params)
            $headers = if ($rows.Count) { @($rows[0].PSObject.Properties.Name) } else { @() }
            return @{ Headers = $headers; Rows = $rows }
        }
        default { Stop-Divvy "Usage file type '$ext' is not supported. Use .csv or .xlsx." }
    }
}

function Import-UsageFile {
    param([Parameter(Mandatory)] [string]$Path, [Parameter(Mandatory)] $Config, [Parameter(Mandatory)] $Quote, [Parameter(Mandatory)] $Result)
    $u = $Config.Usage
    try { $file = Read-TabularFile -Path $Path -HeaderRow $u.HeaderRow -Encoding $u.Encoding -Sheet $u.Sheet }
    catch {
        if ($_.Exception.Data['DivvyStop']) { throw }
        $msg = $_.Exception.Message.Replace($Path, '<usage file>')
        Add-Issue $Result Error UsageUnreadable "Could not read the usage file ($($_.Exception.GetType().Name)): $msg"
        return
    }
    $Result.Usage.Headers = $file.Headers
    $Result.Usage.RowCount = $file.Rows.Count
    if ($file.Rows.Count -eq 0) { Add-Issue $Result Error UsageEmpty 'The usage file has no data rows (check Usage.HeaderRow and Usage.Sheet).'; return }

    # Canonical field -> actual header. Header match ignores case and outer spaces.
    $map = [ordered]@{}
    foreach ($field in $u.Columns.Keys) {
        $want = $u.Columns[$field]
        $hit = @($file.Headers | Where-Object { $_.Trim() -eq $want })
        if ($hit.Count -eq 0) { Add-Issue $Result Error MissingUsageColumn "Canonical field '$field' maps to header '$want', which is not in the usage file." }
        else { $map[$field] = $hit[0] }
    }
    if (Get-IssueCount $Result Error) { return }

    $kindByText = @{}   # access option text -> kind (case-insensitive)
    foreach ($k in $u.AccessOptionValues.Keys) { $kindByText[$u.AccessOptionValues[$k]] = $k }

    $unknownAccess = @{}; $badTokens = [System.Collections.Generic.List[int]]::new()
    $seatTokens = [System.Collections.Generic.List[int]]::new(); $seatBadTokens = [System.Collections.Generic.List[int]]::new()
    $rows = [System.Collections.Generic.List[object]]::new()
    $n = 0
    foreach ($obj in $file.Rows) {
        $n++
        $rowNumber = $u.HeaderRow + $n   # row number as the owner sees it in Excel or a text editor
        $source = [ordered]@{}
        foreach ($h in $file.Headers) { $source[$h] = [string]$obj.$h }
        $fields = [ordered]@{}
        foreach ($field in $map.Keys) { $fields[$field] = $source[$map[$field]] }
        # Skip fully blank lines (Excel often leaves some at the end).
        if (-not (@($source.Values) -join '').Trim()) { continue }

        $packageRaw = ([string]$fields['Package']).Trim()
        $package = if ($u.OfferingAliases.ContainsKey($packageRaw)) { $u.OfferingAliases[$packageRaw] } else { $packageRaw }
        if ($Quote.OfferingNames.ContainsKey($package)) { $package = $Quote.OfferingNames[$package] }

        $accessText = ([string]$fields['AccessOption']).Trim()
        $kind = $kindByText[$accessText]
        if (-not $kind) {
            if (-not $unknownAccess.ContainsKey($accessText)) { $unknownAccess[$accessText] = [System.Collections.Generic.List[int]]::new() }
            $unknownAccess[$accessText].Add($rowNumber)
        }

        $tokenText = ([string]$fields['Tokens']).Trim()
        $tokens = ConvertTo-Quantity $tokenText
        if ($kind -eq 'Token' -and $null -eq $tokens) { $badTokens.Add($rowNumber) }
        if ($kind -eq 'Seat') {
            if ($tokenText -and $null -eq $tokens) { $seatBadTokens.Add($rowNumber) }
            elseif ($tokens -gt 0) { $seatTokens.Add($rowNumber) }
        }

        $rows.Add([pscustomobject]@{
                RowNumber = $rowNumber; Source = $source; Fields = $fields
                Package = $package; PackageRaw = $packageRaw; AccessText = $accessText; Access = $kind
                Tokens = if ($kind -eq 'Token') { $tokens } else { [decimal]0 }
                # Filled in later stages:
                MatchStatus = $null; MatchRule = $null; MatchValue = $null; MatchDirValue = $null; Candidates = @(); User = $null
                PreferEnabledDropped = $false; DisabledSkipped = $false
                Override = $null; LinkOverride = $null; State = $null; Reason = $null; MovedToSeat = $false; TokensBeforeSeat = $null
                ManagerDirId = $null; ManagerDirName = $null; ManagerId = $null; ManagerName = $null; ManagerSource = $null
                CostCenterRaw = $null; CostCenter = $null
                OfferingPrice = $null; PoolSeatRows = $null; TokenRate = $null; PoolTokens = $null
                SeatCharge = [decimal]0; TokenCharge = [decimal]0; RowTotal = [decimal]0
            })
    }
    $Result.Rows = $rows.ToArray()

    $known = ($u.AccessOptionValues.Values | ForEach-Object { "'$_'" }) -join ', '
    foreach ($text in Get-OrdinalSorted @($unknownAccess.Keys)) {
        $shown = if ($text.Length -gt 40) { $text.Substring(0, 40) + '...' } else { $text }
        Add-Issue $Result Error UnknownAccessOption "Access option '$shown' is not one of $known (Usage.AccessOptionValues)." -Rows $unknownAccess[$text].ToArray()
    }
    if ($badTokens.Count) { Add-Issue $Result Error InvalidTokens "Token rows with a blank, negative, or non-numeric token count (digits only, no commas)." -Rows $badTokens.ToArray() }
    if ($seatTokens.Count) { Add-Issue $Result Warning SeatTokensIgnored 'Seat rows with tokens > 0. The tokens are ignored.' -Rows $seatTokens.ToArray() }
    if ($seatBadTokens.Count) { Add-Issue $Result Warning SeatTokensIgnored 'Seat rows with a non-numeric token value. The value is ignored.' -Rows $seatBadTokens.ToArray() }

    # Every offering with a seat row needs a seat price (after aliases).
    $unpriced = @{}
    foreach ($r in $rows) {
        if ($r.Access -eq 'Seat' -and -not $Quote.SeatPrices.ContainsKey($r.Package)) {
            if (-not $unpriced.ContainsKey($r.Package)) { $unpriced[$r.Package] = [System.Collections.Generic.List[int]]::new() }
            $unpriced[$r.Package].Add($r.RowNumber)
        }
    }
    foreach ($name in Get-OrdinalSorted @($unpriced.Keys)) {
        Add-Issue $Result Error UnpricedOffering "Offering '$name' has seat rows but no price in the quote. Check Usage.OfferingAliases." -Rows $unpriced[$name].ToArray()
    }
    if (@($rows | Where-Object Access -eq 'Token').Count -and $null -eq $Quote.TokenPoolPrice) {
        Add-Issue $Result Error QuoteInvalid 'The usage file has token rows but the quote has no TokenPoolPrice.'
    }
}
