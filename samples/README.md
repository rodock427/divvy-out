# Sample data (FAKE)

Every name, email, ID, and price here is invented. Rebuild with `pwsh -NoProfile -File samples/New-SampleData.ps1` (fixed seed).

The usage layout has 24 columns. Only `Team Alias`, `Offering Name`, `Source Email`, `Access Options`, and `Tokens Used`
come from the real report. `User Name` and the other columns are invented stand-ins.

Planted cases:

| Case | Expected result |
|---|---|
| 5-level org: CEO → VP → director → manager → staff | manager chain 4+ levels |
| CEO has usage, no manager | `NeedsOwner` / no manager |
| 12 disabled staff with usage | `NotHere` / `Disabled` |
| 1 disabled manager (7 reports) | reports are `NeedsOwner` / manager disabled |
| 8 old disabled accounts sharing a live mail | `PreferEnabled` picks the live one |
| 3 admin accounts sharing a live mail (both enabled) | `AmbiguousMatch` → `NeedsOwner` |
| 2 users whose only mail hit is a disabled old account | `DisabledSoloHit = TryNextRule` finds them by UPN |
| 8 usage emails that exist only in `proxyAddresses` | matched by the proxyAddresses rule |
| 4 rows with blank email, `CORP\sam` username | matched by a username rule |
| 12 former staff + 3 contractors not in the directory | `NotHere` / `NoMatch` |
| Manager loop A → B → C → A (+2 staff under A) | warned, left out of roll-ups |
| 2 staff whose manager DN is in another domain | `NeedsOwner` / manager not found |
| Duplicate seat rows, seat+token on one offering, seat rows with tokens | warnings |
| Emails in upper case with spaces | normalized |
| Team `=Team Formula` | written as text in CSV (formula escaping) |
| Offering `Offering 2 (Legacy)` | alias of `Offering Two` |
| Non-English names, cost centers with commas | UTF-8 and `,` → `-` |
| `Offering Four`: token rows only, not in the quote | charged from the token pool, no error (D82) |
| Every user has a `physicalDeliveryOfficeName` (site, by department) | `Ad.ManagerInfo` shows each manager's site in the summary, statements, roll-ups, dashboard |
| Quote has `SeatCounts` and `TokensPurchased` | dashboard: click an offering for the seat vs token comparison and ⚠ flags |
| `overrides.csv`: exclude, link, fix ambiguous, manager, cost center, include (on leave), tree fix, typo | M3 tests |
| `overrides.csv`: `SeatFor = Offering Two` for the heaviest token user of it | that person is charged one seat of Offering Two; their tokens leave the token pool (`MovedToSeat`) |
