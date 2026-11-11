# DivvyOut

Charges internal software cost to each user's manager. v1: Autodesk.

You give it the vendor quote, the usage report, a directory export, and your manual fixes. It charges each user a fixed share of the **new** quote, by **last year's** usage, and groups the charges by manager. Users who are not here are not charged; their share is spread over everyone else.

- Full spec: [chargeback-tool-spec.md](chargeback-tool-spec.md)
- Choices made where the spec was silent: [DECISIONS.md](DECISIONS.md)

## Requirements

- PowerShell 7 (`pwsh`). Not Windows PowerShell 5.1.
- `ImportExcel` module: `Install-Module ImportExcel -Scope CurrentUser`
- For the directory export only: RSAT Active Directory module (`Get-ADUser`).
- For the tests only: Pester 5 or later.

## Try it on the fake sample data

```powershell
./scripts/Invoke-DivvyOut.ps1 -Profile config/profiles/autodesk_profile_2027.psd1 -Quote config/quotes/autodesk_quote_2027.psd1 `
    -Usage samples/autodesk_usage_2027.xlsx -Ad samples/ad-snapshot.csv -Overrides samples/overrides.csv
```

It prints the match report and the status, and writes everything to `output/<run-id>/`. The sample run is `DRAFT` on purpose (planted problems: see [samples/README.md](samples/README.md)).

## Run it on real data

Keep real files in `inputs/`. Git ignores `inputs/` and `output/`. Never put real data anywhere else in this folder. File names: `<vendor>_<profile|quote|usage>_<year>`, for example `autodesk_quote_2028.psd1`.

1. **Profile.** Copy `config/profiles/autodesk_profile_2027.psd1` and set your real names: the usage report headers (`Usage.Columns`), the access option text, the match rules, and the directory attribute names (`Ad`). Nothing about your report or directory is in the code; it is all in the profile. For a vendor that gives only a list of users, start from `config/profiles/userlist_profile_2027.psd1` instead: see "Vendors that give only a list of users". Optional: `Ad.ManagerInfo` adds directory attributes of each manager (for example a region) to the summary, statements, roll-ups, and dashboard.
2. **Quote.** Copy `config/quotes/autodesk_quote_2027.psd1` to `inputs/` and enter the real prices. Write amounts as `12000`, `'12000.50'`, or `12000.50d` (a bare `12000.50` is rejected). Optional: `SeatCounts` and `TokensPurchased` (what was bought) turn on the seat vs token comparison on the dashboard. They never change charges.
3. **Directory snapshot.**
   ```powershell
   ./scripts/Export-AdUsers.ps1 -ProfilePath inputs/autodesk_profile_2027.psd1 -OutFile inputs/ad-snapshot.csv -Server dc1.corp.example
   ```
   Several domains: add one `-Server` per domain. The export has enabled and disabled users, and shows progress as it reads.

   Avoid `-UseGlobalCatalog` unless you need it. The Global Catalog does not hold every attribute, so some columns can come back blank, with no error. Before you run, open the snapshot and check that every column the profile names has values. `diagnostics.txt` also counts blank cost centers and blank manager info.
4. **Check the inputs** (writes nothing, prints the match report and every problem):
   ```powershell
   Import-Module ./src/DivvyOut/DivvyOut.psd1
   $check = Test-DivvyOutInput -Profile inputs/autodesk_profile_2027.psd1 -Quote inputs/autodesk_quote_2027.psd1 -Usage inputs/autodesk_usage_2027.xlsx -Ad inputs/ad-snapshot.csv -Overrides inputs/overrides.csv
   ```
5. **Run.**
   ```powershell
   ./scripts/Invoke-DivvyOut.ps1 -Profile inputs/autodesk_profile_2027.psd1 -Quote inputs/autodesk_quote_2027.psd1 `
       -Usage inputs/autodesk_usage_2027.xlsx -Ad inputs/ad-snapshot.csv -Overrides inputs/overrides.csv
   ```
6. **Fix and run again** until the status is `FINAL`. The run folder has `overrides-template.csv`: one line per key the run could not handle, with only `Key` and a `Problem` hint filled in. Fill in the lines you can fix and **copy them into** `inputs/overrides.csv`. Do not replace your file with it: the template holds only new problems, not your existing overrides. The `Problem` column is ignored when the file is read.

### Options

| Option | What it does |
|---|---|
| `-AllowUnrecovered` | Do not stop when a price has nobody to charge. The amount is reported as not recovered and the run is `DRAFT`. |
| `-IncludeAmounts` | Put money amounts in `diagnostics.txt` (off by default). |
| `-Skip Statements, Rollups, ...` | Do not write these outputs: `Summary`, `NotFound`, `Exceptions`, `Statements`, `Rollups`, `Audit`, `Dashboard`, `Inputs`. `diagnostics.txt` and `manifest.json` are always written. |
| `-OutputRoot <folder>` | Where run folders go (default `output`). |

### Policies (profile `Policy`)

| Setting | Default | What it does |
|---|---|---|
| `UnusedQuoteOffering` | `Stop` | A quote offering with no usage rows has nobody to charge. `Stop` stops the run (or, with `-AllowUnrecovered`, reports it as not recovered). `Ignore` leaves it out of the total. A new offering in the quote stops the run until someone is charged for it: see "Renewal: moving heavy token users to seats". |
| `DuplicateSeatRows` | `ChargeEach` | Same person, same offering, 2+ seat rows: `ChargeEach` charges every row, `ChargeOnce` charges one. |
| `BadOverride` | `Draft` | An override that finds nobody, finds several people, names an unknown offering, or clashes with another: `Draft` makes the run `DRAFT`, `Warn` only warns. |

## Status: FINAL or DRAFT

`FINAL` only when every charged row has an owner, every price is charged to someone, and every override worked. Otherwise `DRAFT`, with the reasons in the console, the reports, and `diagnostics.txt`.

## Outputs (`output/<run-id>/`)

| File | For | What |
|---|---|---|
| `summary-by-manager.csv` | owner | One line per manager: people, rows, seat, token, total. Brief people from this. |
| `statements/<manager>.xlsx` | that manager | Their direct reports, the total, and how it was calculated. |
| `statements/NO-OWNER.xlsx` | owner | Rows with no usable owner. Fix with overrides. |
| `statements/rollup/<manager>.xlsx` | that manager | Managers with managers beneath them: the tree and one sheet per manager. |
| `not-found.csv` | owner | Every row not charged, and why: `NoMatch` (not found), `Disabled`, `Excluded`, `Duplicate` (extra seat row, `ChargeOnce`), `MovedToSeat` (extra row of a person moved to one seat). |
| `overrides-template.csv` | owner | One line per key to fix. Fill in and use as overrides. |
| `exceptions.csv` | owner | Every warning and problem, by row. |
| `audit.csv` | owner | One row per usage row with every number. Every report number traces here. |
| `dashboard.html` | owner | One offline page: status, totals, managers, attention list. Click an offering to see its users and which token users cost as much as a seat. Lists everyone. |
| `manifest.json` | owner | Run ID, versions, input hashes and row counts, reconciliation. |
| `inputs/` | owner | Copies of the input files, so the numbers can be rebuilt. |
| `diagnostics.txt` | **safe to share** | No names, emails, or amounts. Send this when something is wrong. |

Everything except `diagnostics.txt` holds personal data. You decide how long to keep run folders.

## Overrides (`overrides.csv`)

| Column | Use |
|---|---|
| `Key` | Finds the person (rules in `Overrides.KeyRules`, for example the usage email or the logon name). |
| `Manager` | New manager (found with `Overrides.ManagerLookup`; text not found is used as given). Also fixes the org tree for people with no usage. |
| `CostCenter` | New cost center text. |
| `Exclude` | `Y` = not here, not charged. |
| `Include` | `Y` = charge this user even though they are disabled (for example on leave). |
| `LinkTo` | Fixes a row that matched nobody or several people: finds the right directory user. |
| `SeatFor` | Offering name(s), `;` between several. Charges this person one seat of that offering instead of their tokens on it (for seats bought in the new quote). Their tokens leave the token pool. |
| `Reason`, `By`, `Date` | Shown in the audit trail and on statements. |

An override that finds nobody, finds several people, or clashes with another makes the run `DRAFT` (`Policy.BadOverride`).

## Renewal: moving heavy token users to seats

Some people use more tokens than a seat would cost. To move them to seats in the new quote:

1. **Find them.** Put `SeatCounts` and `TokensPurchased` in the quote and run. On the dashboard, click an offering under "Charge by offering". People marked ⚠ have a token cost of at least `Dashboard.SeatCandidatePercent` % of one seat (default 100). The attention list counts them too.

   For an offering you only use through tokens today, do a what-if run on a copy of the quote: add the offering to `SeatPrices` with the vendor price of one seat and `SeatCounts` = 1, and run with `-AllowUnrecovered` (nobody has a seat of it yet, so that price is reported as not recovered and the run is `DRAFT`). Read the dashboard only; do not send that run's statements.
2. **Buy the seats.** In the new quote, add the offering to `SeatPrices` with the total price of the seats. Optional: its `SeatCounts`.
3. **Say who gets them.** In `inputs/overrides.csv`, add one line per person with `SeatFor` set to the offering name (`;` between several offerings).
4. **Run.** Each person is charged one seat of that offering instead of their tokens on it. Their tokens leave the token pool, so the per-token rate for everyone else goes up. The seat price is split over everyone charged a seat of that offering.

Check `exceptions.csv` for `SeatForNoEffect` (the person has no token row on that offering, or already has a seat on it). If you skip step 3, the new offering has nobody to charge and the run stops (`UnusedQuoteOffering`). Charges come only from last year's usage: someone with no usage row for that offering cannot be charged a seat of it.

## Vendors that give only a list of users

Some vendors give only the people who used a product: no product, access type, or tokens. Use the `UserList` profile and quote:

1. Copy `config/profiles/userlist_profile_2027.psd1` and `config/quotes/userlist_quote_2027.psd1` to `inputs/`, renamed to `<vendor>_profile_<year>.psd1` and `<vendor>_quote_<year>.psd1`.
2. In the profile, set `Usage.Columns.Email` to the list's header. If the list has a logon name instead, map `UserKey` and change the match rules to use it. Set `Usage.FixedValues.Package` to the product name.
3. In the quote, put that same product name in `SeatPrices` with the total price.
4. Run as usual with the list as `-Usage`.

The price is split equally per person on the list. A person listed twice pays one share. People who are not here (disabled, not found, excluded) are not charged, and their share is spread over everyone else. One list = one product = one run.

Try it on the fake sample:
```powershell
./scripts/Invoke-DivvyOut.ps1 -Profile config/profiles/userlist_profile_2027.psd1 -Quote config/quotes/userlist_quote_2027.psd1 `
    -Usage samples/userlist/userlist_usage_2027.csv -Ad samples/ad-snapshot.csv
```

## When something goes wrong

Send `diagnostics.txt` from the run folder. Never send the other files. It is written on every run, failed runs included, and shows header and attribute names, counts, row numbers, and masked value shapes only.

## Tests

```powershell
pwsh -NoProfile -Command "Invoke-Pester ./tests -Output Detailed"
```

All test data is fake. Rebuild the sample data with `pwsh -NoProfile -File samples/New-SampleData.ps1`.

## Add a vendor

1. Write `src/DivvyOut/Rules/<Vendor>.ps1`: register the rule (name, canonical fields it needs, access kinds, allocate function). The function gets the pool rows and the quote and sets the row charges. Use `Rules/UserList.ps1` as the template.
2. Write a profile with `Vendor = '<Vendor>'` and the report's headers.
3. No core change is needed for vendors that sell seats and/or a token pool (DECISIONS D73, D74). A report that lacks a column the rule needs can set it in the profile with `Usage.FixedValues` (D86).

## Layout

```
config/       profiles/ (one per vendor), quotes/ (fake), overrides.csv (header only)
scripts/      Invoke-DivvyOut.ps1 (one-command run), Export-AdUsers.ps1
src/DivvyOut/ Public/ (commands), Private/ (core and writers), Rules/ (vendor math), Assets/ (dashboard page)
tests/        Pester tests, fake data only
samples/      fake data
inputs/       real data (gitignored)
output/       run folders (gitignored)
```
