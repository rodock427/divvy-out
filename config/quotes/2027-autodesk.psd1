# FAKE quote for the sample data. Put the real quote in inputs/, never in git.
# Amounts: whole numbers, quoted strings ('12000.50'), or decimal literals (12000.50d). A bare 12000.50 is rejected.
@{
    Period         = '2027'
    Currency       = 'USD'
    SeatPrices     = @{            # key = exact offering name (after OfferingAliases); value = TOTAL price for that offering
        'Offering One'   = '48210.55'
        'Offering Two'   = '19333.33'
        'Offering Three' = '7777.77'
    }
    TokenPoolPrice = '61777.77'    # one price for the whole token pool
}
