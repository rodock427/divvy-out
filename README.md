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

Keep real files in `inputs/`. Git ignores `inputs/` and `output/`. Never put real data anywhere else in this folder.

1. **Profile.** Copy `config/profiles/autodesk_profile_2027.psd1` and set your real names: the usage report headers (`Usage.Columns`), the access option text, the match rules, and the directory attribute names (`Ad`). Nothing about your report or directory is in the code; it is all in the profile. Optional: `Ad.ManagerInfo` adds directory attributes of each manager (for example a region) to the summary, statements, roll-ups, and dashboard.
2. **Quote.** Copy `config/quotes/autodesk_quote_2027.psd1` to `inputs/` and enter the real prices. Write amounts as `12000`, `'12000.50'`, or `12000.50d` (a bare `12000.50` is rejected). Optional: `SeatCounts` and `TokensPurchased` (what was bought) turn on the seat vs token comparison on the dashboard. They never change charges.
3. **Directory snapshot.**
   ```powershell
   ./scripts/Export-AdUsers.ps1 -ProfilePath inputs/autodesk_profile_2027.psd1 -OutFile inputs/ad-snapshot.csv -Server dc1.corp.example
   ```
   Several domains: add one `-Server` per domain, or use `-UseGlobalCatalog`. The export has enabled and disabled users.
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
6. **Fix and run again** until the status is `FINAL`: use `overrides-template.csv` from the run folder as the start of your `inputs/overrides.csv`.

### Options

| Option | What it does |
|---|---|
| `-AllowUnrecovered` | Do not stop when a price has nobody to charge. The amount is reported as not recovered and the run is `DRAFT`. |
| `-IncludeAmounts` | Put money amounts in `diagnostics.txt` (off by default). |
| `-Skip Statements, Rollups, ...` | Do not write these outputs: `Summary`, `NotFound`, `Exceptions`, `Statements`, `Rollups`, `Audit`, `Dashboard`, `Inputs`. `diagnostics.txt` and `manifest.json` are always written. |
| `-OutputRoot <folder>` | Where run folders go (default `output`). |

## Status: FINAL or DRAFT

`FINAL` only when every charged row has an owner, every price is charged to someone, and every override worked. Otherwise `DRAFT`, with the reasons in the console, the reports, and `diagnostics.txt`.

## Outputs (`output/<run-id>/`)

| File | For | What |
|---|---|---|
| `summary-by-manager.csv` | owner | One line per manager: people, rows, seat, token, total. Brief people from this. |
| `statements/<manager>.xlsx` | that manager | Their direct reports, the total, and how it was calculated. |
| `statements/NO-OWNER.xlsx` | owner | Rows with no usable owner. Fix with overrides. |
| `statements/rollup/<manager>.xlsx` | that manager | Managers with managers beneath them: the tree and one sheet per manager. |
| `not-found.csv` | owner | Every row not charged, and why (not found, disabled, excluded). |
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
| `Reason`, `By`, `Date` | Shown in the audit trail and on statements. |

An override that finds nobody, finds several people, or clashes with another makes the run `DRAFT` (`Policy.BadOverride`).

## When something goes wrong

Send `diagnostics.txt` from the run folder. Never send the other files. It is written on every run, failed runs included, and shows header and attribute names, counts, row numbers, and masked value shapes only.

## Tests

```powershell
pwsh -NoProfile -Command "Invoke-Pester ./tests -Output Detailed"
```

All test data is fake. Rebuild the sample data with `pwsh -NoProfile -File samples/New-SampleData.ps1`.

## Add a vendor

1. Write `src/DivvyOut/Rules/<Vendor>.ps1`: register the rule (name, canonical fields it needs, access kinds, allocate function). The function gets the pool rows and the quote and sets the row charges. Use `Rules/ExampleVendor.ps1` as the template.
2. Write a profile with `Vendor = '<Vendor>'` and the report's headers.
3. No core change is needed for vendors that sell seats and/or a token pool (DECISIONS D73, D74).

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
