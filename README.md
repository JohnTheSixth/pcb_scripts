# PCB Scripts

A general-purpose repository for PCB design automation scripts, primarily targeting **Cadence Allegro PCB Designer**.

## Overview

Scripts are written in **SKILL** (Cadence's Lisp dialect) and loaded directly into the Allegro console:

```
skill load("script_name.il")
```

Each script is self-contained in a single `.il` file — no external tools or companion files required.

## Scripts

| File | Command | Description |
|------|---------|-------------|
| `group_parts_by_schematic.il` | `group_parts` | Groups unplaced components by schematic page using a PDF-exported text file; associates passives with nearby ICs via net affinity; places groups in an off-board staging area |
| `sample.il` | — | Minimal hello-world reference for syntax style |

## Workflow: PDF Schematic → Board Staging

1. Receive schematic as PDF
2. Forward-annotate into `.brd` (parts appear unplaced)
3. Export PDF to plain text (Adobe Acrobat: **File > Save As Other > Text Plain**)
4. Load and run the grouping script:
   ```
   skill load("group_parts_by_schematic.il")
   group_parts
   ```
5. Select the exported `.txt` file when prompted
6. Review `group_parts_report.txt` in the design directory
7. Confirm placement — components are staged in a grid off the board
8. Manually place groups onto the board

## Environment

- **Tool:** Cadence Allegro PCB Designer (Windows)
- **Language:** SKILL
- **Constraints:** Windows only, self-contained (no shell/subprocess calls)

## Adding New Scripts

- Prefix all internal helper procedures with a short abbreviation (e.g., `_abc`) to avoid namespace collisions
- Wrap multi-step placements in `axlDBTransactionStart` / `axlDBTransactionCommit` for undo support
- Add configurable spacing/layout constants at the top of the file
- Register the user-facing command with `axlCmdRegister`
