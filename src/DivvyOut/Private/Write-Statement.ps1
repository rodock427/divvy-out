# Excel statements (spec 9.1, 9.7):
#   statements/<manager>.xlsx         one per charge owner: their direct reports only
#   statements/NO-OWNER.xlsx          NeedsOwner rows, for the owner only
#   statements/rollup/<manager>.xlsx  one per manager with managers beneath (Summary + one sheet per manager)
# Look: number first, one accent color, status = icon + word, no gridlines, thin hairlines, one font.

$script:Palette = @{
    Accent = '2a78d6'; Good = '0ca30c'; Warn = 'fab219'
    Text = '0b0b0b'; Text2 = '52514e'; Muted = '898781'; Hairline = 'e1e0d9'; White = 'ffffff'
}
$script:MoneyFormat = '$#,##0.00'

$script:XlColors = @{}
function Get-XlColor {
    param([string]$Name)
    if (-not $script:XlColors.ContainsKey($Name)) { $script:XlColors[$Name] = [System.Drawing.Color]::FromArgb([Convert]::ToInt32('FF' + $script:Palette[$Name], 16)) }
    $script:XlColors[$Name]
}

function Get-ShortId {
    param([string]$Key)
    $h = [System.Security.Cryptography.SHA1]::HashData([Text.Encoding]::UTF8.GetBytes($Key))
    -join ($h[0..2] | ForEach-Object { $_.ToString('x2') })
}

# Windows file name rules, checked here so the files work on the owner's laptop even when built elsewhere.
function ConvertTo-SafeFileName {
    param([string]$Name)
    $s = [regex]::Replace([string]$Name, '[<>:"/\\|?*\x00-\x1F]', '_').Trim().TrimEnd('.', ' ')
    if ($s.Length -gt 100) { $s = $s.Substring(0, 100).TrimEnd('.', ' ') }
    if (-not $s) { $s = '_' }
    if ($s -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$') { $s = '_' + $s }
    $s
}

# Key -> file base name. Names that clash (ignoring case) get a short ID from the key.
function Get-UniqueFileName {
    param([object[]]$Items)   # objects with Key and Name
    $out = @{}
    foreach ($g in $Items | Group-Object { (ConvertTo-SafeFileName $_.Name).ToLowerInvariant() }) {
        foreach ($i in $g.Group) {
            $base = ConvertTo-SafeFileName $i.Name
            $out[$i.Key] = if ($g.Count -gt 1 -or $base -ieq 'NO-OWNER') { "$base ($(Get-ShortId $i.Key))" } else { $base }
        }
    }
    $out
}

# Excel sheet name: 31 characters at most, no [ ] : * ? / \, no outer apostrophes, unique (ignoring case).
function ConvertTo-SheetName {
    param([string]$Name, [System.Collections.Generic.HashSet[string]]$Used, [string]$Key = $Name)
    $s = [regex]::Replace([string]$Name, '[\[\]:*?/\\]', '_').Trim().Trim("'")
    if (-not $s) { $s = 'Sheet' }
    if ($s.Length -gt 31) { $s = $s.Substring(0, 31).TrimEnd() }
    if ($Used.Contains($s)) {
        $suffix = ' ~' + (Get-ShortId $Key)
        $s = $s.Substring(0, [Math]::Min($s.Length, 31 - $suffix.Length)).TrimEnd() + $suffix
    }
    [void]$Used.Add($s)
    $s
}

# Workbooks are built in memory and written as bytes. EPPlus 4.5 Dispose() forces a full garbage collection,
# which costs ~0.2 s per file once the run's data is in memory (1,000 statements = minutes). A memory-only
# package holds no file handle, so it needs no Dispose.
function Save-XlPackage {
    param($Package, [string]$Path)
    [IO.File]::WriteAllBytes((Get-FullPath $Path), $Package.GetAsByteArray())
}

function Set-XlText {
    param($Cell, $Value, [string]$Color = 'Text', [int]$Size = 0, [switch]$Bold)
    $Cell.Value = $Value
    $Cell.Style.Font.Color.SetColor((Get-XlColor $Color))
    if ($Size) { $Cell.Style.Font.Size = $Size }
    if ($Bold) { $Cell.Style.Font.Bold = $true }
}

function Set-XlMoney {
    param($Cell, [decimal]$Value)
    $Cell.Value = $Value
    $Cell.Style.Numberformat.Format = $script:MoneyFormat
    $Cell.Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Right
}

function Set-XlPage {
    param($Ws)
    $Ws.View.ShowGridLines = $false
    $Ws.PrinterSettings.Orientation = [OfficeOpenXml.eOrientation]::Portrait
    $Ws.PrinterSettings.FitToPage = $true
    $Ws.PrinterSettings.FitToWidth = 1
    $Ws.PrinterSettings.FitToHeight = 0
}

# Header block: name + status chip, subtitle, draft/unrecovered lines, big total, count line. Returns the next free row.
function Write-XlHeader {
    param($Ws, $Result, [string]$Title, [string]$Subtitle, [decimal]$Total, [string]$CountLine, [int]$Width)
    Set-XlText $Ws.Cells[1, 1] $Title -Size 16 -Bold
    $chip = $Ws.Cells[1, $Width]
    $final = $Result.Status -eq 'FINAL'
    Set-XlText $chip $(if ($final) { [string][char]0x2713 + ' FINAL' } else { [string][char]0x26A0 + ' DRAFT' }) -Color $(if ($final) { 'White' } else { 'Text' }) -Bold
    $chip.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
    $chip.Style.Fill.BackgroundColor.SetColor((Get-XlColor $(if ($final) { 'Good' } else { 'Warn' })))
    $chip.Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Center
    Set-XlText $Ws.Cells[2, 1] $Subtitle -Color 'Text2'
    $r = 3
    if (-not $final) { Set-XlText $Ws.Cells[$r, 1] ('Draft: ' + ($Result.DraftReasons -join '; ') + '. Numbers may change.') -Color 'Text2'; $r++ }
    $un = $Result.Reconciliation.Unrecovered
    if ($un -gt 0) { Set-XlText $Ws.Cells[$r, 1] ('Not recovered: ' + $un.ToString('$#,##0.00', [cultureinfo]::InvariantCulture) + ' has a price but nobody to charge.') -Color 'Text2'; $r++ }
    $r++
    $big = $Ws.Cells[$r, 1]
    $big.Value = $Total
    $big.Style.Numberformat.Format = $script:MoneyFormat
    $big.Style.Font.Size = 26; $big.Style.Font.Bold = $true
    $big.Style.Font.Color.SetColor((Get-XlColor 'Accent'))
    $big.Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Left
    $Ws.Row($r).Height = 36
    $r++
    Set-XlText $Ws.Cells[$r, 1] $CountLine -Color 'Text2'
    $r + 2
}

function Get-PersonLabel {
    param($Row, $Result)
    if ($Row.User) { return $Row.User.Display }
    $vals = @(Get-IdentifierField $Result | ForEach-Object { ([string]$Row.Fields[$_]).Trim() } | Where-Object { $_ })
    if ($vals.Count) { $vals[0] } else { "Usage row $($Row.RowNumber)" }
}

# The statement table. Returns the next free row.
function Write-XlStatementTable {
    param($Ws, [int]$Row, [object[]]$Rows, $Result, [switch]$WithReason, [switch]$Freeze)
    $hasTeam = $Result.Config.Usage.Columns.Contains('Team')
    $hasCc = [bool]$Result.Config.Ad.CostCenter
    $cols = @(
        @{ H = 'Person'; W = 26 }
        if ($hasTeam) { @{ H = 'Team'; W = 18 } }
        @{ H = 'Offering'; W = 22 }
        @{ H = 'Access'; W = 9 }
        @{ H = 'Tokens'; W = 10; Right = $true }
        @{ H = 'Seat charge'; W = 13; Right = $true }
        @{ H = 'Token charge'; W = 13; Right = $true }
        @{ H = 'Charge'; W = 13; Right = $true }
        if ($hasCc) { @{ H = 'Cost center'; W = 20 } }
        if ($WithReason) { @{ H = 'Why no owner'; W = 18 } }
    )
    for ($c = 1; $c -le $cols.Count; $c++) {
        $cell = $Ws.Cells[$Row, $c]
        Set-XlText $cell $cols[$c - 1].H -Bold
        if ($cols[$c - 1]['Right']) { $cell.Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Right }
        $cell.Style.Border.Bottom.Style = [OfficeOpenXml.Style.ExcelBorderStyle]::Thin
        $cell.Style.Border.Bottom.Color.SetColor((Get-XlColor 'Text2'))
        if ($Ws.Column($c).Width -lt $cols[$c - 1].W) { $Ws.Column($c).Width = $cols[$c - 1].W }
    }
    if ($Freeze) { $Ws.View.FreezePanes($Row + 1, 1) }

    $sorted = @(Get-SortedByKey $Rows { param($x) "{0}`0{1}`0{2:D9}" -f (Get-PersonLabel $x $Result), $x.Package, $x.RowNumber })
    $total = [decimal]0
    $off = if ($hasTeam) { 1 } else { 0 }
    $n = $cols.Count
    $first = $Row + 1
    $last = $Row + $sorted.Count
    if ($sorted.Count) {
        # Style whole ranges once (per-cell styling is slow with 1,000 statements).
        $data = $Ws.Cells[$first, 1, $last, $n]
        $data.Style.Font.Color.SetColor((Get-XlColor 'Text'))
        $data.Style.Border.Bottom.Style = [OfficeOpenXml.Style.ExcelBorderStyle]::Hair
        $data.Style.Border.Bottom.Color.SetColor((Get-XlColor 'Hairline'))
        $tokRange = $Ws.Cells[$first, (4 + $off), $last, (4 + $off)]
        $tokRange.Style.Numberformat.Format = '#,##0'
        $tokRange.Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Right
        $moneyRange = $Ws.Cells[$first, (5 + $off), $last, (7 + $off)]
        $moneyRange.Style.Numberformat.Format = $script:MoneyFormat
        $moneyRange.Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Right
    }
    foreach ($x in $sorted) {
        $Row++
        $c = 1
        $Ws.Cells[$Row, $c].Value = Get-PersonLabel $x $Result; $c++
        if ($hasTeam) { $Ws.Cells[$Row, $c].Value = [string]$x.Fields['Team']; $c++ }
        $Ws.Cells[$Row, $c].Value = $x.PackageRaw; $c++
        $Ws.Cells[$Row, $c].Value = $(if ($x.Access -eq 'Token') { 'Tokens' } else { 'Seat' }); $c++
        $tok = $Ws.Cells[$Row, $c]
        if ($x.Access -eq 'Token') {
            $tok.Value = $x.Tokens
            if ($x.Tokens -ne [decimal]::Truncate($x.Tokens)) { $tok.Style.Numberformat.Format = '#,##0.00' }
        }
        else { $tok.Value = [string][char]0x2013 }
        $Ws.Cells[$Row, ($c + 1)].Value = $x.SeatCharge
        $Ws.Cells[$Row, ($c + 2)].Value = $x.TokenCharge
        $Ws.Cells[$Row, ($c + 3)].Value = $x.RowTotal
        $c += 4
        if ($hasCc) { $Ws.Cells[$Row, $c].Value = [string]$x.CostCenter; $c++ }
        if ($WithReason) { $Ws.Cells[$Row, $c].Value = [string]$x.Reason }
        $total += $x.RowTotal
    }
    $Row++
    Set-XlText $Ws.Cells[$Row, 1] 'Total' -Bold
    $tc = $Ws.Cells[$Row, (7 + $(if ($hasTeam) { 1 } else { 0 }))]
    Set-XlMoney $tc $total
    $tc.Style.Font.Bold = $true
    for ($c = 1; $c -le $cols.Count; $c++) {
        $Ws.Cells[$Row, $c].Style.Border.Top.Style = [OfficeOpenXml.Style.ExcelBorderStyle]::Thin
        $Ws.Cells[$Row, $c].Style.Border.Top.Color.SetColor((Get-XlColor 'Text2'))
    }
    $Row + 1
}

# Sheet 2: plain-English lines with the real numbers for these rows.
function Write-XlExplanation {
    param($Ws, [object[]]$Rows, $Result)
    $inv = [cultureinfo]::InvariantCulture
    $m = { param([decimal]$d) $d.ToString('$#,##0.00', $inv) }
    $lines = [System.Collections.Generic.List[object]]::new()
    $add = { param([string]$t, [string]$style = '') $lines.Add(@{ T = $t; S = $style }) }
    & $add 'How this was calculated' 'title'
    & $add "$($Result.Config.Vendor) · $($Result.Quote.Period) renewal · run $($Result.RunId) · $($Result.Started.ToString('yyyy-MM-dd')) · $($Result.Status)" 'sub'
    & $add ''
    & $add 'Each person is charged a fixed amount for the year, from the new quote and last year''s usage.' ''
    & $add 'People who are not here (left, disabled, or not found) are not charged. Their share is spread over everyone else.' ''
    & $add 'Each amount is rounded to the cent. Some charges are 1 cent higher so that every price is covered exactly.' ''
    $seat = @($Rows | Where-Object { $_.Access -eq 'Seat' -and $_.PoolSeatRows })
    if ($seat.Count) {
        & $add ''; & $add 'Seat charges' 'head'
        foreach ($g in $seat | Group-Object Package | Sort-Object Name) {
            $x = $g.Group[0]
            & $add ("{0}: price {1} ÷ {2} seats = {3} per seat." -f $g.Name, (& $m $x.OfferingPrice), $x.PoolSeatRows, (& $m ([decimal]::Round($x.OfferingPrice / $x.PoolSeatRows, 2)))) ''
        }
    }
    $tok = @($Rows | Where-Object { $_.Access -eq 'Token' -and $_.PoolTokens })
    if ($tok.Count) {
        $x = $tok[0]
        & $add ''; & $add 'Token charges' 'head'
        & $add ("Token pool: price {0} ÷ {1} tokens used = {2} per token (shown rounded; the exact rate is used)." -f (& $m ($x.TokenRate * $x.PoolTokens)), $x.PoolTokens.ToString('#,##0.##', $inv), $x.TokenRate.ToString('$0.0000##', $inv)) ''
        & $add 'Each token row pays tokens used × rate.' ''
    }
    $ov = @($Rows | Where-Object Override)
    if ($ov.Count) {
        & $add ''; & $add 'Changes made by hand (overrides)' 'head'
        foreach ($x in $ov) {
            $o = $x.Override
            $what = @(
                if ($x.LinkOverride) { 'matched to this person by hand' }
                if ($o.Manager) { "manager set to $($x.ManagerName)" }
                if ($o.CostCenter) { "cost center set to $($o.CostCenter)" }
                if ($o.Include) { 'charged although disabled in the directory' }
            ) -join ', '
            $who = (@($o.By, $o.Date) | Where-Object { $_ }) -join ', '
            & $add ("{0}, {1}: {2}. {3}{4}" -f (Get-PersonLabel $x $Result), $x.PackageRaw, $what, $o.Reason, $(if ($who) { " ($who)" } else { '' })) ''
        }
    }
    if ($Result.Status -ne 'FINAL') { & $add ''; & $add ('DRAFT because: ' + ($Result.DraftReasons -join '; ') + '.') 'head' }
    $r = 0
    foreach ($l in $lines) {
        $r++
        $cell = $Ws.Cells[$r, 1]
        switch ($l.S) {
            'title' { Set-XlText $cell $l.T -Size 16 -Bold }
            'sub' { Set-XlText $cell $l.T -Color 'Text2' }
            'head' { Set-XlText $cell $l.T -Bold }
            default { if ($l.T) { Set-XlText $cell $l.T } }
        }
    }
    $Ws.Column(1).Width = 120
    Set-XlPage $Ws
}

function Get-Subtitle { param($Result, [string]$Extra = '') ((@($Result.Config.Vendor, "$($Result.Quote.Period) renewal", $Extra, "run $($Result.RunId)") | Where-Object { $_ }) -join ' · ') }

function Get-CountLine {
    param([object[]]$Rows)
    $seat = [decimal]0; $tok = [decimal]0
    $people = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($r in $Rows) { $seat += $r.SeatCharge; $tok += $r.TokenCharge; [void]$people.Add($(if ($r.User) { $r.User.Id } else { "row$($r.RowNumber)" })) }
    $inv = [cultureinfo]::InvariantCulture
    '{0} {1} · Seats {2} · Tokens {3}' -f $people.Count, $(if ($people.Count -eq 1) { 'person' } else { 'people' }), $seat.ToString('$#,##0.00', $inv), $tok.ToString('$#,##0.00', $inv)
}

function Save-StatementFile {
    param([string]$Path, $Result, [string]$Title, [object[]]$Rows, [switch]$NoOwner)
    $pkg = [OfficeOpenXml.ExcelPackage]::new()
    $ws = Add-Worksheet -ExcelPackage $pkg -WorksheetName 'Statement'
    $total = [decimal]0; foreach ($r in $Rows) { $total += $r.RowTotal }
    $width = 7 + [int]$Result.Config.Usage.Columns.Contains('Team') + [int][bool]$Result.Config.Ad.CostCenter + [int][bool]$NoOwner
    $next = Write-XlHeader $ws $Result $Title (Get-Subtitle $Result $(if ($NoOwner) { 'for the owner only' })) $total (Get-CountLine $Rows) $width
    if (-not $Rows.Count -and $NoOwner) { Set-XlText $ws.Cells[$next, 1] 'Every charged row has an owner.' -Color 'Text2'; $next += 2 }
    [void](Write-XlStatementTable $ws $next $Rows $Result -WithReason:$NoOwner -Freeze)
    Set-XlPage $ws
    Write-XlExplanation (Add-Worksheet -ExcelPackage $pkg -WorksheetName 'How this was calculated') $Rows $Result
    Save-XlPackage $pkg $Path
}

# A node's own direct charge plus every node beneath, down LevelsLeft levels (-1 = all).
function Get-TeamTotal {
    param($Node, [int]$LevelsLeft)
    $t = $Node.DirectTotal
    if ($LevelsLeft -ne 0) { foreach ($c in $Node.Children) { $t += Get-TeamTotal $c $(if ($LevelsLeft -lt 0) { -1 } else { $LevelsLeft - 1 }) } }
    $t
}

function Save-RollupFile {
    param([string]$Path, $Result, $Node)
    $depth = $Result.Config.Rollup.Depth
    $maxTabs = [Math]::Max(1, $Result.Config.Rollup.MaxTabs)
    $sub = @(Get-SubtreeNodes $Node $depth)
    $below = @($sub | Select-Object -Skip 1)
    $rows = @($sub | Where-Object { $_.Node.Direct } | ForEach-Object { $_.Node.Direct.Rows })
    $team = Get-TeamTotal $Node $(if ($depth -eq 0) { -1 } else { $depth })
    $people = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($r in $rows) { [void]$people.Add($(if ($r.User) { $r.User.Id } else { "row$($r.RowNumber)" })) }

    $pkg = [OfficeOpenXml.ExcelPackage]::new()
    $ws = Add-Worksheet -ExcelPackage $pkg -WorksheetName 'Summary'
    $count = '{0} manager{1} below you · {2} people' -f $below.Count, $(if ($below.Count -eq 1) { '' } else { 's' }), $people.Count
    $row = Write-XlHeader $ws $Result $Node.Name (Get-Subtitle $Result 'Roll-up') $team $count 4
    $heads = 'Manager', 'People', 'Direct charge', 'With teams below'
    for ($c = 1; $c -le 4; $c++) {
        $cell = $ws.Cells[$row, $c]
        Set-XlText $cell $heads[$c - 1] -Bold
        if ($c -gt 1) { $cell.Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Right }
        $cell.Style.Border.Bottom.Style = [OfficeOpenXml.Style.ExcelBorderStyle]::Thin
        $cell.Style.Border.Bottom.Color.SetColor((Get-XlColor 'Text2'))
    }
    $ws.Column(1).Width = 34; $ws.Column(2).Width = 10; $ws.Column(3).Width = 16; $ws.Column(4).Width = 18
    $ws.View.FreezePanes($row + 1, 1)
    $sumPeople = 0; $sumDirect = [decimal]0
    foreach ($s in $sub) {
        $row++
        $n = $s.Node
        $p = if ($n.Direct) { $n.Direct.People.Count } else { 0 }
        Set-XlText $ws.Cells[$row, 1] $(if ($s.Level -eq 0) { "$($n.Name) (direct)" } else { $n.Name })
        $ws.Cells[$row, 1].Style.Indent = [Math]::Max(0, $s.Level - 1) * 2
        $ws.Cells[$row, 2].Value = $p
        Set-XlMoney $ws.Cells[$row, 3] $n.DirectTotal
        $t = if ($s.Level -eq 0) { $n.DirectTotal } else { Get-TeamTotal $n $(if ($depth -eq 0) { -1 } else { $depth - $s.Level }) }
        Set-XlMoney $ws.Cells[$row, 4] $t
        for ($c = 1; $c -le 4; $c++) {
            $ws.Cells[$row, $c].Style.Border.Bottom.Style = [OfficeOpenXml.Style.ExcelBorderStyle]::Hair
            $ws.Cells[$row, $c].Style.Border.Bottom.Color.SetColor((Get-XlColor 'Hairline'))
        }
        $sumPeople += $p; $sumDirect += $n.DirectTotal
    }
    $row++
    Set-XlText $ws.Cells[$row, 1] 'Total' -Bold
    $ws.Cells[$row, 2].Value = $sumPeople; $ws.Cells[$row, 2].Style.Font.Bold = $true
    Set-XlMoney $ws.Cells[$row, 3] $sumDirect; $ws.Cells[$row, 3].Style.Font.Bold = $true
    for ($c = 1; $c -le 4; $c++) { $ws.Cells[$row, $c].Style.Border.Top.Style = [OfficeOpenXml.Style.ExcelBorderStyle]::Thin }
    $row += 2
    Set-XlText $ws.Cells[$row, 1] 'The total adds the Direct charge column only. "With teams below" includes the managers beneath, so adding it would count people twice.' -Color 'Text2'
    $row++
    Set-XlText $ws.Cells[$row, 1] 'These charges are assigned to the managers listed.' -Color 'Text2'

    # Detail sheets: own direct reports first, then each manager below (depth first), up to MaxTabs sheets in all.
    $used = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$used.Add('Summary')
    $withRows = @($sub | Where-Object { $_.Node.Direct })
    $room = $maxTabs - 1
    $omitted = [Math]::Max(0, $withRows.Count - $room)
    foreach ($s in $withRows | Select-Object -First ([Math]::Max(0, $room))) {
        $n = $s.Node
        $name = ConvertTo-SheetName $(if ($s.Level -eq 0) { "$($n.Name) (direct)" } else { $n.Name }) $used $n.Key
        $sh = Add-Worksheet -ExcelPackage $pkg -WorksheetName $name
        Set-XlText $sh.Cells[1, 1] $n.Name -Size 14 -Bold
        Set-XlText $sh.Cells[2, 1] (Get-CountLine $n.Direct.Rows) -Color 'Text2'
        [void](Write-XlStatementTable $sh 4 $n.Direct.Rows.ToArray() $Result -Freeze)
        Set-XlPage $sh
    }
    if ($omitted) {
        $row++
        Set-XlText $ws.Cells[$row, 1] "$omitted managers have no sheet in this file (Rollup.MaxTabs = $maxTabs). The table above lists everyone." -Color 'Text2'
    }
    Set-XlPage $ws
    Save-XlPackage $pkg $Path
}

function Write-Statement {
    param([Parameter(Mandatory)] $Result, [Parameter(Mandatory)] [string]$Dir, [switch]$NoStatements, [switch]$NoRollups)
    $stDir = Join-Path $Dir 'statements'
    $ruDir = Join-Path $stDir 'rollup'
    New-Item -ItemType Directory -Force -Path $stDir | Out-Null
    if (-not $NoStatements) {
        $groups = @(Get-ManagerSummary $Result)
        $managers = @($groups | Where-Object Key -ne '~NO OWNER')
        $names = Get-UniqueFileName $managers
        foreach ($g in $managers) { Save-StatementFile (Join-Path $stDir "$($names[$g.Key]).xlsx") $Result $g.Name $g.Rows.ToArray() }
        $noOwner = @($groups | Where-Object Key -eq '~NO OWNER' | ForEach-Object { $_.Rows })
        Save-StatementFile (Join-Path $stDir 'NO-OWNER.xlsx') $Result 'NO OWNER' $noOwner -NoOwner
    }

    $tree = Get-OrgTree $Result
    if ($NoRollups -or -not $Result.Config.Rollup.Enabled) { return }
    $tops = @($tree.Nodes.Values | Where-Object { $_.Children.Count -and -not $_.InLoop })
    if (-not $tops.Count) { return }
    New-Item -ItemType Directory -Force -Path $ruDir | Out-Null
    $names = Get-UniqueFileName $tops
    foreach ($n in $tops) { Save-RollupFile (Join-Path $ruDir "$($names[$n.Key]).xlsx") $Result $n }
}
