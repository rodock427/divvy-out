# Autodesk charge rule. Only the charge math for this vendor lives here (spec Section 12).
# Seat rows split the offering's price equally. Token rows share one token pool by tokens used.
$script:VendorRules['Autodesk'] = @{
    Name           = 'Autodesk'
    RequiredFields = @('Package', 'AccessOption', 'Tokens')
    AccessKinds    = @('Seat', 'Token')
    Allocate       = 'Invoke-AutodeskAllocation'
}
