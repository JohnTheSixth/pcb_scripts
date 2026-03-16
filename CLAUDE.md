# CLAUDE.md — Cadence Allegro SKILL Project

## Project Purpose

This folder contains Cadence Allegro SKILL (`.il`) scripts for PCB design automation. Scripts are loaded directly into Allegro PCB Designer and run as interactive commands.

---

## Environment

- **Tool:** Cadence Allegro PCB Designer (Windows)
- **Language:** SKILL (Cadence's Lisp dialect)
- **Deployment:** Single `.il` file per script — no external tools, no companion `.form` files unless explicitly required
- **Loading:** `skill load("script_name.il")` in the Allegro console
- **Constraints:** Windows only, self-contained, no shell/subprocess calls

---

## SKILL Language Conventions

### Syntax Basics

```skill
; Comments use semicolons
(procedure (myProcedure arg1 arg2)
  (let (localVar1 localVar2)
    localVar1 = someValue
    ; SKILL uses prefix notation for most things but infix for assignment
  )
)
```

- **Assignment:** `x = value` (infix)
- **Arithmetic:** `plus(a b)`, `difference(a b)`, `times(a b)`, `quotient(a b)`
- **Comparison:** `equal`, `ngreaterp` (>=), `nlessp` (<=), `greaterp` (>), `lessp` (<)
- **Boolean:** `and`, `or`, `not`, `null`
- **Conditionals:** `if/then/else`, `when`, `unless`, `cond`
- **Loops:** `foreach`, `while`
- **Lists:** `cons`, `car`, `cdr`, `list`, `nconc`, `append`, `member`, `assoc`, `mapcar`
- **Strings:** `strcat`, `parseString`, `substring`, `rexMatchp`, `sprintf`, `printf`, `fprintf`
- **Type checks:** `stringp`, `numberp`, `symbolp`, `listp`, `null`

### Procedure Structure

```skill
(procedure (procedureName arg1 arg2)
  (let (local1 local2 local3)
    local1 = someValue
    ; body
    returnValue
  )
)
```

### File I/O

```skill
fp = infile("path/to/file.txt")
(while (gets line fp) ... )
(close fp)

fp = outfile("path/to/output.txt")
(fprintf fp "format %s\n" value)
(close fp)
```

### Error Handling Pattern

```skill
(unless fp
  (axlUIWarn "Cannot open file")
  (return nil)
)
```

---

## Allegro SKILL API — Commonly Used Functions

### UI / Dialogs

| Function | Purpose |
|---|---|
| `axlUIConfirm(msg)` | OK/Cancel dialog — returns `t` or `nil` |
| `axlUIWarn(msg)` | Warning message popup |
| `axlUIStatusMessage(msg)` | Status bar message |
| `axlDMFileBrowse(filterList title)` | File browser dialog — returns path string or nil |

### Database Access

| Function | Purpose |
|---|---|
| `axlDBGetDesign()` | Returns the current design object |
| `design->components` | List of all component objects |
| `design->designOutline->bBox` | Board outline bounding box |
| `axlDBGetExtents()` | Fallback bounding box if no outline |
| `axlDBGetComp(refdes)` | Get component object by refdes string |
| `axlDBCreateSymbol(refdes x y nil rotation)` | Place an unplaced component |
| `axlGetVariable("UNITS")` | Returns `"MM"` or `"MILS"` |
| `axlGetVariable("DESIGN_PATH")` | Returns current design directory |

### Component Object Properties

```skill
comp->name       ; refdes string (e.g. "U1", "R23")
comp->cellName   ; footprint/cell name
comp->symbol     ; nil if unplaced, symbol object if placed
comp->pins       ; list of pin objects
pin->net->name   ; net name string connected to this pin
```

### Transactions (Undo Support)

```skill
axlDBTransactionStart("Description for undo menu")
; ... placement calls ...
axlDBTransactionCommit()
```

### Command Registration

```skill
axlCmdRegister("command_name" 'procedureName)
; User types: command_name in Allegro console
```

---

## Script Architecture Patterns

### Single-File Script Template

```skill
; Header comment block with description and usage
; Configurable constants at top
; axlCmdRegister call
; Main entry procedure
; Helper procedures prefixed with _<abbr> to avoid namespace collisions
; Load confirmation printf at bottom
```

### Namespace Convention

All internal helper procedures are prefixed with `_<scriptAbbr>`:
- `group_parts_by_schematic.il` → prefix `_gpbs`
- New scripts should follow same pattern: derive 3–5 char abbreviation from script name

### Configuration Block Pattern

```skill
; At the top of the file, before procedures:
_scriptConfig_spacing = 200
_scriptConfig_gap     = 1000
_scriptPowerNets      = '("GND" "VCC" "VDD")
```

### Unplaced Component Check

Always re-check before placing to handle re-runs gracefully:
```skill
(when (and existComp (null existComp->symbol))
  sym = axlDBCreateSymbol(refdes x y nil 0)
)
```

### Unit Scaling

```skill
units = axlGetVariable("UNITS")
(when (equal units "MM")
  scale = 0.0254   ; convert mils to mm
)
value = times(milValue scale)
```

---

## Refdes Classification

Standard prefix classification used across scripts:

| Type | Prefixes |
|---|---|
| Passive | R, C, L, FB, BEAD, DNP, RN, CN |
| IC | U, IC, Q, XTAL, Y, OSC, CR, Z, VR |
| Connector | J, P, CN, XP, XJ, HDR |
| Diode | D, LED, ZD, TVS |
| Testpoint/Mech | TP, FID, MP, MH, H |

---

## Power Net Exclusion

When analyzing net connectivity for signal-level affinity, always exclude:
- Explicit list: `GND VCC VDD VSS VBAT AGND DGND PWR POWER +3V3 +5V +12V` etc.
- Regex patterns: `^[+-]?[0-9]*V[0-9A-Z_]*$`, `^VDD`, `^VCC`, `^VSS`, `^GND`, `^PWR`

---

## Files in This Project

| File | Purpose |
|---|---|
| `group_parts_by_schematic.il` | Groups unplaced components by schematic page using PDF-exported text; associates passives with ICs via net affinity; generates report; places in staging area |
| `sample.il` | Minimal hello-world reference for syntax style |

---

## Workflow: PDF Schematic → Board Staging

1. Receive schematic as PDF
2. Forward-annotate into `.brd` (parts appear unplaced)
3. Export PDF to plain text (Adobe: File > Save As Other > Text Plain)
4. Run `skill load("group_parts_by_schematic.il")` then `group_parts`
5. Select the `.txt` export; script groups components by page
6. Review `group_parts_report.txt` in design directory
7. Confirm placement into off-board staging area
8. Manually place groups onto board from staging area

---

## Do's and Don'ts

**Do:**
- Prefix all internal procedures with `_<abbr>` to avoid collisions
- Wrap multi-step placements in `axlDBTransactionStart/Commit` for undo
- Re-check `comp->symbol == nil` before placing (re-run safety)
- Use `axlUIConfirm` for destructive or irreversible actions
- Exclude power nets from connectivity/affinity analysis
- Test unit handling (mils vs mm) via `axlGetVariable("UNITS")`
- Write configurable spacing constants at the top of each script

**Don't:**
- Use external tools (pdftotext, Python, shell commands) — Windows, self-contained only
- Create `.form` files unless the UI complexity truly requires it
- Hardcode absolute paths
- Skip transaction wrapping for placement operations
- Use lowercase in refdes pattern matching (Allegro refdes are always uppercase)
