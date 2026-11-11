# FAKE quote for the user-only list sample. Put the real quote in inputs/, never in git.
# One product. Its name must match Usage.FixedValues.Package in the profile.
# Amounts: whole numbers, quoted strings ('12000.50'), or decimal literals (12000.50d). A bare 12000.50 is rejected.
@{
    Period     = '2027'
    Currency   = 'USD'
    SeatPrices = @{
        'Product' = '12000.00'     # TOTAL price, split equally over the people on the list
    }
}
