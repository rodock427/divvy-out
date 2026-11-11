# Guards for the project's hard rules (spec Section 2, NFR-5, money as [decimal]).
BeforeDiscovery {
    $script:SrcFiles = Get-ChildItem (Join-Path (Split-Path -Parent $PSScriptRoot) 'src') -Recurse -Filter *.ps*1 |
        ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
}

Describe 'Hard rules in src/' {
    It '<Name> has no hard-coded directory attribute or report header names' -ForEach $SrcFiles {
        # Quoted literals only, case-sensitive: these names belong in the profile.
        # ('Enabled' is not listed: it is also the profile key Rollup.Enabled.)
        $forbidden = 'mail', 'sAMAccountName', 'userPrincipalName', 'objectGUID', 'displayName', 'distinguishedName',
        'manager', 'proxyAddresses', 'costCenter', 'Seats', 'Source Email', 'Offering Name', 'Access Options',
        'Tokens Used', 'Team Alias', 'User Name'
        $text = Get-Content -LiteralPath $Path -Raw
        foreach ($f in $forbidden) {
            $text | Should -Not -MatchExactly ("['""]" + [regex]::Escape($f) + "['""]") -Because "'$f' must come from the profile"
        }
    }

    It '<Name> never uses [double]' -ForEach $SrcFiles {
        Get-Content -LiteralPath $Path -Raw | Should -Not -Match '\[double\]'
    }

    It '<Name> never sums with Measure-Object (it returns [double])' -ForEach $SrcFiles {
        Get-Content -LiteralPath $Path -Raw | Should -Not -Match 'Measure-Object[^\r\n|]*-Sum'
    }
}
