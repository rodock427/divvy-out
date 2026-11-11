<#
.SYNOPSIS
Builds the FAKE sample dataset in samples/. Fixed seed, so the output is the same every run
(except the .xlsx container timestamps). Every name, email, ID, and price here is invented.

Contents (see samples/README.md for the full list of planted cases):
  ad-snapshot.csv   ~330 directory users: 5-level org, disabled users, a disabled manager,
                    old disabled duplicates, ambiguous shared mailboxes, a manager loop,
                    managers missing from the snapshot, non-English names, cost centers with commas
  autodesk_usage_2027.csv/.xlsx   ~400 usage rows in the 24-column fake layout
  overrides.csv     sample overrides (exclude, link, manager, cost center, include, tree fix, typo, SeatFor)
#>
param([string]$OutDir = $PSScriptRoot, [int]$Seed = 2027)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
$rnd = [System.Random]::new($Seed)
$pick = { param([object[]]$list) $list[$rnd.Next($list.Count)] }
$chance = { param([double]$p) $rnd.NextDouble() -lt $p }

$firstNames = 'Alex', 'Priya', 'Sam', 'Lena', 'Tomas', 'Dana', 'Marcus', 'Hannah', 'José', 'Zoë', 'Søren', 'Łukasz', 'Ngọc', 'Chloé',
'Björn', 'Aoife', 'Mehmet', 'Yuki', 'Olusegun', 'Ana', 'Fatima', 'Raúl', 'Ingrid', 'Dmitri', 'Wei', 'Siobhán', 'Jürgen', 'Noémie',
'Kofi', 'Mateus', 'Ewa', 'Rania', 'Hiroshi', 'Inés', 'Pål', 'Thảo', 'Ömer', 'Beatriz', 'Leilani', 'Nikolai'
$lastNames = 'Rivera', 'Nair', 'Okafor', 'Fischer', 'Brandt', 'Whitfield', 'Lee', 'Cole', 'Núñez', 'Müller', 'Østergaard', 'Wójcik',
'Nguyễn', 'Lefèvre', 'Åström', 'Ó Briain', 'Yılmaz', 'Tanaka', 'Adeyemi', 'Silva', 'Haddad', 'García', 'Lindqvist', 'Ivanov',
'Zhang', 'Ní Bhriain', 'Schäfer', 'Dubois', 'Mensah', 'Costa', 'Kowalska', 'Saleh', 'Sato', 'Peña', 'Hansen', 'Trần', 'Çelik',
'Souza', 'Kahale', 'Petrov'
$departments = 'Design', 'Engineering', 'Operations', 'Research'
$sites = 'North Campus', 'Harbor Office', 'Remote'   # by department, no random draw (keeps every planted case in place)

function ConvertTo-AsciiName([string]$s) {
    foreach ($pair in @(@('ø', 'o'), @('Ø', 'O'), @('ł', 'l'), @('Ł', 'L'), @('đ', 'd'), @('ı', 'i'), @('ß', 'ss'), @('æ', 'ae'))) { $s = $s.Replace($pair[0], $pair[1]) }
    $d = $s.Normalize([Text.NormalizationForm]::FormD)
    $plain = -join ($d.ToCharArray() | Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' })
    ($plain.ToLowerInvariant() -replace '[^a-z0-9]', '')
}

$users = [System.Collections.Generic.List[object]]::new()
$usedSam = @{}; $usedMail = @{}
function New-FakeUser {
    param([string]$First, [string]$Last, [object]$Manager, [string]$Dept, [string]$Ou = 'Staff', [switch]$Disabled,
        [string]$Sam, [string]$Mail, [string]$Upn, [string[]]$Aliases = @())
    $f = ConvertTo-AsciiName $First; $l = ConvertTo-AsciiName $Last
    if (-not $Sam) {
        $base = ($f.Substring(0, 1) + $l); if ($base.Length -gt 18) { $base = $base.Substring(0, 18) }
        $Sam = $base; $n = 1
        while ($usedSam.ContainsKey($Sam)) { $n++; $Sam = "$base$n" }
    }
    $usedSam[$Sam] = $true
    if (-not $PSBoundParameters.ContainsKey('Mail')) {
        $baseMail = "$f.$l"; $Mail = "$baseMail@corp.example"; $n = 1
        while ($usedMail.ContainsKey($Mail)) { $n++; $Mail = "$baseMail$n@corp.example" }
    }
    if ($Mail) { $usedMail[$Mail] = $true }
    if (-not $Upn) { $Upn = "$Sam@ad.corp.example" }
    $bytes = [byte[]]::new(16); $rnd.NextBytes($bytes)
    $proxy = @(if ($Mail) { "SMTP:$Mail" }) + @($Aliases | ForEach-Object { "smtp:$_" })
    $u = [pscustomobject][ordered]@{
        objectGUID        = ([guid]::new($bytes)).ToString()
        sAMAccountName    = $Sam
        userPrincipalName = $Upn
        mail              = $Mail
        displayName       = "$First $Last"
        manager           = if ($Manager) { $Manager.distinguishedName } else { '' }
        distinguishedName = "CN=$Last\, $First ($Sam),OU=$Ou,DC=corp,DC=example"
        Enabled           = if ($Disabled) { 'False' } else { 'True' }
        proxyAddresses    = $proxy -join ';'
        costCenter        = ('{0}, {1}, Corporate' -f (4100 + $departments.IndexOf($Dept) * 100 + $rnd.Next(10)), $Dept)
        physicalDeliveryOfficeName = $sites[[Math]::Max(0, $departments.IndexOf($Dept)) % $sites.Count]
    }
    $users.Add($u)
    $u
}
$randomPerson = { @{ First = & $pick $firstNames; Last = & $pick $lastNames } }

# --- Org: CEO -> 4 VPs -> 12 directors -> 36 managers -> 252 staff (5 levels) ---
$ceo = New-FakeUser 'Morgan' 'Avery' $null 'Operations' -Ou 'Leadership'
$managers = [System.Collections.Generic.List[object]]::new()
$staff = [System.Collections.Generic.List[object]]::new()
foreach ($dept in $departments) {
    $p = & $randomPerson; $vp = New-FakeUser $p.First $p.Last $ceo $dept -Ou 'Leadership'
    foreach ($d in 1..3) {
        $p = & $randomPerson; $dir = New-FakeUser $p.First $p.Last $vp $dept -Ou 'Leadership'
        foreach ($m in 1..3) {
            $p = & $randomPerson; $mgr = New-FakeUser $p.First $p.Last $dir $dept -Ou 'Managers'
            $managers.Add($mgr)
            foreach ($s in 1..7) { $p = & $randomPerson; $staff.Add((New-FakeUser $p.First $p.Last $mgr $dept)) }
        }
    }
}

# --- Planted cases ---
$disabledManager = $managers[5]; $disabledManager.Enabled = 'False'                 # their 7 reports: NeedsOwner/ManagerDisabled
$departedStaff = @($staff | Where-Object { $_.manager -ne $disabledManager.distinguishedName } | Select-Object -First 12 -Skip 20)
foreach ($u in $departedStaff) { $u.Enabled = 'False' }                            # NotHere/Disabled
$live = @($staff | Where-Object { $_.Enabled -eq 'True' -and $_.manager -ne $disabledManager.distinguishedName })

# Old disabled accounts that share a mail with a live account (PreferEnabled drops them).
$withOldAccount = @($live | Select-Object -Skip 40 -First 8)
foreach ($u in $withOldAccount) {
    $old = New-FakeUser 'Old' 'Account' $null 'Operations' -Ou 'Disabled' -Disabled -Sam "old-$($u.sAMAccountName)" -Mail $u.mail
    $old.displayName = "$($u.displayName) (old)"
}
# Two enabled accounts with one mail: AmbiguousMatch.
$sharedMail = @($live | Select-Object -Skip 60 -First 3)
foreach ($u in $sharedMail) { [void](New-FakeUser 'Admin' 'Account' $u 'Operations' -Ou 'Admins' -Sam "adm-$($u.sAMAccountName)" -Mail $u.mail) }
# Only hit on mail is a disabled old account; the live account has the address as UPN (DisabledSoloHit = TryNextRule).
$movedAccount = @($live | Select-Object -Skip 70 -First 2)
foreach ($u in $movedAccount) {
    $address = $u.mail
    [void](New-FakeUser 'Moved' 'Account' $null 'Operations' -Ou 'Disabled' -Disabled -Sam "prev-$($u.sAMAccountName)" -Mail $address)
    $u.mail = $address.Replace('@corp.example', '@new.corp.example'); $u.userPrincipalName = $address
}
# Alias addresses that only appear in proxyAddresses.
$aliasUsers = @($live | Select-Object -Skip 80 -First 8)
foreach ($u in $aliasUsers) { $u.proxyAddresses += ";smtp:$($u.sAMAccountName)@legacy.corp.example" }
# Manager loop: A -> B -> C -> A, plus two staff under A.
$loopA = New-FakeUser 'Loop' 'Alpha' $null 'Research' -Ou 'Managers'
$loopB = New-FakeUser 'Loop' 'Beta' $loopA 'Research' -Ou 'Managers'
$loopC = New-FakeUser 'Loop' 'Gamma' $loopB 'Research' -Ou 'Managers'
$loopA.manager = $loopC.distinguishedName
$loopStaff = @(1..2 | ForEach-Object { $p = & $randomPerson; New-FakeUser $p.First $p.Last $loopA 'Research' })
# Manager DN that is not in the snapshot (other domain): NeedsOwner/ManagerNotFound.
$ghostStaff = @(1..2 | ForEach-Object { $p = & $randomPerson; $u = New-FakeUser $p.First $p.Last $null 'Engineering'; $u.manager = 'CN=Partner\, Pat (ppartner),OU=Staff,DC=partner,DC=example'; $u })
# No manager at all.
$noManager = New-FakeUser 'Casey' 'Contractor' $null 'Operations' -Ou 'Contractors'
# A manager with no usage rows whose own manager is wrong in the directory (fixed by an override, tree only).
$treeFix = $managers[10]

# --- Usage rows ---
$offerSeat = 'Offering One', 'Offering Two', 'Offering 2 (Legacy)', 'Offering Three'
$offerToken = 'Offering One', 'Offering Two', 'Offering Three', 'Offering Four'
$teams = 'Team Alpha', 'Team Beta', 'Team Gamma', '=Team Formula'      # last one tests CSV formula escaping
$usage = [System.Collections.Generic.List[object]]::new()
$usageKeyFor = { param($u)
    switch ($rnd.Next(4)) { 0 { '' } 1 { $u.userPrincipalName } 2 { "CORP\$($u.sAMAccountName)" } 3 { $u.sAMAccountName } } }
function Add-Usage {
    param([string]$Email, [string]$Offering, [string]$Access, $Tokens = '', [string]$UserKey = '', [string]$First = '', [string]$Last = '')
    $usage.Add([pscustomobject][ordered]@{
            'Team ID'           = 'T{0:D4}' -f $rnd.Next(10000)
            'Team Alias'        = & $pick $teams
            'Team Name'         = 'Fake Team'
            'Offering ID'       = 'OFF-{0:D3}' -f $rnd.Next(1000)
            'Offering Name'     = $Offering
            'Product Line Code' = & $pick 'ACD', 'RVT', 'INVPROSA', 'MAYA'
            'Source Email'      = $Email
            'User Name'         = $UserKey
            'First Name'        = $First
            'Last Name'         = $Last
            'Access Options'    = $Access
            'Tokens Used'       = [string]$Tokens
            'Country'           = & $pick 'US', 'DE', 'JP', 'BR', 'PL'
            'Region'            = & $pick 'AMER', 'EMEA', 'APAC'
            'Last Used Date'    = ('2026-{0:D2}-{1:D2}' -f ($rnd.Next(12) + 1), ($rnd.Next(28) + 1))
            'Assigned Date'     = '2025-{0:D2}-01' -f ($rnd.Next(12) + 1)
            'Status'            = 'Active'
            'Contract Number'   = 'C-{0:D6}' -f $rnd.Next(1000000)
            'Seat Type'         = 'Named'
            'Usage Type'        = $Access
            'Machine Name'      = 'PC-{0:D5}' -f $rnd.Next(100000)
            'Version'           = '2026'
            'Department'        = 'n/a'
            'Notes'             = ''
        })
}
function Add-PersonUsage {
    param($u, [string]$Email = $u.mail, [switch]$Seat, [switch]$Token)
    $names = $u.displayName.Split(' ', 2)
    $key = & $usageKeyFor $u
    if (-not $Seat -and -not $Token) { $Seat = & $chance 0.75; $Token = (-not $Seat) -or (& $chance 0.3) }
    if ($Seat) { Add-Usage $Email (& $pick $offerSeat) 'Seats' '' $key $names[0] $names[1] }
    if ($Token) { Add-Usage $Email (& $pick $offerToken) 'Tokens' ($rnd.Next(0, 40) * 500) $key $names[0] $names[1] }
}

$everyone = @($users | Where-Object { $_.sAMAccountName -notmatch '^(old|adm|prev)-' -and $_ -ne $treeFix })
foreach ($u in $everyone) {
    if ($u -in $aliasUsers) { Add-PersonUsage $u -Email "$($u.sAMAccountName)@legacy.corp.example"; continue }
    if ($u -in $movedAccount) { Add-PersonUsage $u -Email $u.userPrincipalName; continue }
    if ($u -in $managers -or $u.distinguishedName -match 'OU=Leadership') { if (& $chance 0.5) { continue } }
    Add-PersonUsage $u
}
# Departed people who are not in the directory at all: NoMatch.
foreach ($i in 1..12) { $p = & $randomPerson; Add-Usage ("former.person$i@corp.example") (& $pick $offerSeat) 'Seats' '' '' $p.First $p.Last }
foreach ($i in 1..3) { Add-Usage ("freelancer$i@contractor.example") 'Offering Four' 'Tokens' ($rnd.Next(1, 20) * 500) }
# Blank email, username only: matched by a fallback rule.
foreach ($u in @($live | Select-Object -Skip 100 -First 4)) { Add-Usage '' 'Offering One' 'Seats' '' "CORP\$($u.sAMAccountName)" }
# Same user, same offering, two seat rows.
foreach ($u in @($live | Select-Object -Skip 110 -First 2)) { Add-Usage $u.mail 'Offering Three' 'Seats'; Add-Usage $u.mail 'Offering Three' 'Seats' }
# Same user, seat and token row on one offering.
foreach ($u in @($live | Select-Object -Skip 120 -First 3)) { Add-Usage $u.mail 'Offering One' 'Seats'; Add-Usage $u.mail 'Offering One' 'Tokens' 2500 }
# Seat rows with tokens > 0 (ignored, warned).
foreach ($u in @($live | Select-Object -Skip 130 -First 3)) { Add-Usage $u.mail 'Offering Two' 'Seats' 1500 }
# Mixed case and spaces in emails (normalize must handle).
foreach ($u in @($live | Select-Object -Skip 140 -First 3)) { Add-Usage ("  " + $u.mail.ToUpperInvariant() + " ") 'Offering Two' 'Seats' }

# Stable row order: shuffle once with the seeded generator so planted cases are spread out.
$rows = $usage.ToArray()
for ($i = $rows.Count - 1; $i -gt 0; $i--) { $j = $rnd.Next($i + 1); $t = $rows[$i]; $rows[$i] = $rows[$j]; $rows[$j] = $t }

# --- Overrides ---
# SeatFor: the heaviest live token user of Offering Two whose only usage row is that token row
# (so no seat under another spelling or alias). Picked without a random draw.
$liveMail = @{}; foreach ($u in $live) { if ($u.mail) { $liveMail[$u.mail] = $true } }
$rowsPerMail = @{}; foreach ($r in $rows) { $m = $r.'Source Email'.Trim().ToLowerInvariant(); $rowsPerMail[$m] = 1 + $(if ($rowsPerMail.ContainsKey($m)) { $rowsPerMail[$m] } else { 0 }) }
$seatFor = @($rows | Where-Object { $_.'Offering Name' -eq 'Offering Two' -and $_.'Access Options' -eq 'Tokens' -and $liveMail.ContainsKey($_.'Source Email') -and $rowsPerMail[$_.'Source Email'] -eq 1 } |
        Sort-Object @{ e = { [int]$_.'Tokens Used' }; Descending = $true }, @{ e = { $_.'Source Email' } })[0].'Source Email'
$excluded = $live[150]
$linkTarget = $live[151]
$overrides = @(
    [pscustomobject][ordered]@{ Key = $excluded.mail; Manager = ''; CostCenter = ''; Exclude = 'Y'; Include = ''; LinkTo = ''; SeatFor = ''; Reason = 'Left in October'; By = 'owner'; Date = '2026-11-01' }
    [pscustomobject][ordered]@{ Key = 'freelancer1@contractor.example'; Manager = ''; CostCenter = ''; Exclude = ''; Include = ''; LinkTo = $linkTarget.sAMAccountName; SeatFor = ''; Reason = 'Personal address of a staff member'; By = 'owner'; Date = '2026-11-01' }
    [pscustomobject][ordered]@{ Key = $sharedMail[0].mail; Manager = ''; CostCenter = ''; Exclude = ''; Include = ''; LinkTo = "CORP\$($sharedMail[0].sAMAccountName)"; SeatFor = ''; Reason = 'Shared mailbox, real user'; By = 'owner'; Date = '2026-11-01' }
    [pscustomobject][ordered]@{ Key = $ghostStaff[0].sAMAccountName; Manager = $managers[0].mail; CostCenter = ''; Exclude = ''; Include = ''; LinkTo = ''; SeatFor = ''; Reason = 'Manager is in another domain'; By = 'owner'; Date = '2026-11-01' }
    [pscustomobject][ordered]@{ Key = $live[160].mail; Manager = ''; CostCenter = '9999, Special Projects, Corporate'; Exclude = ''; Include = ''; LinkTo = ''; SeatFor = ''; Reason = 'Billed to project'; By = 'owner'; Date = '2026-11-01' }
    [pscustomobject][ordered]@{ Key = $departedStaff[0].sAMAccountName; Manager = ''; CostCenter = ''; Exclude = ''; Include = 'Y'; LinkTo = ''; SeatFor = ''; Reason = 'On leave, still charged'; By = 'owner'; Date = '2026-11-01' }
    [pscustomobject][ordered]@{ Key = $treeFix.sAMAccountName; Manager = $managers[11].mail; CostCenter = ''; Exclude = ''; Include = ''; LinkTo = ''; SeatFor = ''; Reason = 'Reorg not in AD yet'; By = 'owner'; Date = '2026-11-01' }
    [pscustomobject][ordered]@{ Key = $seatFor; Manager = ''; CostCenter = ''; Exclude = ''; Include = ''; LinkTo = ''; SeatFor = 'Offering Two'; Reason = 'Heavy token user, seat in the new quote'; By = 'owner'; Date = '2026-11-01' }
    [pscustomobject][ordered]@{ Key = 'nobody.here@corp.example'; Manager = ''; CostCenter = ''; Exclude = 'Y'; Include = ''; LinkTo = ''; SeatFor = ''; Reason = 'Typo on purpose: finds nobody'; By = 'owner'; Date = '2026-11-01' }
)

# --- Write ---
$adPath = Join-Path $OutDir 'ad-snapshot.csv'
$users | Sort-Object objectGUID | Export-Csv $adPath -Encoding utf8BOM
$rows | Export-Csv (Join-Path $OutDir 'autodesk_usage_2027.csv') -Encoding utf8BOM
$xlsx = Join-Path $OutDir 'autodesk_usage_2027.xlsx'
Remove-Item $xlsx -ErrorAction SilentlyContinue
$rows | Export-Excel $xlsx -WorksheetName 'Usage' 3>$null
$overrides | Export-Csv (Join-Path $OutDir 'overrides.csv') -Encoding utf8BOM
Write-Host "Fake data: $($users.Count) directory users, $($rows.Count) usage rows, $($overrides.Count) overrides -> $OutDir"
