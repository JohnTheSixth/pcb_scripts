# Plan: `group_parts_by_schematic.il` — Allegro SKILL Script

## Context

When new schematics arrive as a PDF, forward-annotation loads parts into the `.brd` file but leaves them unplaced and disorganized. This script cross-references a text export of the schematic PDF with the board's unplaced components, groups them by schematic page, associates passives with their main IC via net connectivity, generates a text report, and physically places the groups in an off-board staging area.

**Constraints:** Windows, self-contained (no external tools like pdftotext), single `.il` file deployment.

---

## Architecture

Single file: `group_parts_by_schematic.il` — no `.form` file needed (uses built-in dialogs).

```
User types: group_parts
  → groupPartsBySchematic()
    → axlUIConfirm()           — show instructions for PDF-to-text export
    → axlDMFileBrowse()        — user selects the .txt file
    → _gpbsParseTextFile()     — parse text, extract refdes per page
    → _gpbsBoardData()         — get unplaced components + net connectivity
    → _gpbsCrossReference()    — match text refdes to board components, group by page
    → _gpbsAssociatePassives() — within each page, link passives to ICs by shared nets
    → _gpbsGenerateReport()    — write grouped report to text file
    → _gpbsPlaceComponents()   — place groups in off-board staging area (with confirm)
```

All procedures prefixed `_gpbs` to avoid namespace collisions.

---

## Implementation Steps

### Step 1: File scaffold and command registration

- Header comment block with usage instructions
- Global config variables (spacing constants, power net patterns)
- `axlCmdRegister("group_parts" 'groupPartsBySchematic)`
- Main entry procedure with instruction dialog + file browser

### Step 2: Text file parser (`_gpbsParseTextFile`)

- Read file line-by-line via `infile()`/`gets()`
- Detect page breaks via form feed character (ASCII 12 / `\014`)
- Tokenize each line with `parseString(line " \t,;(){}[]=/\\"'")`
- Match tokens against refdes pattern: `^[A-Z]+[0-9]+$` (handles R1, C23, U5, FB12, TP3, etc.)
- Cross-reference against actual board components to filter false positives
- Build association list: `refdes → page_number`

### Step 3: Board data extraction (`_gpbsBoardData`)

- `axlDBGetDesign() -> design->components`
- Filter unplaced: `comp->symbol == nil`
- For each: extract `comp->name`, `comp->cellName`, pin/net connectivity
- Classify by refdes prefix: passive (R/C/L/FB), IC (U/IC/Q/XTAL/Y), connector (J/P), diode (D/LED), testpoint (TP/FID), other
- Exclude power/ground nets from connectivity data (GND, VCC, VDD, VSS, +3V3, +5V, etc. and regex `^[+-]?[0-9]*V[0-9]*`)

### Step 4: Cross-reference and page grouping (`_gpbsCrossReference`)

- Match unplaced board components against text file page map
- Group into `pageGroups[pageNum] = list of comp data`
- Track `unmatchedBoard` (in board but not in text) and `unmatchedText` (in text but not unplaced in board)

### Step 5: IC affinity analysis (`_gpbsAssociatePassives`)

- Per page: separate ICs from passives/others
- For each passive, count shared signal nets with each IC on the same page
- Assign passive to IC with highest affinity score
- Zero-affinity passives go to "UNASSOCIATED" bucket

### Step 6: Report generation (`_gpbsGenerateReport`)

- Write to `<design_directory>/group_parts_report.txt`
- Format: Summary → per-page sections → per-IC sub-groups with passive lists → unmatched sections
- Display report path via `axlUIConfirm()`

### Step 7: Physical placement (`_gpbsPlaceComponents`)

- Find board bounding box via `design->designOutline->bBox` (fallback: `axlDBGetExtents`)
- Detect units via `axlGetVariable("UNITS")`, scale spacing constants accordingly
- Staging area: right of board edge + configurable gap
- Layout per page: IC at center, passives in grid around it, page groups stacked vertically
- Wrap in `axlDBTransactionStart()`/`axlDBTransactionCommit()` for undo support
- Re-check `comp->symbol == nil` before each placement (handles re-runs)
- `axlDBCreateSymbol(refdes, x:y, nil, 0)` for each component
- Confirm before placing via `axlUIConfirm()`

---

## Key Design Decisions

| Decision | Rationale |
|---|---|
| No `.form` file | Single-file deployment; use `axlDMFileBrowse` + `axlUIConfirm` instead |
| User exports PDF to text manually | SKILL can't read PDFs; no external tools allowed; Adobe "Save As Text" is reliable for vector PDFs |
| Token-based refdes extraction | More robust than regex-on-full-line; naturally handles varied whitespace/formatting |
| Power net exclusion from affinity | Power nets connect everything, making affinity scores meaningless |
| Transaction wrapping for placement | Allows single undo of all placements |
| Configurable constants at top of file | Users can adjust spacing, power net list, refdes prefix classification |

---

## Configurable Constants (top of script)

```skill
_gpbsConfig_boardGap      = 2000   ; gap from board edge to staging area (mils)
_gpbsConfig_icSpacing     = 800    ; horizontal space between IC subgroups
_gpbsConfig_passiveGrid   = 200    ; grid spacing for passives around IC
_gpbsConfig_pageGapY      = 1500   ; vertical gap between page groups
_gpbsConfig_maxColsPerRow = 8      ; max passives per row in a subgroup
_gpbsPowerNets = '("GND" "VCC" "VDD" "VSS" "VBAT" "AGND" "DGND")
```

---

## Error Handling

| Scenario | Response |
|---|---|
| No file selected | `axlUIConfirm` message, abort |
| File can't be opened | Error with path, abort |
| No unplaced components | Info message, still generate report |
| No refdes found in text | Warning, process board data only |
| No matches between text and board | Warning in report, skip placement |
| `axlDBCreateSymbol` returns nil | Log failure, continue with remaining |
| No board outline | Fallback to `axlDBGetExtents` |
| Script run twice (parts already placed) | Re-check `comp->symbol == nil`, skip placed |

---

## Files

- **Create:** `/Users/jwburge6/Development/testapp/group_parts_by_schematic.il`
- **Reference:** `/Users/jwburge6/Development/testapp/sample.il` (syntax style)

---

## Verification

1. Load script in Allegro: `skill load("group_parts_by_schematic.il")`
2. Run command: `group_parts`
3. Verify instruction dialog appears with PDF-to-text instructions
4. Select a text file exported from a schematic PDF
5. Confirm report is generated at `<design_dir>/group_parts_report.txt` with correct groupings
6. Confirm components are placed in staging area, grouped by page and IC
7. Verify undo (Ctrl+Z) removes all staged placements in one step
8. Re-run script to confirm it handles already-placed components gracefully
