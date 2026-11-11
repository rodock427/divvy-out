# DivvyOut — notes for Claude Code

DivvyOut charges internal software cost (v1: Autodesk) to each user's manager.
Full spec: `chargeback-tool-spec.md`. Choices the spec left open: `DECISIONS.md`.

## Working agreement (spec Section 14)

- **Fake data only.** Never ask for real names, emails, prices, or rows. Never put real data in the repo, tests, logs, or commit messages.
- The owner runs the tool on real data at work. When something fails, ask for `diagnostics.txt`, never raw rows.
- If an input does not match the spec, or the spec is unclear about anything that affects the math, **stop and ask**. Do not guess.
- Build in milestone order (spec Section 13). Run the tests after each milestone. Commit when they pass.
- Write short, plain English.

## Hard rules

- **Money is `[decimal]`. Never `[double]`.** Never `Measure-Object -Sum` on money (it returns `[double]`).
- **Nothing in this list is hard-coded in `src/`. It all goes in the profile:**
  - report header names
  - the text of access option values
  - which fields match a usage row to a directory user
  - which directory attribute is the unique user ID
  - which fields the override file uses to find a person
  - directory attribute names (manager, enabled flag, cost center, display name)
  If you are about to write `mail`, `sAMAccountName`, `Seats`, or `Source Email` in `src/`, stop. `tests/Guard.Tests.ps1` checks this.
- Core code never contains vendor logic. Vendor math lives in `src/DivvyOut/Rules/<Vendor>.ps1`.
- Every output writer takes the one result object. No writer reads another writer's file.
- `diagnostics.txt` holds no personal data: no names, no emails, no money (unless `-IncludeAmounts`). Issue `Message` text must be safe. Values go in `Detail` (owner-only).
- Sorting that affects money or output order uses ordinal comparison and a full key (ends with the source row number). Never depend on hashtable order.
- `inputs/` and `output/` are gitignored. Real data lives there only.

## Run the tests

```powershell
pwsh -NoProfile -Command "Invoke-Pester ./tests -Output Detailed"
```

Rebuild the fake sample data: `pwsh -NoProfile -File samples/New-SampleData.ps1`
