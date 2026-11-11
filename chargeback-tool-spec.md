# Software Chargeback Tool — Project Spec

Read this whole file before you write code. Section 14 tells you how to start.

---

## 1. Purpose

Build a tool that charges internal software cost to the correct managers.

We can no longer pay for this software from one central cost center. Each user's cost must go to the user's manager. The tool takes the vendor quote, a usage report, and a directory (AD) export. It gives back a fixed charge for each user, grouped by manager.

## 2. Scope and design principles

**v1 (build now):** Autodesk only.

**Later:** other software. Design for this now:
- **Input profiles** (Section 5) map any vendor's report to the tool **without code**.
- **Vendor rule modules** (Section 12) hold only the charge math for one vendor.

**Design principle: nothing is hard-coded.** The tool must work at any company with any setup. These are always config, never code:
- report header names
- the text of access option values
- which fields match a usage row to a directory user (email, username, UPN, anything)
- which directory attribute is the unique user ID
- which fields the override file uses to find a person
- directory attribute names (manager, enabled flag, cost center)

If you catch yourself writing `mail`, `sAMAccountName`, `Seats`, or `Source Email` in core code, stop. Move it to the profile.

**Out of scope for v1:**
- Live connection to the vendor's system (use the uploaded report)
- Posting to a finance system or making a finance upload file
- True-up to actual usage (the charge is fixed for the year)
- Currencies other than USD
- Refreshing manager ownership during the year

## 3. Key facts (from the project owner)

- Autodesk gives access in two ways, shown per row in the report: **Seats** or **Tokens**.
- **Seat rows** pay a share of the offering's price. The price is split equally among the seat rows of that offering.
- **Token rows** pay only for tokens used. Tokens come from one shared **token pool**. The pool has one price.
- Charging uses the **NEW quote** (next year's cost).
- The split uses the **usage report**, which is last year's data. The owner controls the timeframe with the export. **Whatever is in the file counts.** The tool does not check dates.
- The charge is **fixed for the year**. No true-up.
- **If a user is not here, they are not charged.** Their share is spread over the users who are still here. The owner still wants a **list of the users who were not found**.
- Manager comes from the directory at run time. The owner must be able to **change it by hand**. The directory is sometimes wrong for billing.
- The tool runs **for the renewal**. An occasional monthly snapshot is fine. It is not the main use.
- Currency: **USD**.
- Cost center is **not integral**. Show it when the profile defines it. Nothing depends on it.
- The AD cost center value contains commas. This is only how AD stores it. The tool replaces `,` with `-`.
- Usage comes from **one export**. One row per user per offering.
- Directory data comes from a **CSV export**. The tool may read AD live later.
- `Team Alias` (the Autodesk team) is **info only**. It does not change the charge.
- `ImportExcel` is allowed.
- **Workflow:** Claude Code builds with fake data. The owner runs the tool on real data locally and relays feedback. See Sections 9.5 and 14.

## 4. Inputs

All inputs are files. Do not guess column names. Ask the user for the real headers first (Section 14).

| Input | Contents | Format |
|---|---|---|
| Input profile | Column map, match rules, directory attributes, override rules | `.psd1` (one per vendor) |
| Quote | Total price per offering. Token pool price. Currency. | `.psd1` (one per period) |
| Usage report | One row per user per offering: team, offering, email, access option, tokens used | CSV or XLSX, from the vendor |
| Directory snapshot | Attributes per user (Section 6) | CSV |
| Overrides | Manual changes (Section 5.3) | CSV |

Use `.psd1` for config. PowerShell reads it with `Import-PowerShellDataFile`. It allows comments. It does not run code.

Quote example:

```powershell
@{
    Period         = '2027'
    Currency       = 'USD'
    SeatPrices     = @{            # key = exact text of the offering name; value = TOTAL price for that offering
        'Offering One' = 12000
        'Offering Two' = 8000
    }
    TokenPoolPrice = 30000         # one final price for the whole token pool
}
```

## 5. Configurable inputs (input profile)

Goal: a new vendor report, or a new company setup, works by editing a profile, not code.

### 5.1 Column map
The profile maps each **source column** to a **canonical field**. Map by **header name**, not by column letter. Exports can move columns. The tool and the rule modules only use canonical fields.

Canonical fields for v1:

| Field | Autodesk source header | Required |
|---|---|---|
| `Email` | `Source Email` | Yes |
| `Package` | `Offering Name` | Yes |
| `AccessOption` | `Access Options` | Yes |
| `Tokens` | `Tokens Used` | Yes |
| `Team` | `Team Alias` | No (info only, passes through) |
| `UserKey` | (username column, if the report has one) | No |

A profile may add more canonical fields. They pass through to the audit trail.

The profile also holds:
- `AccessOptionValues`: the exact text for seat and token rows (`Seats`, `Tokens`)
- `OfferingAliases`: maps an offering name in the report to its name in the quote (names change between years)
- `Sheet`, `HeaderRow`, `Encoding` for the usage file (optional)

The usage reader accepts CSV and XLSX. It picks the reader by file extension.

### 5.2 Match rules (usage row → directory user)
The profile has an **ordered list** of match rules. Each rule says:
- which usage field to read
- which directory attribute to compare it to
- how to normalize both sides

Behavior:
1. Try rule 1. Find all directory users that match.
2. If `PreferEnabled` is on and there is more than one hit, drop the disabled users first. (Old disabled accounts often share an email with a live account.)
3. If exactly **one** user is left, stop. That is the match.
4. If **none**, try the next rule.
5. If **more than one**, do **not** guess. The row is `AmbiguousMatch` (Section 10).
6. If no rule matches, the row is `NoMatch` (Section 10).
7. Record **which rule matched** and the **values compared** in the audit trail.

Normalize options (apply to both sides before the compare):

| Option | Effect |
|---|---|
| `Trim` | Remove leading and trailing spaces |
| `ToLower` | Lowercase |
| `StripDomainPrefix` | `CORP\jsmith` → `jsmith` |
| `StripUpnSuffix` | `jsmith@corp.com` → `jsmith` |
| `Regex` | Custom pattern and replacement |

The directory attribute can be **any column in the snapshot**: `mail`, `userPrincipalName` (user logon name), `sAMAccountName` (pre-Windows 2000 name), `employeeID`, `displayName`, or a custom one.

If a username column exists, it may hold **either** logon-name type. List both as separate rules so either form matches.

### 5.3 Overrides
The owner must be able to fix any user by hand, with any identifier. The profile says how the override file finds a person. This uses the same idea as the match rules.

`overrides.csv` columns:

| Column | Meaning |
|---|---|
| `Key` | Value that identifies the person. Found with `Overrides.KeyRules` (tried in order, first single hit wins). |
| `Manager` | Optional. New manager. Found with `Overrides.ManagerLookup`. If not found in the directory, warn and use the text as given. |
| `CostCenter` | Optional. New cost center text. |
| `Exclude` | `Y` = treat this person as not here. They are not charged. |
| `LinkTo` | Optional. Value that finds the right directory user. Fixes a `NoMatch`. Uses the directory-attribute rules in `Overrides.KeyRules`. |
| `Reason`, `By`, `Date` | For the audit trail. |

A `KeyRule` can read a **usage field** (for example `Email`) or a **directory attribute**. A usage-field rule fixes rows that never matched the directory.

Validate the file. Report: keys that find nobody, keys that find more than one person, duplicate keys, and overrides that match no usage row (stale).

### 5.4 Example profile (verify header text against the real file)

```powershell
@{
    Vendor = 'Autodesk'

    Usage = @{
        # Sheet     = 'Sheet1'           # XLSX only (optional)
        HeaderRow = 1
        Encoding  = 'utf8'
        Columns = @{                     # canonical = source HEADER NAME
            Team         = 'Team Alias'
            Package      = 'Offering Name'
            Email        = 'Source Email'
            AccessOption = 'Access Options'
            Tokens       = 'Tokens Used'
        }
        AccessOptionValues = @{ Seat = 'Seats'; Token = 'Tokens' }   # exact text in the report
        OfferingAliases    = @{ }                                    # 'Name in report' = 'Name in quote'
    }

    Match = @{
        PreferEnabled = $true
        Rules = @(                       # tried in order
            @{ UsageField = 'Email'; AdAttribute = 'mail';              Normalize = 'Trim','ToLower' }
            @{ UsageField = 'Email'; AdAttribute = 'userPrincipalName'; Normalize = 'Trim','ToLower' }
            # If the report has a username column mapped as UserKey, add:
            # @{ UsageField = 'UserKey'; AdAttribute = 'userPrincipalName'; Normalize = 'Trim','ToLower' }
            # @{ UsageField = 'UserKey'; AdAttribute = 'sAMAccountName';    Normalize = 'Trim','ToLower','StripDomainPrefix','StripUpnSuffix' }
        )
    }

    Ad = @{
        Attributes       = 'objectGUID','sAMAccountName','userPrincipalName','mail','displayName','manager','Enabled'   # add the cost center attribute if you use it
        IdAttribute      = 'objectGUID'  # unique user ID. Any unique attribute works. The tool stops if values repeat.
        EnabledColumn    = 'Enabled'
        EnabledValue     = 'True'
        ManagerAttribute = 'manager'
        # CostCenter (optional):
        # CostCenter = @{ Attribute = '<COST_CENTER_ATTR>'; Replace = @( @{ From = ','; To = '-' } ) }
    }

    Charge = @{
        Owner = 'DirectManager'          # later option: 'OwnerList'
    }

    Rollup = @{
        Enabled = $true
        Depth   = 0                      # 0 = all levels
        MaxTabs = 50                     # sheets per roll-up workbook. The Summary always lists everyone.
    }

    Overrides = @{
        KeyRules = @(                    # how the Key column finds a person
            @{ UsageField  = 'Email';          Normalize = 'Trim','ToLower' }
            @{ AdAttribute = 'sAMAccountName'; Normalize = 'Trim','ToLower','StripDomainPrefix' }
        )
        ManagerLookup = @{ AdAttribute = 'mail'; Normalize = 'Trim','ToLower' }
    }
}
```

### 5.5 Profile validation
Before any calculation, the tool must check the profile and say exactly what is wrong:
- Every mapped source column exists in the usage file.
- Every `AdAttribute` in the profile is a column in the directory snapshot.
- `IdAttribute` values are unique in the snapshot. If not, stop and name the duplicate count.
- Every canonical field that the vendor rule needs is mapped.
- Every `Access Options` value in the file is one of the two values in `AccessOptionValues`.
- Every offering with a seat row (after aliases) has a price in the quote.
- Quote `Currency` is `USD`.
- Print a **match report**: how many rows matched by each rule, how many failed.

## 6. Directory snapshot (AD)

Always **snapshot the directory to a CSV**, even if AD is read live. The audit trail hashes the input files. Re-runs must give the same result. AD changes daily.

Any directory works if it produces the CSV columns the profile names.

`Export-AdUsers.ps1` does the AD export:
- Uses `Get-ADUser` with the attribute list from the profile (`Ad.Attributes`).
- Exports **enabled and disabled** users. Disabled users are needed to find departed users and managers.
- Options: `-Server` (one or more domain controllers), `-SearchBase`, `-UseGlobalCatalog`. Several domains need several servers, or the Global Catalog. Some custom attributes are not in the Global Catalog. If so, query each domain.
- The AD `manager` attribute holds a **distinguished name (DN)**. The script must resolve it. It adds columns for the manager's `IdAttribute`, `mail`, and `displayName`.
- Handles multi-valued attributes by joining them with `;` (document the choice).
- Writes UTF-8 with BOM.

## 7. Calculation rules

Use `[decimal]`, never `[double]`.

### 7.1 Who is in the pools

Every usage row gets a state:

| State | Rule | In the pool? |
|---|---|---|
| `Charged` | Matched, enabled, and has a valid manager (or an override gives one) | Yes |
| `NeedsOwner` | Here, but no valid owner: `AmbiguousMatch`, no manager, manager is disabled, manager not found | Yes |
| `NotHere` | `NoMatch`, disabled directory user, or override `Exclude = Y` | **No** |

`NotHere` rows are **not charged** and **do not count** in any divisor. Their share is spread over the rows that remain. They go to the Not-found report (Section 9.3).

`NeedsOwner` rows are charged normally but have no statement owner. They block a `FINAL` run (Section 7.4).

### 7.2 Formulas

```
seat_charge(row)  = offering_price / number_of_pool_seat_rows_in_that_offering        (AccessOption = Seat)
token_rate        = token_pool_price / total_tokens_used_by_pool_token_rows
token_charge(row) = tokens_used * token_rate                                          (AccessOption = Token)
user_total        = sum of the user's row charges
```

Notes:
- Prices come from the **new quote**. Tokens come from the **usage report**.
- A **seat row** pays the seat charge only. A **token row** pays the token charge only.
- `Tokens Used` on a seat row is ignored. Warn if it is more than 0.
- A user can have several rows (different offerings, different access options). Charge each row by its own access option.
- `Import-Csv` returns strings. Cast every number explicitly. Reject values that do not parse.
- Do not round the token rate. Round only each row's final charge. Show the rate rounded in reports for display only.

### 7.3 Rounding
Round to cents. Use the largest-remainder method **per pool**. One pool = one offering's price over its pool seat rows. One pool = the token pool over its pool token rows. Each pool then adds up to its price **exactly**.

**Ties must be deterministic.** Sort rows by a fixed key (offering, then directory ID, then email) before rounding. Break remainder ties in that order. PowerShell hashtable order is not stable. Use `[ordered]` or an explicit sort. Never depend on enumeration order.

### 7.4 Reconciliation and run status

**Invariant (test this):**
`sum(all row charges) == sum(prices of pools that have at least one row)`

Unrecoverable pools:
- An offering has a price but **zero** pool seat rows.
- The token pool has a price but **zero** pool tokens.

There is nobody to charge. The run **stops** with a clear message. The owner may run again with `-AllowUnrecovered`. Then the unrecovered amount is shown at the top of every report.

Run status:
- `FINAL`: no `NeedsOwner` rows and no unrecovered amount.
- `DRAFT`: anything else. Every report says `DRAFT` in the title. The owner fixes the cause with overrides and runs again.

### 7.5 Worked example (use as the first unit test)

- Offering One price: 12,000. It has 11 seat rows. One user is `NotHere`. → 10 pool seat rows → **1,200.00** each.
- Token pool price: 30,000. Token rows used 110,000 tokens in total. A departed user (`NotHere`) used 10,000. → 100,000 pool tokens → rate **0.30**.
- User X has a seat row in Offering One. User X has a token row in Offering Two with 2,500 tokens.
- User X seat charge: 1,200.00. Token charge: 2,500 × 0.30 = 750.00.
- User X total: **1,950.00**.
- The `NotHere` seat user and the departed token user pay 0.00. Both appear in the Not-found report.

## 8. Manager mapping and overrides

Order of precedence:
1. Override file (Section 5.3)
2. Directory attribute (`Ad.ManagerAttribute`)

Charge owner = manager. Each statement lists the manager's direct reports.

Ownership is read at **run time** and not refreshed. Runs happen at the renewal.

Cost center (optional): if the profile defines it, read it from the user's directory record, apply the `Replace` list, trim, and show it. Keep both the raw and the final value in the audit trail. Nothing groups or blocks on it.

Every override must show up in the audit trail.

### Org tree and roll-up

The directory manager chain gives an org tree. A charged user belongs to their **final** manager (after overrides). A manager's own manager comes from the directory.

- **Who pays:** the direct manager (`Charge.Owner = 'DirectManager'`). The owner is not sure yet if this is right. Put the owner rule in one function (`Resolve-ChargeOwner`). A later mode (`OwnerList`) can move a charge up to a listed budget owner (director or VP) without changing anything else.
- A **roll-up is a view.** It does not change who is charged. Each user is counted once.
- A manager who has at least one manager beneath them (with charges beneath) gets a **roll-up workbook** (Section 9.7). `Rollup.Enabled` turns it off. `Rollup.Depth` limits the levels (0 = all).
- A disabled manager is skipped in the tree. Their sub-managers attach to the next enabled manager above. (A disabled direct manager of a charged user is `NeedsOwner`, per Section 10.)
- A loop in the manager chain: warn, and leave the loop members out of roll-ups.
- Overrides may set the manager of a person who has **no usage row**, to fix the tree. That is not a stale override.

Roll-up checks (test these):
- The sum of every manager's direct charge equals the grand total.
- A roll-up total equals the sum of the direct charges of the managers in its subtree.
- No user is counted twice.

## 9. Outputs

**Export everything first.** Every run writes **all** outputs below. Output switches (choose what to write) come later, after the owner has seen the full set (M9). Do not build selection logic in v1.

To make switches cheap later, build each output as its own writer function. The core code builds one result object. Every writer takes that object. No writer reads another writer's file.

Every run writes to its own folder:

```
output/<run-id>/
  statements/<manager>.xlsx     one per manager
  statements/NO-OWNER.xlsx      rows with no usable owner (owner only)
  statements/rollup/<manager>.xlsx   one per manager who has managers beneath them
  summary-by-manager.csv
  not-found.csv
  overrides-template.csv
  exceptions.csv
  audit.csv
  dashboard.html
  manifest.json                 run ID, tool version, run status, input file names,
                                input hashes and row counts, match report, reconciliation
  diagnostics.txt               safe to share (Section 9.5)
  inputs/                       copies of the input files
```

- Inputs are copied into the run folder by default, so the owner can rebuild the numbers later. A switch to turn this off comes later.
- Statement file names: remove characters Windows does not allow. If two managers share a name, add a short ID to the file name.
- The folder contains personal data. The owner decides how long to keep it.

### 9.1 Per-manager statement
- One Excel file per manager (`ImportExcel`).
- Header: manager, period, run date, run status. `DRAFT` runs say `DRAFT`.
- Table: each direct report, team, offering, access option, seat charge, tokens, token charge, row total. Cost center if defined.
- Subtotal for the manager.
- Footer: plain-English explanation of the formulas, the seat split, and the token rate.
- `NeedsOwner` rows go on one extra statement called `NO OWNER`. It is for the owner only.
- Layout and styling: Section 9.7.
- A manager who has managers beneath them also gets a roll-up workbook (Section 8 and Section 9.7). Their normal statement covers only their own direct reports.

### 9.2 Summary CSV
One CSV with one line per manager: manager, direct report count, seat total, token total, total. Build this early (Section 13, M5). The owner can brief people with it before the statements exist.

### 9.3 Not-found report
CSV of every `NotHere` row: the usage identifiers, team, offering, access option, tokens, and the reason (`NoMatch`, `Disabled`, `Excluded`). Also write `overrides-template.csv`: one line for each `NoMatch` and `NeedsOwner` row, with `Key` already filled from the first usage-field rule in `Overrides.KeyRules`, and the other columns empty.

### 9.4 Audit trail
One row per usage row. Columns at minimum:
- usage identifiers (as in the report), team
- row state (`Charged`, `NeedsOwner`, `NotHere`) and reason
- matched directory ID, **match rule number**, value compared, directory value compared
- offering, access option, offering price, pool seat rows, seat charge
- tokens, token rate, token charge, row total
- manager (directory), manager (final), cost center (raw), cost center (final)
- override applied (Y/N), override reason, override who/when
- run ID, run timestamp, tool version
- **Everything else:** every column from the usage report as it is (prefix `usage_`), and every attribute in `Ad.Attributes` for the matched directory user (prefix `ad_`). Export everything first. Trim later.

### 9.5 Diagnostics (safe to share)
The owner runs the tool on real data and sends feedback to the builder. Real data must not go in that feedback. So every run writes `diagnostics.txt` with **no personal data**:
- tool version, PowerShell version, module versions
- profile validation result, with header and attribute **names** (names of columns are not personal data)
- row counts, and counts per match rule, per state, and per exception type
- row **numbers** for problems, not values
- for failed matches: a masked shape of the value only, for example `a***@b***.com (len 22)`
- no manager names, no emails, no money amounts

An option (`-IncludeAmounts`) adds money amounts. It is off by default.

### 9.6 Dashboard
Single static HTML file written by the script (no server).
Views:
- Total charge by manager
- Charge by offering, and seat vs token split
- Top token users
- Quote vs allocated (reconciliation) and run status
- Not-found count and exceptions list
- By cost center, only if the profile defines one

The dashboard and the audit trail list everyone. They are for the owner only. Managers get only their own statement. Layout and styling: Section 9.7.

### 9.7 Visual design

The owner approved a mockup of the manager statement and the owner dashboard. Goal: clear data that a manager **and** the owner like to look at. No dense grids, no heavy borders, nothing that looks like an old printed manual.

**Shared rules**
- **Number first.** The total is the biggest thing on the page.
- **Money:** right-aligned, tabular digits, format `$#,##0.00`.
- **One accent color,** plus a second only where it means something (seats vs tokens).
- **Status = icon + word,** never color alone. `FINAL` or `DRAFT` is always in the header.
- **No gridlines, no banded rows, no heavy borders.** Use thin dividers and white space.
- **Thin marks.** Bars are at most 24 px thick (Excel: keep them small).
- **One axis.** Never a chart with two scales.
- **Color follows meaning, not rank.** Seats are always series 1. Tokens are always series 2.
- **Text uses text colors.** Never color text with a series color.

**Colors**

| Use | Light | Dark (dashboard only) |
|---|---|---|
| Series 1: seats, default bars | `#2a78d6` | `#3987e5` |
| Series 2: tokens | `#eb6834` | `#d95926` |
| Status good (`FINAL`, reconciled) | `#0ca30c` | `#0ca30c` |
| Status warning (`DRAFT`, not found) | `#fab219` | `#fab219` |
| Text primary / secondary / muted | `#0b0b0b` / `#52514e` / `#898781` | `#f0efec` / `#c3c2b7` / `#898781` |
| Hairline divider | `#e1e0d9` | `#2c2c2a` |

Status colors are reserved. Never use them for a data series.

**Manager statement (Excel)**

```
Dana Whitfield                                        [✓ FINAL]
Autodesk · 2027 renewal · run <run-id>

$5,580.00
5 people · Seats $3,600.00 · Tokens $1,980.00

Person         Team         Offering       Access   Tokens       Charge
──────────────────────────────────────────────────────────────────────
Alex Rivera    Design       Offering One   Seat          –    $1,200.00
Priya Nair     Design       Offering One   Seat          –    $1,200.00
Sam Okafor     Engineering  Offering Two   Tokens    2,500      $750.00
Lena Fischer   Engineering  Offering One   Seat          –    $1,200.00
Tomas Brandt   Operations   Offering Two   Tokens    4,100    $1,230.00
──────────────────────────────────────────────────────────────────────
Total                                                          $5,580.00
```

- Sheet 1 is "Statement". It fits one page. It has: header block, big total, people count, seat/token amounts, table.
- The total is large and bold in the accent color. (Excel cannot match a serif hero number. Do not try.)
- Header row: bold, thin line under it. Data rows: thin hairline between rows. No fills, except the status cell (green for `FINAL`, amber for `DRAFT`, with the word).
- Seat and token amounts may use one small stacked bar if `ImportExcel` makes it easy. If not, text only.
- Freeze panes under the header row. Hide gridlines. One font for the whole file.
- Print: portrait, fit to one page wide.
- Sheet 2 is "How this was calculated". It has plain-English lines with the real numbers for this manager's offerings: seat price ÷ pool seat rows = seat charge; token pool ÷ pool tokens = rate; list of overrides applied; run ID and date. No formulas the manager must read.
- The `DRAFT` statement shows an amber `DRAFT` chip and one line saying why.
- A manager sees only their own people. `NO OWNER` rows never appear on a manager statement.

**Roll-up workbook (Excel)**

For a manager who has managers beneath them. Same look as the statement.

```
Priya Shah                                            [✓ FINAL]
Autodesk · 2027 renewal · Roll-up · run <run-id>

$42,180.00
3 managers below you · 27 people

Manager               People    Direct charge    With teams below
──────────────────────────────────────────────────────────────────
Priya Shah (direct)        2        $2,400.00           $2,400.00
Dana Whitfield             5        $5,580.00           $5,580.00
Marcus Lee                12       $18,240.00          $34,200.00
  Hannah Cole              8       $15,960.00          $15,960.00
──────────────────────────────────────────────────────────────────
Total                     27                           $42,180.00
```

- The **Summary** sheet is first. It shows the org tree with indents, one row per manager.
- **Direct charge** is that manager's own direct reports. **With teams below** adds everyone beneath that manager. The Total adds the **Direct charge** column only. Never add "With teams below" (it counts people twice). Show a one-line note under the table saying this.
- After the Summary: one sheet for the person's own direct reports, then one sheet per manager in the tree. Each sheet uses the normal statement table.
- `Rollup.MaxTabs` (default 50) limits the sheets. The Summary always lists everyone. If sheets were left out, say so under the table.
- Sheet names: 31 characters at most, no `[ ] : * ? / \`, and unique. Add a short ID if two names clash.
- The wording is neutral: "These charges are assigned to the managers listed." It does not say who pays. The owner has not decided that yet.
- Same status chip and `DRAFT` rules as the statement.

**Owner dashboard (HTML)**

Order from the top:
1. **Status strip.** Green `Final · reconciled` with "Quote = allocated". On `DRAFT`, amber, with the reason (for example "3 rows need an owner").
2. **Four tiles, two by two:** total allocated, users charged, managers, not found.
3. **Top managers by charge.** Horizontal bars, one color, sorted high to low, value at the right. Show the top 6 and "Top 6 of N". Hover shows the exact amount.
4. **Seats and tokens.** One stacked bar with a legend that shows percent and amount.
5. **Attention list.** Rows with icon, label, and arrow: users not found (not charged); rows matched by a fallback rule; rows that need an owner.

Interactions:
- Search box filters by manager. Click a manager to see their rows. Click an attention row to see its rows.
- Hover on any bar shows a tooltip with the exact amount.
- Sort the manager list by charge or by name.
- A toggle switches the manager list between **direct charge** and **with teams below**.

Technical rules:
- One self-contained HTML file. Plain HTML, CSS, and JavaScript. **No external calls** (no CDN, no fonts, no analytics). It works offline and sends nothing out.
- Light and dark mode. Follow the system setting.
- Print stylesheet: hide the search box, keep the tiles and the bars.
- Numbers use tabular digits.
- Mobile-friendly: two tile columns at most.
- The file lists everyone. It is for the owner only (Section 9.6).

## 10. Exceptions and edge cases

The tool must **not crash** on these. It lists them in the exceptions report and keeps the totals correct.

| Case | State | Handling |
|---|---|---|
| Usage row matches no directory user (`NoMatch`) | `NotHere` | Not charged. In Not-found report. Fix with `LinkTo` or `Exclude`. |
| Directory user is disabled | `NotHere` | Not charged. In Not-found report. |
| Override `Exclude = Y` | `NotHere` | Not charged. In Not-found report. |
| Usage row matches more than one user (`AmbiguousMatch`) | `NeedsOwner` | Do not pick. Blocks `FINAL`. Fix with `LinkTo`. |
| User has no manager, or manager is disabled or not found | `NeedsOwner` | Blocks `FINAL`. Fix with `Manager`. |
| Row matched by a fallback rule (not rule 1) | `Charged` | Info line in the match report. |
| `PreferEnabled` removed disabled duplicates | `Charged` | Info line in the match report. |
| `Access Options` value is not one of the two known values | — | Stop with a clear error. |
| Token row with blank or non-numeric `Tokens Used` | — | Stop with a clear error. |
| Seat row with `Tokens Used` > 0 | `Charged` | Warn. Ignore the tokens. |
| Seat row for an offering with no price in the quote | — | Stop with a clear error. Check `OfferingAliases`. |
| Same user has two rows for the same offering | `Charged` | Warn. |
| Offering has a price but no pool seat rows | — | Unrecoverable (Section 7.4). |
| Token pool has a price but no pool tokens | — | Unrecoverable (Section 7.4). |
| `IdAttribute` values repeat in the snapshot | — | Stop with a clear error. |
| Manager chain loops | `Charged` | Warn. |
| User has no cost center | `Charged` | Not an exception. Leave blank. |

## 11. Requirements

**Functional**
- FR-1: Read the usage report (CSV/XLSX), directory snapshot, quote, overrides, and profile. Validate them.
- FR-2: Map usage columns to canonical fields using the profile. No code change for a new report layout.
- FR-3: Match usage rows to directory users using the ordered rules, the normalize options, and `PreferEnabled`.
- FR-4: Set row states. Exclude `NotHere` rows from all divisors.
- FR-5: Calculate seat and token charges per Section 7.
- FR-6: Apply the manager rules and overrides per Section 8. Override keys are configurable.
- FR-7: Reconcile. Set `FINAL` or `DRAFT`. Stop on unrecoverable pools unless `-AllowUnrecovered`.
- FR-8: Write **all** the outputs in Section 9 on every run. Output switches come later (M9).
- FR-9: Same inputs give the same charges, in the same order, every time.
- FR-10: Vendor charge rules are separate modules (Section 12).
- FR-11: `Export-AdUsers.ps1` makes the snapshot from a configurable attribute list.
- FR-12: Write the safe diagnostics file (Section 9.5) on every run, including failed runs.

**Non-functional**
- NFR-1: Inputs contain personal data. Never commit real data. Never put real data in tests or logs. Diagnostics must hold none.
- NFR-2: PowerShell 7. Runs on a normal Windows laptop. No server.
- NFR-3: Every number in a report traces to an audit row.
- NFR-4: A non-developer can run it with one command and a profile.
- NFR-5: Nothing in Section 2's list is hard-coded.
- NFR-6: Speed. Build a hashtable index of the directory for each match rule once (normalized value → list of users). Do not search the directory with `Where-Object` for every row.
- NFR-7: Encoding. Read the usage file as UTF-8 unless the profile says otherwise. Write CSV files as UTF-8 with BOM, so Excel shows non-English names correctly.
- NFR-8: Output safety. Write any text cell that starts with `=`, `+`, `-` or `@` as text (in CSV, prefix it with a single quote).
- NFR-9: The dashboard file makes no external calls and loads nothing from the internet.

## 12. Design

**Stack**
- PowerShell 7 (not 5.1)
- `Get-ADUser` (RSAT) for the AD export
- `ImportExcel` module for XLSX read and write
- Pester 5 for tests
- `[decimal]` for all money
- Dashboard: one static HTML file (inline data, Chart.js inlined or loaded from a local file)

**Vendor rule modules**
- Each vendor has one file in `Rules/`.
- A rule declares: its name, the canonical fields it needs, and a function that takes pool rows + quote and returns charge rows.
- The core code finds rules by the profile's `Vendor` name.
- The core code never contains vendor logic.

**Layout**

```
sw-chargeback/
  README.md
  CLAUDE.md                     # short notes for Claude Code (copy Section 14)
  config/
    profiles/
      autodesk.psd1             # input profile
    quotes/
      <period>-autodesk.psd1    # quote values (fake in the repo)
    overrides.csv
  scripts/
    Export-AdUsers.ps1
    Invoke-Chargeback.ps1       # thin wrapper
  src/Chargeback/
    Chargeback.psd1
    Chargeback.psm1
    Public/
      Invoke-Chargeback.ps1
      Test-ChargebackInput.ps1
    Private/
      Import-UsageFile.ps1      # CSV/XLSX + column map + aliases
      Import-AdSnapshot.ps1     # + index per match rule
      Resolve-UserMatch.ps1     # ordered rules + normalize + PreferEnabled
      Resolve-Override.ps1      # KeyRules, ManagerLookup, LinkTo, Exclude
      Resolve-Mapping.ps1       # row states + manager + cost center
      Invoke-LargestRemainder.ps1
      Write-Statement.ps1
      Write-Summary.ps1
      Write-NotFound.ps1
      Write-Exceptions.ps1
      Write-Audit.ps1
      Write-Diagnostics.ps1
      Write-Dashboard.ps1
      Write-Manifest.ps1        # every Write-* takes the same result object (Section 9)
    Rules/
      Autodesk.ps1
  tests/                        # *.Tests.ps1 (Pester 5)
  samples/                      # fake data only
  inputs/                       # gitignored. Real data.
  output/                       # gitignored
```

**Run command (target)**

```powershell
Invoke-Chargeback -Profile config/profiles/autodesk.psd1 `
                  -Quote   config/quotes/2027-autodesk.psd1 `
                  -Usage   inputs/usage.xlsx `
                  -Ad      inputs/ad-snapshot.csv `
                  -Overrides config/overrides.csv
```

## 13. Milestones and TODO

**M0 — Prep (before code)**
- [ ] Get the full list of usage report headers (the owner gave 5 of at least 24). Look for a username column.
- [x] Exact `Access Options` values: `Seats` and `Tokens` (confirmed by owner).
- [ ] Get the XLSX sheet name and header row (if XLSX).
- [ ] Get the directory attribute names: manager, logon names, mail, enabled flag. Cost center only if wanted.
- [ ] Make fake sample data in the real layout. Fake names, fake emails, fake prices.
- [ ] Resolve the open questions below (or accept the defaults).

**M1 — Profiles, ingest, diagnostics**
- [ ] Profile loader and validator (Section 5.5).
- [ ] Usage reader: CSV and XLSX, column map, offering aliases.
- [ ] Safe diagnostics file (Section 9.5). Build it first. The owner will use it for all feedback.
- [ ] `Export-AdUsers.ps1` with configurable attributes, enabled and disabled users, manager resolution.
- [ ] Directory snapshot reader with ID uniqueness check.

**M2 — Matching**
- [ ] Normalize functions (all options in Section 5.2).
- [ ] Directory index per rule. Ordered rules. `PreferEnabled`. `NoMatch` and `AmbiguousMatch`.
- [ ] Match report.
- [ ] Tests: email form, UPN form, `DOMAIN\sam` form, ambiguous, no match, disabled duplicate.

**M3 — Overrides and states**
- [ ] Override loader and validator (Section 5.3). Configurable `KeyRules`, `ManagerLookup`.
- [ ] `Link`, `Manager`, `CostCenter`, `Exclude`.
- [ ] Row states: `Charged`, `NeedsOwner`, `NotHere`.
- [ ] Optional cost center clean-up.

**M4 — Allocation engine**
- [ ] Vendor rule interface + Autodesk rule.
- [ ] Pools exclude `NotHere` rows. Seat split, token rate, token charge.
- [ ] Largest-remainder rounding per pool with deterministic ties.
- [ ] Tests: worked example (Section 7.5), invariant (also with random data), unrecoverable pools, ordering.

**M5 — Reconcile and first numbers** *(cut line: the owner can brief people after this)*
- [ ] Reconciliation. Run status `FINAL` / `DRAFT`. `-AllowUnrecovered`.
- [ ] Summary CSV by manager.
- [ ] Not-found report and `overrides-template.csv`.
- [ ] Exceptions report.

**M6 — Per-manager statements**
- [ ] One Excel file per manager + `NO OWNER` statement, following Section 9.7.
- [ ] Org tree from the manager chain (Section 8). `Resolve-ChargeOwner` as one function.
- [ ] Roll-up workbooks (Summary sheet + one sheet per manager). Tests: the three roll-up checks in Section 8.

**M7 — Audit trail and run folder**
- [ ] Row-level audit CSV. Run manifest with input hashes. `-ArchiveInputs`.

**M8 — Dashboard**
- [ ] Static HTML with the views in Section 9.6 and the design in Section 9.7.

**M9 — Finish**
- [ ] README and run instructions.
- [ ] Prove a second vendor works: new profile + new rule file, no core changes.
- [ ] Output switches (for example `-Outputs` and `-Skip`, and a switch for copying inputs). Add them after the owner has seen the full output set and knows what to turn off.

**Parking lot (not v1)**
- `Show-ChargeExplanation`: explain one user's charge in plain English. The owner wants to define what it shows. Design it with the owner after M7. The audit trail already keeps the data it needs.
- Finance upload file
- PDF statements
- Live AD read
- Charge owner mode `OwnerList`: the charge moves up to a listed budget owner. Owner resolution is one function, so this is a small change.

### Confirmed by owner

- Usage report: one row per user per offering.
- `Access Options` values: `Seats` and `Tokens`.
- Quote: a total price per offering, plus one final token pool price. USD.
- Users who are not here are not charged. Their share is spread over the remaining users. The owner wants a list of them.
- The owner controls the usage timeframe. The tool trusts the file.
- Runs happen at the renewal. Ownership is read at run time.
- Matching, override keys, and the user ID attribute are all configurable.
- Cost center is optional and informational.
- `ImportExcel` is allowed. Statements are Excel.
- The owner runs the tool on real data locally and relays feedback.
- Visual design: the manager statement and owner dashboard in Section 9.7 (owner approved the mockup). Excel statements only. The dashboard shows names and is owner-only.
- A manager who has managers beneath them gets a roll-up workbook: a Summary sheet plus one sheet per manager.

### Open questions (answer in M0)

1. **Directory attribute names** for manager, enabled flag, and logon names. *Get from the real export.*
2. **Username column:** is there a username column besides `Source Email`? *Check the real report. If yes, add the UPN and sAMAccountName match rules.*
3. **Mixed access:** can one user have both a seat row and a token row for the **same** offering? *Default: warn, charge each row by its own access option.*
4. **Rows with no usable owner** (`AmbiguousMatch`, no manager, disabled manager): *Default: they are charged, they have no owner, and they block a `FINAL` run until the owner fixes them with an override.*
5. **Unrecoverable pool** (a price with nobody to charge): *Default: stop the run unless `-AllowUnrecovered`.*
6. **Who pays:** the user's direct manager, or a budget owner higher up? *The owner is not sure yet. Default: direct manager. Roll-up workbooks cover the higher levels either way.*

## 14. How to start (instructions for Claude Code)

1. Read this whole file.
2. **Working agreement.** You build and test with **fake data only**. Do not ask for real data. The owner runs the tool on real data on a work machine and reports back. When something fails, ask for the **diagnostics file** (Section 9.5), never raw rows.
3. Do **not** write calculation code yet. First ask the owner for:
   - the full usage report header list (headers only, no rows)
   - the directory attribute names (manager, enabled flag, logon names, mail)
   - whether the report has a username column
   - the XLSX sheet name and header row (if any)
   Use fake prices for the quote.
4. Ask the owner to answer the open questions in Section 13, or confirm the defaults.
5. Put the plan for the session in the task list. Show it to the owner before you build.
6. Set up the repo layout in Section 12. Add `inputs/` and `output/` to `.gitignore` first.
7. Build M1 first, with the diagnostics file. Then write the worked example (Section 7.5) as a failing Pester test and build the Autodesk rule until it passes.
8. Build in milestone order. Run the tests after each milestone.
9. Never put real user data in the repo, in tests, in logs, or in commit messages.
10. Keep money in `[decimal]`. Never use `[double]` for money.
11. Never hard-code anything listed in Section 2.
12. If an input does not match what this spec says, stop and ask. Do not guess.
