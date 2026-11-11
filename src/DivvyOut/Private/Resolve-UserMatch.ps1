# Normalize options (spec 5.2), applied in the order listed, to both sides of a compare.
function ConvertTo-NormalizedValue {
    param([string]$Value, [object[]]$Steps)
    if ($null -eq $Value) { return '' }
    $v = $Value
    foreach ($s in $Steps) {
        if ($s -is [System.Collections.IDictionary]) { $v = [regex]::Replace($v, $s.Pattern, $s.Replacement); continue }
        switch ($s) {
            'Trim' { $v = $v.Trim() }
            'ToLower' { $v = $v.ToLowerInvariant() }
            'StripDomainPrefix' { $i = $v.LastIndexOf('\'); if ($i -ge 0) { $v = $v.Substring($i + 1) } }
            'StripUpnSuffix' { $i = $v.IndexOf('@'); if ($i -ge 0) { $v = $v.Substring(0, $i) } }
        }
    }
    $v
}
