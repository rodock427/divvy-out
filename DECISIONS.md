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

## Overrides and states

- **D32. One override per usage row** (changed by D79). Usage-key overrides apply to the rows they find (or to the whole person, D78). Directory-key overrides apply to every row of that user (after any `LinkTo`). If two overrides reach the same row, neither is applied anywhere (`OverrideConflict`, a bad override).
- **D33. `LinkTo`** needs a Key found by a usage-field key rule (it re-points usage rows). It finds the user with the directory key rules only. A linked row shows match status `Linked`. Linking to a disabled user makes the row `Disabled` unless `Include = Y`.
- **D34. Flags.** `Exclude` and `Include` accept Y/Yes/True/1 (any case) or blank/N/No/False/0. Anything else is a bad override.
- **D35. Precedence.** `Exclude` beats everything. `Ambiguous` and `NoMatch` rows are not fixed by `Manager` alone (they need `LinkTo`). An override manager beats the directory manager, even if that manager is disabled (warned).
- **D36. Duplicate keys** (same text ignoring case), and two directory-key overrides that find the same user, are bad overrides.
- **D37. Stale** = finds a person but touches no usage row and sets no manager. Only a warning. A directory-key override with a Manager and no usage rows is `TreeOnly` (org tree fix, spec 8).
- **D38. Directory manager lookup** compares the reference ignoring case and outer spaces (AD DNs ignore case). Two directory users with the same reference = manager not found.
- **D39. Cost center** comes from the matched user (after `LinkTo`). `Replace` is a literal text replace, then trim. An override `CostCenter` replaces the final value; the raw value stays for the audit trail.
- **D40. `Test-DivvyOutInput`** also checks the overrides file and sets row states; it never throws on bad inputs (look at `.Issues`).

## Allocation

- **D41. Vendor rule interface.** A rule file registers `@{ Name; RequiredFields; AccessKinds; Allocate }` in `$script:VendorRules[<Vendor>]`. `Allocate` names a function that takes `-PoolRows` (sorted, not `NotHere`), `-AllRows`, `-Quote`, `-Policy`, sets the row charges, and returns its pools. The core checks every pool and the total.
- **D42. Unrecoverable pools are found by the rule**: a seat offering with a price and no pool seat rows; the token pool with a price and zero pool tokens (including token rows that all used 0 tokens). The stop (`-AllowUnrecovered`) and the invariant check are in the core, in M4, because the M4 tests cover them.
- **D43. Pool info on `NotHere` rows** (offering price, pool seat rows, rate) is left blank; their charges are 0.
- **D44. A price of 0** is a valid pool. Its rows are charged 0.00 and it is never unrecoverable.

## Reports (M5)

- **D45. CSV status.** A CSV has no title, so every `summary-by-manager.csv` line has a `Status` column (`FINAL`/`DRAFT`). The console and `diagnostics.txt` list the DRAFT reasons.
- **D46. Unrecovered money in CSVs** appears as an `UNRECOVERED (nobody to charge)` line at the end of the summary and as an `Unrecovered` line in `exceptions.csv`. The Excel and HTML reports (M6, M8) will show it at the top.
- **D47. Summary lines**: one per charge owner (by directory ID; a free-text override manager is its own line with no ID), then `NO OWNER` (all `NeedsOwner` rows). `People` counts distinct directory users. Sorted by manager name, then ID, ordinal (non-ASCII names sort after Z; sort in Excel if needed). No total line (sum the column).
- **D48. `overrides-template.csv`** has one line per distinct key (normalized) and an extra `Problem` column (reason and usage rows). DivvyOut ignores `Problem` when it reads overrides, so the template can be edited and used as is. Rows with a blank key are left out (counted in an info line).
- **D49. `exceptions.csv`** has one line per row per issue (all levels), with a `File` column saying which file the row number points into (`usage`, `overrides`, `directory`).
- **D50. CSV formula escaping** also covers text starting with a tab or carriage return (OWASP list), besides `= + - @`.
- **D51. Outputs on a failed run**: only `diagnostics.txt` (FR-12). Reports are written only after the money reconciles.

## Statements and roll-ups (M6)

- **D52. Tree parent.** A person's manager in the tree is the override `Manager` from any override that was used for them (directory-key, tree-only, or applied to their rows), else the directory manager. Disabled managers are skipped (spec 8).
- **D53. Loops.** The people in the loop keep their own statements, get no roll-up, and sit under nobody. People below a loop become top level. One `ManagerLoop` warning lists the loop's charged rows.
- **D54. A free-text override manager** is a top-level node (not in the directory, so no manager above).
- **D55. Who gets files.** A statement for every charge owner with charged rows (loop members and free-text managers included). A manager with no direct charges gets no statement, only a roll-up if someone is beneath. `NO-OWNER.xlsx` is always written (it says so when empty). A file name that clashes with `NO-OWNER` gets a short ID.
- **D56. `Rollup.MaxTabs`** counts every sheet, the Summary included. Sheets go depth first; the rest are listed on the Summary only, with a note.
- **D57. `Rollup.Depth`** limits levels below the top manager (1 = direct sub-managers only). "With teams below" counts only the levels shown.
- **D58. Roll-up Summary.** First row is "<name> (direct)", whose "With teams below" is its own direct charge (as in the mockup). The Total row adds People and Direct charge only (spec text; the mockup shows the total in the last column).
- **D59. Statement table** has the spec 9.1 columns (seat charge, tokens, token charge, row total, cost center), with the mockup's look. No stacked bar: text only (ImportExcel does not make it easy).
- **D60. Name sort keys** (managers, people, rounding ties) join parts with a NUL character, so "mgr" sorts before "mgr2". Still ordinal and deterministic.
- **D61. File and sheet names** follow Windows and Excel rules in code (not the build OS): invalid characters become `_`, reserved names (CON, LPT1, ...) get a leading `_`, 100-character file names, 31-character sheet names, case-insensitive uniqueness with a 6-hex ID from the manager's key.
- **D62. Roll-up checks** (spec 8) run on every run before any report is written; a failure stops the run as an internal error.

## Audit and run folder (M7)

- **D63. Input copies.** Every run copies its input files to `<run>/inputs/` (spec 9). The M7 list says `-ArchiveInputs`, but spec 9 says copying is the default and a switch to turn it off comes later (M9). No switch yet. Two inputs with the same file name: the second gets its role as a prefix (`directory-data.csv`). A profile or quote passed as a hashtable is listed as `(in memory)` with no hash.
- **D64. `manifest.json`** is written only on successful runs (like the other reports, D51). Amounts are strings with 2 decimals (no float rounding in JSON). It holds amounts: owner-only.
- **D65. Audit numbers.** `Tokens` on a seat row is 0 (ignored); the original text is still in `usage_<header>`. `TokenRate` is the full unrounded rate. A row fixed by `LinkTo` shows `MatchRule = Override`.

## Dashboard (M8)

- **D66. No chart library.** Bars are plain HTML/CSS (spec 12 allows Chart.js inlined, but it is not needed for these views and adds a large blob). Hover text uses the native `title` tooltip.
- **D67. Data is inline JSON** in a `<script type="application/json">` block; every `<` is escaped so no name can close the tag. The page builds everything with `textContent` (no HTML from data).
- **D68. Tiles.** "Users charged" = distinct people on charged and NeedsOwner rows. "Not found (not charged)" = distinct people on `NotHere` rows. "Managers" = charge owners (NO OWNER excluded).
- **D69. Managers list.** Direct view lists charge owners; "With teams below" also lists managers who only have teams beneath (directors). Clicking a manager shows their direct-report rows. Top 6 by default, "Show all", search shows every match.
- **D70. Attention list**: not here (not charged), need an owner, matched by a fallback rule, rows under a manager loop, overrides that could not be applied. Each row opens its usage rows.
- **D71. Lists capped** for reading: top 10 token users (by token charge), top 10 cost centers. Full data is in the CSVs.

## Finish (M9)

- **D72. Output switches.** One parameter, `-Skip`, with a fixed list: Summary, NotFound (also the overrides template), Exceptions, Statements, Rollups, Audit, Dashboard, Inputs. No `-Outputs` (it would say the same thing the other way round). `diagnostics.txt` (FR-12) and `manifest.json` (traceability) cannot be skipped. The manifest records what was skipped.
- **D73. Second vendor proof.** `ExampleVendor` (fake) adds only `Rules/ExampleVendor.ps1`, a profile, a quote, and sample files. It has a different report layout, an HR-style directory (employee numbers, `Status = Active`, manager by employee number), and different math (one share per person, not per row). The core has no change and never names it (tested).
- **D74. Known limit for future vendors.** The core still knows the two access kinds `Seat` and `Token`: the quote shape (`SeatPrices`, `TokenPoolPrice`), token parsing, seat price checks, and the Seat/Token columns in reports. A vendor that fits seats and/or a token pool needs no core change. A vendor with a third kind (for example concurrent licences) would need small core changes in those places.

## Scale (after M9)

- **D75. Excel files are built in memory and written as bytes** (`GetAsByteArray`), with no `Dispose()`. EPPlus 4.5 `Dispose()` forces a full garbage collection; with a work-size run in memory that cost ~0.2 s per file. Ranges are styled once, not cell by cell. CSVs are written with plain loops (no script block per cell).
- **D76. Paths.** Every path handed to .NET goes through PowerShell's path resolution (`Get-FullPath`). .NET resolves relative paths against the process folder, which does not follow `cd`, so relative `-Usage`, `-Ad`, `-OutputRoot` could read or write the wrong folder.
- **D77. Measured at work scale** (fake: 30,061 directory users, 1,000 managers, 20,103 usage rows, Linux laptop): full run 45 s, peak memory about 1.25 GB. Before the fixes: about 230 s.

## Money-path review (after M9)

- **D78. An email override means the person** (owner OK, 2026-11-10). If every usage row a usage-field Key finds matched the same directory user, and the line has no `LinkTo`, the override applies to all of that user's rows, including rows under an alias or a username. Rows that matched nobody, or several people, stay row by row.
- **D79. Link, then the person's override.** A `LinkTo` line that only links (no Manager, CostCenter, Exclude, or Include) can be followed on the same row by the linked person's own override. A linking line that also sets one of those fields still clashes with the person's override. The audit shows both (`OverrideRow`, `LinkOverrideRow`).
- **D80. More warnings, no DRAFT:** two token rows for the same user and offering (`DuplicateTokenRows`, spec 10), and overrides that change nothing (`OverrideNoEffect`: Manager, CostCenter, or Include on rows that stay not found, disabled, or ambiguous; CostCenter with no `Ad.CostCenter`).
- **D81. `ManagerLookup` uses `Match.PreferEnabled`**: if the manager's mail finds a live and an old disabled account, the live one is used.
- **D82. Token rows may use offerings not in the quote.** Tokens draw on one pool with one price (`TokenPoolPrice`), so the offering name on a token row needs no seat price. Only seat rows need their offering in `SeatPrices`.
- **D83. Manager info columns** (owner OK, 2026-11-11). `Ad.ManagerInfo` lists `@{ Label; Attribute }` pairs, in order. The values come from the manager's own directory record and are added after `ManagerId` in `summary-by-manager.csv`, as a line under the subtitle on statements and roll-ups, as columns in the roll-up table, and under each name on the dashboard, where search matches them too. Blank for managers with no directory record (free-text override manager, NO OWNER). Labels must be unique and must not reuse a summary column name. `diagnostics.txt` shows how many managers have each one blank, and how many charged rows have a blank cost center, never the values.
- **D84. Seat vs token comparison, report only** (owner OK, 2026-11-11). The quote may list `SeatCounts` (seats bought per offering, whole numbers, names must be in `SeatPrices`) and `TokensPurchased` (tokens bought). Per seat = offering price ÷ seats bought; per token = `TokenPoolPrice` ÷ tokens bought. These are the vendor's unit prices, not the run's charges, and they never change a charge. On the dashboard, clicking an offering lists every charged or no-owner user of it (seat and token), with tokens, token cost (tokens × per token), % of one seat, and the run's charge. A token user with no seat row on that offering is flagged when token cost ≥ `Dashboard.SeatCandidatePercent` % of one seat (default 100). Flagged users are also an attention item. Not-here users are left out. Known limit: a collection seat that covers several products is compared per product, so heavy users of several products in one collection are undercounted.
