# ExampleVendor: a FAKE second vendor. It proves that a new vendor needs only a profile and a rule file
# (spec M9): no change to the core.
#
# Named-user licences: each offering's price is split equally per PERSON (not per row). A person with
# several rows in one offering pays one share, split over those rows. No tokens.
$script:VendorRules['ExampleVendor'] = @{
    Name           = 'ExampleVendor'
    RequiredFields = @('Package', 'AccessOption')
    AccessKinds    = @('Seat')
    Allocate       = 'Invoke-PerPersonAllocation'   # same math as UserList: Rules/UserList.ps1
}
