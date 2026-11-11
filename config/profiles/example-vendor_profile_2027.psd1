# FAKE second vendor (M9 proof). A different report layout and an HR-style directory (not AD):
# employee numbers as IDs, manager by employee number, Status = Active, no tokens.
@{
    Vendor = 'ExampleVendor'

    Usage = @{
        HeaderRow = 1
        Columns   = @{
            Email        = 'Assigned User'
            Package      = 'Product'
            AccessOption = 'License Type'
            Team         = 'Department'
        }
        AccessOptionValues = @{ Seat = 'Named User' }
        OfferingAliases    = @{}
    }

    Match = @{
        PreferEnabled = $true
        Rules = @(
            @{ UsageField = 'Email'; AdAttribute = 'WorkEmail'; Normalize = 'Trim', 'ToLower' }
        )
    }

    Ad = @{
        Attributes          = 'EmployeeNo', 'FullName', 'WorkEmail', 'ManagerEmployeeNo', 'Status', 'CostCentre'
        IdAttribute         = 'EmployeeNo'
        EnabledColumn       = 'Status'
        EnabledValue        = 'Active'
        DisplayAttribute    = 'FullName'
        ManagerAttribute    = 'ManagerEmployeeNo'
        ManagerKeyAttribute = 'EmployeeNo'
        CostCenter          = @{ Attribute = 'CostCentre'; Replace = @( @{ From = ','; To = ' -' } ) }
    }

    Overrides = @{
        KeyRules = @(
            @{ UsageField  = 'Email';      Normalize = 'Trim', 'ToLower' }
            @{ AdAttribute = 'EmployeeNo'; Normalize = 'Trim' }
        )
        ManagerLookup = @{ AdAttribute = 'WorkEmail'; Normalize = 'Trim', 'ToLower' }
    }
}
