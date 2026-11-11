# DivvyOut input profile: Autodesk.
# Everything that depends on your report layout or your directory lives here, never in code.
# The header names below match the FAKE sample data in samples/. Replace them with your real names.
@{
    Vendor = 'Autodesk'

    Usage = @{
        # Sheet   = 'Usage'          # XLSX only. Default: the first sheet.
        HeaderRow = 1                 # row that holds the headers
        Encoding  = 'utf8'            # CSV only
        Columns   = @{                # canonical field = source HEADER NAME (case and outer spaces ignored)
            Team         = 'Team Alias'
            Package      = 'Offering Name'
            Email        = 'Source Email'
            UserKey      = 'User Name'
            AccessOption = 'Access Options'
            Tokens       = 'Tokens Used'
        }
        AccessOptionValues = @{ Seat = 'Seats'; Token = 'Tokens' }   # exact text in the report
        OfferingAliases    = @{                                      # 'Name in report' = 'Name in quote'
            'Offering 2 (Legacy)' = 'Offering Two'
        }
    }

    Match = @{
        PreferEnabled   = $true           # with 2+ hits, drop disabled accounts first
        DisabledSoloHit = 'TryNextRule'   # only hit is disabled: 'TryNextRule' (look for a live account) or 'Stop'
        Rules = @(                        # tried in order; first single hit wins
            @{ UsageField = 'Email';   AdAttribute = 'mail';              Normalize = 'Trim', 'ToLower' }
            @{ UsageField = 'Email';   AdAttribute = 'userPrincipalName'; Normalize = 'Trim', 'ToLower' }
            # proxyAddresses holds every address joined by ';' (SMTP:primary;smtp:alias). Split and strip the prefix.
            @{ UsageField = 'Email';   AdAttribute = 'proxyAddresses';    Split = ';'; Normalize = 'Trim', 'ToLower', @{ Pattern = '^smtp:'; Replacement = '' } }
            @{ UsageField = 'UserKey'; AdAttribute = 'userPrincipalName'; Normalize = 'Trim', 'ToLower' }
            @{ UsageField = 'UserKey'; AdAttribute = 'sAMAccountName';    Normalize = 'Trim', 'ToLower', 'StripDomainPrefix', 'StripUpnSuffix' }
        )
    }

    Ad = @{
        # Columns Export-AdUsers.ps1 writes. Every attribute the profile names must be in the snapshot.
        Attributes          = 'objectGUID', 'sAMAccountName', 'userPrincipalName', 'mail', 'displayName', 'manager', 'distinguishedName', 'Enabled', 'proxyAddresses', 'costCenter'
        IdAttribute         = 'objectGUID'          # unique user ID. The run stops if values repeat.
        EnabledColumn       = 'Enabled'
        EnabledValue        = 'True'
        DisplayAttribute    = 'displayName'         # name shown on statements
        ManagerAttribute    = 'manager'             # column that points to the manager
        ManagerKeyAttribute = 'distinguishedName'   # the manager's column that ManagerAttribute holds (AD: a DN)
        ManagerColumns      = 'objectGUID', 'mail', 'displayName'   # Export-AdUsers adds manager_<name> columns (info only)
        CostCenter          = @{ Attribute = 'costCenter'; Replace = @( @{ From = ','; To = '-' } ) }   # optional; delete to hide
        # Optional: extra manager columns in the summary, statements, roll-ups and dashboard, from each manager's own record.
        # Each Attribute must also be in Attributes. Order is kept.
        # ManagerInfo       = @( @{ Label = 'Region'; Attribute = 'extensionAttribute5' }, @{ Label = 'Site'; Attribute = 'physicalDeliveryOfficeName' } )
    }

    Charge = @{
        Owner = 'DirectManager'
    }

    Policy = @{
        UnusedQuoteOffering = 'Stop'          # quote offering with no usage rows: 'Stop' (unrecoverable) or 'Ignore'
        DuplicateSeatRows   = 'ChargeEach'    # same user, same offering, 2+ seat rows: 'ChargeEach' or 'ChargeOnce'
        BadOverride         = 'Draft'         # override that finds nobody / several people: 'Draft' or 'Warn'
    }

    Dashboard = @{
        SeatCandidatePercent = 100   # flag a token user when their token cost on an offering reaches this % of one seat
    }

    Rollup = @{
        Enabled = $true
        Depth   = 0       # 0 = all levels
        MaxTabs = 50      # sheets per roll-up workbook. The Summary always lists everyone.
    }

    Overrides = @{
        KeyRules = @(     # how the Key (and LinkTo) column finds a person; first single hit wins
            @{ UsageField  = 'Email';          Normalize = 'Trim', 'ToLower' }
            @{ AdAttribute = 'sAMAccountName'; Normalize = 'Trim', 'ToLower', 'StripDomainPrefix' }
        )
        ManagerLookup = @{ AdAttribute = 'mail'; Normalize = 'Trim', 'ToLower' }
    }
}
