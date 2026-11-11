# Decisions

Choices made where the spec was silent or unclear. Newest at the bottom of each section.
"Owner OK" = the owner accepted it in M0 (2026-11-10).

## Naming and layout

- **D1. Name.** The tool is DivvyOut. The spec's `Chargeback` names become `DivvyOut` (module `src/DivvyOut`, command `Invoke-DivvyOut`).
- **D2. Repo root** is this folder, not `sw-chargeback/`.
- **D3. Real config stays out of git.** `config/quotes/` and `config/overrides.csv` in the repo hold fake values only. Put the real quote and overrides in `inputs/`.

## Math (owner OK)

- **D10 (A). Quote offering with zero usage rows.** `Policy.UnusedQuoteOffering = 'Stop'` (default): treated as an unrecoverable pool, so the run stops unless `-AllowUnrecovered`. `'Ignore'`: the price is left out of the quote total, with a warning.
- **D11 (B). Invariant with `-AllowUnrecovered`.** sum(row charges) + unrecovered = quote total (all priced pools, minus ignored offerings).
- **D12 (C). Only hit is disabled.** `Match.DisabledSoloHit = 'TryNextRule'` (default): keep trying later rules for an enabled match. If none, the row is `NotHere`/`Disabled`. `'Stop'`: the spec's literal reading, stop at the disabled hit.
- **D13 (D). `PreferEnabled` drops every hit** (all hits disabled): same as D12, treated as "all hits disabled".
- **D14 (E). Duplicate seat rows** (same directory user, same offering, both seat rows): `Policy.DuplicateSeatRows = 'ChargeEach'` (default) charges every row and warns. `'ChargeOnce'`: the first row (by the rounding sort key) is charged, the rest become `NotHere`/`Duplicate`.
- **D15 (F). Bad override** (key finds nobody, finds 2+ people, two overrides hit the same row, `LinkTo` finds nobody): the override is skipped and listed. `Policy.BadOverride = 'Draft'` (default) forces the run to `DRAFT`. `'Warn'` only warns.
- **D16 (G). Disabled user who should be charged** (for example, on leave): override column `Include = Y`. Not used unless the owner adds it.
- **D17 (H). Number formats.** Quote prices: whole number, quoted string (`'12000.50'`), or decimal literal (`12000.50d`). At most 2 decimals, not negative. A bare `12000.50` loads as `[double]` and is rejected. Tokens: digits with an optional decimal part, not negative. No thousands separators, no signs, no exponent. `1,234` is rejected (stops the run) rather than guessed.
- **D18. Rounding sort key** is offering, directory ID, first match-rule usage value, then source row number. Ordinal comparison. The row number makes the order total (ambiguous rows have no directory ID, and duplicate rows can tie on everything else).
- **D19. Token shares** are computed as `price × tokens ÷ pool tokens` (multiply first). This is the spec's `tokens × rate` with less decimal error. The rate is never rounded.

## Inputs and matching

- **D20. Manager link.** `Ad.ManagerAttribute` is the column that points to the manager. `Ad.ManagerKeyAttribute` is the manager's column it holds. In AD: `manager` holds a DN, so the key is `distinguishedName` (must be in the snapshot). Works for any directory (for example an HR file where the manager column holds an employee ID).
- **D21. Display name** comes from `Ad.DisplayAttribute` (new profile key).
- **D22. Extra manager columns** from `Export-AdUsers.ps1` are named in `Ad.ManagerColumns` and written as `manager_<name>`. Info only; the core does not read them.
- **D23. Multi-valued match.** A match rule may set `Split = ';'` to compare against each part of a joined attribute (for example `proxyAddresses`). This is how alias emails match.
- **D24. Header and text matching.** Usage headers match the profile ignoring case and outer spaces. Access option text and offering names (quote and aliases) also ignore case and outer spaces. The quote's spelling is used in reports.
- **D25. Row numbers** in all messages are the row as the owner sees it in Excel or a text editor (header row = `Usage.HeaderRow`). Fully blank usage rows are skipped.
- **D26. An empty value never matches.** A blank email does not match users with a blank `mail`.
- **D27. Diagnostics** show input file types and row counts, not file names (names can contain a person's name). Unexpected errors show the error type and code location only, never the message (it can contain data values).
- **D28. Seat rows** keep `Tokens = 0` internally. A non-numeric token value on a seat row is a warning, not a stop.
- **D29. Directory blank IDs** stop the run like repeated IDs.
- **D30. Match outcomes.** Every row gets `Matched`, `Ambiguous`, `Disabled`, or `NoMatch`. With `PreferEnabled` off, a live and a disabled account on one value are `Ambiguous` (spec step 5). With it on or off, hits that are all disabled count as "disabled" (D12, D13).
- **D31. `Test-DivvyOutInput`** also runs matching and prints the match report (spec 5.5 lists the match report as part of validation). It writes no files.
