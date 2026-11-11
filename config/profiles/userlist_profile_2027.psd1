# DivvyOut input profile: a user-only list (UserList).
# The report is just the people who used one product: no product, access, or token columns.
# The price in the quote is split equally per person; a person listed twice pays one share.
# Everything about your report and directory lives here, never in code. The names below match the FAKE sample data.
@{
    Vendor = 'UserList'

    Usage = @{
        # Sheet   = 'Users'          # XLSX only. Default: the first sheet.
        HeaderRow = 1                 # row that holds the headers
        Encoding  = 'utf8'            # CSV only
        Columns   = @{                # canonical field = source HEADER NAME (case and outer spaces ignored)
            Email = 'User Email'      # add UserKey = '<header>' too if the list has a logon name column
        }
        # The report has no product or access column, so every row gets these. Package must match the
        # name in the quote's SeatPrices. AccessOption must match AccessOptionValues.Seat.
        FixedValues        = @{ Package = 'Product'; AccessOption = 'User' }
        AccessOptionValues = @{ Seat = 'User' }
    }

    Match = @{
        PreferEnabled   = $true           # with 2+ hits, drop disabled accounts first
        DisabledSoloHit = 'TryNextRule'   # only hit is disabled: 'TryNextRule' (look for a live account) or 'Stop'
        Rules = @(                        # tried in order; first single hit wins
            @{ UsageField = 'Email';   AdAttribute = 'mail';              Normalize = 'Trim', 'ToLower' }
            @{ UsageField = 'Email';   AdAttribute = 'userPrincipalName'; Normalize = 'Trim', 'ToLower' }
            # proxyAddresses holds every address joined by ';' (SMTP:primary;smtp:alias). Split and strip the prefix.
            @{ UsageField = 'Email';   AdAttribute = 'proxyAddresses';    Split = ';'; Normalize = 'Trim', 'ToLower', @{ Pattern = '^smtp:'; Replacement = '' } }
        )
    }

    Ad = @{
        # Columns Export-AdUsers.ps1 writes. Every attribute the profile names must be in the snapshot.
        Attributes          = 'objectGUID', 'sAMAccountName', 'userPrincipalName', 'mail', 'displayName', 'manager', 'distinguishedName', 'Enabled', 'proxyAddresses', 'costCenter', 'physicalDeliveryOfficeName'
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
        ManagerInfo         = @( @{ Label = 'Site'; Attribute = 'physicalDeliveryOfficeName' } )   # more: @{ Label = 'Region'; Attribute = 'extensionAttribute5' }
    }

    Charge = @{
        Owner = 'DirectManager'
    }

    Policy = @{
        UnusedQuoteOffering = 'Stop'          # quote offering with no usage rows: 'Stop' (unrecoverable) or 'Ignore'
        DuplicateSeatRows   = 'ChargeOnce'    # a person listed twice: the extra row is not charged (one share per person)
        BadOverride         = 'Draft'         # override that finds nobody / several people: 'Draft' or 'Warn'
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
