; =============================================================================
; group_parts_by_schematic.il
; =============================================================================
; DESCRIPTION:
;   Groups unplaced board components by schematic page using a text export of
;   the schematic PDF. Associates passives with their nearest IC via net
;   connectivity, generates a text report, and optionally places groups in an
;   off-board staging area.
;
; USAGE:
;   1. In Adobe Acrobat (or similar), open the schematic PDF and save as .txt:
;      File > Save As Other > More Options > Text (Plain) > Save
;   2. Load this script in Allegro:
;        skill load("group_parts_by_schematic.il")
;   3. Run the command:
;        group_parts
;   4. When prompted, select the exported .txt file.
;   5. Review the report written to <design_dir>/group_parts_report.txt
;   6. Confirm to place groups in the off-board staging area.
;
; UNDO:
;   All placements are wrapped in a single transaction — one Ctrl+Z removes them.
;
; CONSTRAINTS:
;   Windows, single-file deployment, no external tools required.
; =============================================================================

; ---------------------------------------------------------------------------
; Configurable constants — adjust these for your board's spacing preferences
; ---------------------------------------------------------------------------
_gpbsConfig_boardGap      = 2000   ; gap from board edge to staging area (mils)
_gpbsConfig_icSpacing     = 800    ; horizontal space between IC subgroups (mils)
_gpbsConfig_passiveGrid   = 200    ; grid spacing for passives around IC (mils)
_gpbsConfig_pageGapY      = 1500   ; vertical gap between page groups (mils)
_gpbsConfig_maxColsPerRow = 8      ; max passives per row in a subgroup

; Power/ground nets excluded from affinity scoring
_gpbsPowerNets = '("GND" "VCC" "VDD" "VSS" "VBAT" "AGND" "DGND"
                   "PWR" "POWER" "EARTH" "CHASSIS" "SHIELD"
                   "+3V3" "+5V" "+12V" "+15V" "-12V" "-15V"
                   "3V3" "5V" "12V" "15V" "1V8" "2V5" "3V")

; Refdes prefix classification
_gpbsPassivePrefixes   = '("R" "C" "L" "FB" "BEAD" "DNP" "RN" "CN")
_gpbsIcPrefixes        = '("U" "IC" "Q" "XTAL" "Y" "OSC" "CR" "Z" "VR")
_gpbsConnPrefixes      = '("J" "P" "CN" "XP" "XJ" "HDR")
_gpbsDiodePrefixes     = '("D" "LED" "ZD" "TVS")
_gpbsTpPrefixes        = '("TP" "FID" "MP" "MH" "H")

; =============================================================================
; Command registration
; =============================================================================
axlCmdRegister("group_parts" 'groupPartsBySchematic)

; =============================================================================
; MAIN ENTRY POINT
; =============================================================================
(procedure (groupPartsBySchematic)
  (let (instrMsg txtFile pageMap boardData crossRef report placed)

    ; -------------------------------------------------------------------------
    ; Show instructions for exporting PDF to text
    ; -------------------------------------------------------------------------
    instrMsg = strcat(
      "GROUP PARTS BY SCHEMATIC\n"
      "========================\n\n"
      "Before continuing, export your schematic PDF to plain text:\n\n"
      "  Adobe Acrobat:  File > Save As Other > More Options\n"
      "                  > Text (Plain) > Save\n\n"
      "  Foxit Reader:   File > Export to > Text\n\n"
      "  Command line:   pdftotext -layout schematic.pdf schematic.txt\n\n"
      "The text file must preserve page breaks (form-feed characters).\n\n"
      "Click OK when ready to select the text file, or Cancel to abort."
    )

    (unless (axlUIConfirm instrMsg)
      (axlUIWarn "group_parts: Aborted by user.")
      (return nil)
    )

    ; -------------------------------------------------------------------------
    ; Browse for the text file
    ; -------------------------------------------------------------------------
    txtFile = axlDMFileBrowse(
      '(("Text Files" "*.txt")
        ("All Files"  "*.*"))
      "Select schematic text export"
    )

    (when (null txtFile)
      (axlUIWarn "group_parts: No file selected. Aborted.")
      (return nil)
    )

    axlUIStatusMessage(strcat("Reading text file: " txtFile))

    ; -------------------------------------------------------------------------
    ; Parse text file and extract board data
    ; -------------------------------------------------------------------------
    pageMap   = _gpbsParseTextFile(txtFile)
    boardData = _gpbsBoardData()

    (when (null boardData)
      (axlUIWarn "group_parts: No unplaced components found in design.")
      (return nil)
    )

    ; -------------------------------------------------------------------------
    ; Cross-reference and group by page
    ; -------------------------------------------------------------------------
    crossRef = _gpbsCrossReference(pageMap boardData)
    crossRef  = _gpbsAssociatePassives(crossRef boardData)

    ; -------------------------------------------------------------------------
    ; Generate report
    ; -------------------------------------------------------------------------
    report = _gpbsGenerateReport(crossRef boardData txtFile)
    (axlUIConfirm strcat("Report written to:\n\n" report "\n\nClick OK to continue to placement, or Cancel to skip placement.") )

    ; -------------------------------------------------------------------------
    ; Physical placement (with confirmation)
    ; -------------------------------------------------------------------------
    (when (axlUIConfirm "Place grouped components in off-board staging area?\n\nThis action can be undone with Ctrl+Z.")
      _gpbsPlaceComponents(crossRef)
    )

    t
  )
)

; =============================================================================
; Step 2: Text file parser
; =============================================================================
(procedure (_gpbsParseTextFile txtFile)
  ; Returns an association list: ( (refdes . pageNum) ... )
  ; Page numbers are 1-based integers.
  (let (fp line pageNum pageMap tokens tok boardRefSet)

    ; Pre-build a set of all board component names for filtering false positives
    ; We'll validate against actual board components in _gpbsCrossReference,
    ; so here we do a liberal extract of any token matching refdes pattern.
    pageNum = 1
    pageMap = nil
    fp = infile(txtFile)

    (unless fp
      (axlUIWarn strcat("group_parts: Cannot open file: " txtFile))
      (return nil)
    )

    line = ""
    (while (gets line fp)
      ; Check for form-feed (page break) — ASCII 12
      (when (rexMatchp "\\014" line)
        pageNum = pageNum + 1
      )

      ; Tokenize the line
      tokens = parseString(line " \t,;(){}[]=/\\\"'<>|@#$%^&*!?~`+-:")

      ; Check each token against refdes pattern
      (foreach tok tokens
        (when (and
                tok
                (stringp tok)
                (ngreaterp (length tok) 0)
                (_gpbsIsRefdesPattern tok)
              )
          ; Add to map if not already seen (first occurrence wins — page is correct)
          (unless (assoc tok pageMap)
            pageMap = cons(cons(tok pageNum) pageMap)
          )
        )
      )
    )

    (close fp)

    (printf "group_parts: Parsed %d pages, found %d candidate refdes tokens.\n"
            pageNum (length pageMap))

    pageMap
  )
)

; ---------------------------------------------------------------------------
; Helper: does this token look like a refdes? (e.g. R1, C23, U5, FB12, TP3)
; ---------------------------------------------------------------------------
(procedure (_gpbsIsRefdesPattern tok)
  ; Must start with 1-5 uppercase letters followed by 1-6 digits
  ; and be entirely uppercase alphanumeric (no lowercase)
  (and
    (stringp tok)
    (rexMatchp "^[A-Z][A-Z0-9]{0,4}[0-9]+$" tok)
    ; Exclude pure numbers or single characters that aren't refdes
    (ngreaterp (length tok) 1)
  )
)

; =============================================================================
; Step 3: Board data extraction
; =============================================================================
(procedure (_gpbsBoardData)
  ; Returns a list of property lists, one per unplaced component:
  ;   '( (name refdes cellName type nets ...) ... )
  (let (design allComps comp compData result nets pin pinNets netName)

    design   = axlDBGetDesign()
    allComps = design->components
    result   = nil

    (foreach comp allComps
      ; Unplaced components have no placed symbol
      (when (null comp->symbol)
        nets   = nil
        ; Gather signal nets from all pins
        (foreach pin comp->pins
          netName = pin->net->name
          (when (and netName
                     (not (_gpbsIsPowerNet netName)))
            (unless (member netName nets)
              nets = cons(netName nets)
            )
          )
        )

        compData = list(
          'name     comp->name
          'refdes   comp->name
          'cellName comp->cellName
          'type     (_gpbsClassifyRefdes comp->name)
          'nets     nets
        )
        result = cons(compData result)
      )
    )

    (printf "group_parts: Found %d unplaced components.\n" (length result))
    result
  )
)

; ---------------------------------------------------------------------------
; Helper: is this net a power/ground net?
; ---------------------------------------------------------------------------
(procedure (_gpbsIsPowerNet netName)
  (or
    (member netName _gpbsPowerNets)
    ; Match voltage-like names: +3V3, -12V, 1V8, VDD_1V8, etc.
    (rexMatchp "^[+-]?[0-9]*V[0-9A-Z_]*$" netName)
    (rexMatchp "^VDD" netName)
    (rexMatchp "^VCC" netName)
    (rexMatchp "^VSS" netName)
    (rexMatchp "^GND" netName)
    (rexMatchp "^PWR" netName)
    (rexMatchp "^AGND" netName)
    (rexMatchp "^DGND" netName)
  )
)

; ---------------------------------------------------------------------------
; Helper: classify a refdes by its prefix
; ---------------------------------------------------------------------------
(procedure (_gpbsClassifyRefdes refdes)
  (let (prefix)
    ; Extract alphabetic prefix
    prefix = ""
    (let (i ch)
      i = 0
      (while (and (nlessp i (length refdes))
                  (rexMatchp "^[A-Z]$" (substring refdes (add1 i) 1)))
        prefix = strcat(prefix (substring refdes (add1 i) 1))
        i = i + 1
      )
    )

    (cond
      ((member prefix _gpbsPassivePrefixes)  'passive)
      ((member prefix _gpbsIcPrefixes)       'ic)
      ((member prefix _gpbsConnPrefixes)     'connector)
      ((member prefix _gpbsDiodePrefixes)    'diode)
      ((member prefix _gpbsTpPrefixes)       'testpoint)
      (t                                     'other)
    )
  )
)

; =============================================================================
; Step 4: Cross-reference and page grouping
; =============================================================================
(procedure (_gpbsCrossReference pageMap boardData)
  ; Returns an association list:
  ;   ( (pageNum . compDataList) ... )
  ; Plus sets global _gpbsUnmatchedBoard and _gpbsUnmatchedText
  (let (pageGroups compData refdes pageNum entry unmatchedBoard unmatchedText
        textRefdes boardRefdes textSet boardSet)

    pageGroups    = nil
    unmatchedBoard = nil
    unmatchedText  = nil

    ; Build a set of refdes from text
    textSet = mapcar('car pageMap)

    ; Build a set of refdes from board
    boardSet = mapcar(lambda (cd) (cadr (member 'refdes cd)) boardData)

    ; For each board component, find its page
    (foreach compData boardData
      refdes = cadr(member 'refdes compData)
      entry  = assoc(refdes pageMap)

      (if entry
        then
          pageNum = cdr(entry)
          ; Add to pageGroups
          (let (pageEntry)
            pageEntry = assoc(pageNum pageGroups)
            (if pageEntry
              then (nconc pageEntry (list compData))
              else
                pageGroups = cons(cons(pageNum (list compData)) pageGroups)
            )
          )
        else
          unmatchedBoard = cons(refdes unmatchedBoard)
      )
    )

    ; Find text refdes not in board (already placed or wrong)
    (foreach textRefdes textSet
      (unless (member textRefdes boardSet)
        unmatchedText = cons(textRefdes unmatchedText)
      )
    )

    ; Store unmatched lists as globals for report
    _gpbsUnmatchedBoard = unmatchedBoard
    _gpbsUnmatchedText  = unmatchedText

    (printf "group_parts: %d page groups, %d unmatched board, %d unmatched text.\n"
            (length pageGroups)
            (length unmatchedBoard)
            (length unmatchedText))

    pageGroups
  )
)

; =============================================================================
; Step 5: Associate passives with ICs by net affinity
; =============================================================================
(procedure (_gpbsAssociatePassives crossRef boardData)
  ; For each page group, partition into ICs and passives.
  ; Score each passive against each IC by shared signal net count.
  ; Returns the same crossRef structure but each page entry is replaced with:
  ;   (pageNum (ic . passiveList) ... (nil . unassocPassiveList))
  ; The new structure:
  ;   pageGroups = ( (pageNum . icGroupList) ... )
  ;   icGroupList = ( (icCompData . passiveList) ... (nil . unassocList) )
  (let (result pageEntry pageNum compList ics passives icData passData
        bestIc bestScore score sharedNets icNets passNets net affinityMap)

    result = nil

    (foreach pageEntry crossRef
      pageNum  = car(pageEntry)
      compList = cdr(pageEntry)

      ics      = nil
      passives = nil

      ; Partition by type
      (foreach compData compList
        (let (ctype)
          ctype = cadr(member 'type compData)
          (if (equal ctype 'ic)
            then ics      = cons(compData ics)
            else passives = cons(compData passives)
          )
        )
      )

      ; Build affinity map: (passive . ic) pairs
      affinityMap = nil

      (foreach passData passives
        passNets  = cadr(member 'nets passData)
        bestIc    = nil
        bestScore = 0

        (foreach icData ics
          icNets = cadr(member 'nets icData)
          score  = 0

          ; Count shared signal nets
          (foreach net passNets
            (when (member net icNets)
              score = score + 1
            )
          )

          (when (ngreaterp score bestScore)
            bestScore = score
            bestIc    = icData
          )
        )

        ; Associate passive with best IC (or nil if no affinity)
        affinityMap = cons(cons(passData bestIc) affinityMap)
      )

      ; Build IC groups: (icData . passiveList)
      (let (icGroups unassoc icGroup)
        icGroups = nil
        unassoc  = nil

        ; Seed groups from IC list
        (foreach icData ics
          icGroups = cons(cons(icData nil) icGroups)
        )

        ; Assign passives
        (foreach pair affinityMap
          passData = car(pair)
          icData   = cdr(pair)

          (if icData
            then
              ; Find this IC's group and append
              (let (g)
                g = assoc(icData icGroups)
                (if g
                  then (nconc g (list passData))
                  else
                    icGroups = cons(cons(icData (list passData)) icGroups)
                )
              )
            else
              unassoc = cons(passData unassoc)
          )
        )

        ; Append unassociated bucket
        (when unassoc
          icGroups = nconc(icGroups (list (cons nil unassoc)))
        )

        result = cons(cons(pageNum icGroups) result)
      )
    )

    result
  )
)

; =============================================================================
; Step 6: Report generation
; =============================================================================
(procedure (_gpbsGenerateReport crossRef boardData txtFile)
  (let (design designDir reportPath fp pageEntry pageNum icGroups icGroup
        icData passData refdes cellName ctype compData)

    design    = axlDBGetDesign()
    designDir = axlGetVariable("DESIGN_PATH")
    (when (null designDir)
      designDir = "."
    )

    reportPath = strcat(designDir "/group_parts_report.txt")
    fp = outfile(reportPath)

    (unless fp
      (axlUIWarn strcat("group_parts: Cannot write report to: " reportPath))
      (return reportPath)
    )

    ; Header
    (fprintf fp "GROUP PARTS BY SCHEMATIC REPORT\n")
    (fprintf fp "================================\n")
    (fprintf fp "Generated: %s\n" (getCurrentTime))
    (fprintf fp "Text file: %s\n" txtFile)
    (fprintf fp "Board:     %s\n\n" (or design->name "unknown"))

    ; Summary
    (fprintf fp "SUMMARY\n")
    (fprintf fp "-------\n")
    (fprintf fp "  Total unplaced components: %d\n" (length boardData))
    (fprintf fp "  Page groups found:         %d\n" (length crossRef))
    (fprintf fp "  Unmatched (board only):    %d\n" (length _gpbsUnmatchedBoard))
    (fprintf fp "  Unmatched (text only):     %d\n\n" (length _gpbsUnmatchedText))

    ; Per-page sections
    (fprintf fp "PAGE GROUPS\n")
    (fprintf fp "===========\n\n")

    (foreach pageEntry (sort crossRef (lambda (a b) (lessp (car a) (car b))))
      pageNum  = car(pageEntry)
      icGroups = cdr(pageEntry)

      (fprintf fp "--- Page %d ---\n" pageNum)

      (foreach icGroup icGroups
        icData = car(icGroup)

        (if icData
          then
            refdes   = cadr(member 'refdes icData)
            cellName = cadr(member 'cellName icData)
            (fprintf fp "  IC: %s  (%s)\n" refdes (or cellName ""))
          else
            (fprintf fp "  UNASSOCIATED\n")
        )

        ; List passives/others in this subgroup
        (foreach passData (cdr icGroup)
          refdes   = cadr(member 'refdes passData)
          cellName = cadr(member 'cellName passData)
          ctype    = cadr(member 'type passData)
          (fprintf fp "    %s  %-12s  [%s]\n"
                   refdes
                   (or cellName "")
                   (symbolToString ctype))
        )

        (fprintf fp "\n")
      )
    )

    ; Unmatched board components
    (when _gpbsUnmatchedBoard
      (fprintf fp "UNMATCHED (in board, not in text file)\n")
      (fprintf fp "--------------------------------------\n")
      (foreach refdes (sort _gpbsUnmatchedBoard 'alphalessp)
        (fprintf fp "  %s\n" refdes)
      )
      (fprintf fp "\n")
    )

    ; Unmatched text references
    (when _gpbsUnmatchedText
      (fprintf fp "UNMATCHED (in text file, not unplaced in board)\n")
      (fprintf fp "-----------------------------------------------\n")
      (foreach refdes (sort _gpbsUnmatchedText 'alphalessp)
        (fprintf fp "  %s\n" refdes)
      )
      (fprintf fp "\n")
    )

    (close fp)
    (printf "group_parts: Report written to %s\n" reportPath)
    reportPath
  )
)

; =============================================================================
; Step 7: Physical placement in off-board staging area
; =============================================================================
(procedure (_gpbsPlaceComponents crossRef)
  (let (design bBox boardRight boardTop stagingX curY
        pageEntry pageNum icGroups icGroup icData passives
        icRefdes sym x y col row
        unitScale gap icSpacing passGrid pageGapY maxCols)

    design = axlDBGetDesign()

    ; -------------------------------------------------------------------------
    ; Determine unit scale (mil vs mm)
    ; -------------------------------------------------------------------------
    (let (units)
      units = axlGetVariable("UNITS")
      (if (equal units "MM")
        then unitScale = 1.0   ; constants already in mils; convert if needed
        else unitScale = 1.0   ; mils — no conversion
      )
      ; If MM mode, convert mil constants to mm (1 mil = 0.0254 mm)
      (when (equal units "MM")
        unitScale = 0.0254
      )
    )

    gap       = times(_gpbsConfig_boardGap      unitScale)
    icSpacing = times(_gpbsConfig_icSpacing     unitScale)
    passGrid  = times(_gpbsConfig_passiveGrid   unitScale)
    pageGapY  = times(_gpbsConfig_pageGapY      unitScale)
    maxCols   = _gpbsConfig_maxColsPerRow

    ; -------------------------------------------------------------------------
    ; Find board extents
    ; -------------------------------------------------------------------------
    boardRight = 0
    boardTop   = 0

    (let (outline extents)
      outline = design->designOutline
      (if outline
        then
          (let (bb)
            bb = outline->bBox
            (when bb
              boardRight = cadr(car(bb))   ; right edge x
              boardTop   = cadr(cadr(bb))  ; top edge y
            )
          )
        else
          ; Fallback
          extents = axlDBGetExtents()
          (when extents
            boardRight = cadr(car(extents))
            boardTop   = cadr(cadr(extents))
          )
      )
    )

    stagingX = plus(boardRight gap)
    curY     = boardTop

    ; -------------------------------------------------------------------------
    ; Begin transaction for single-undo support
    ; -------------------------------------------------------------------------
    axlDBTransactionStart("Place grouped schematic parts")

    ; -------------------------------------------------------------------------
    ; Place each page group
    ; -------------------------------------------------------------------------
    (foreach pageEntry (sort crossRef (lambda (a b) (lessp (car a) (car b))))
      pageNum  = car(pageEntry)
      icGroups = cdr(pageEntry)

      (let (groupStartX groupWidth)
        groupStartX = stagingX
        groupWidth  = 0

        (foreach icGroup icGroups
          icData   = car(icGroup)
          passives = cdr(icGroup)

          ; Place IC (or a placeholder origin for unassociated group)
          x = groupStartX
          y = curY

          (when icData
            icRefdes = cadr(member 'refdes icData)
            ; Only place if still unplaced
            (let (existComp)
              existComp = axlDBGetComp(icRefdes)
              (when (and existComp (null existComp->symbol))
                sym = axlDBCreateSymbol(icRefdes x y nil 0)
                (unless sym
                  (printf "group_parts: WARNING — failed to place %s\n" icRefdes)
                )
              )
            )
          )

          ; Place passives in a grid below (or around) the IC
          col = 0
          row = 1
          (foreach passData passives
            (let (passRefdes existComp px py)
              passRefdes = cadr(member 'refdes passData)
              px = plus(x times(col passGrid))
              py = difference(y times(row passGrid))

              existComp = axlDBGetComp(passRefdes)
              (when (and existComp (null existComp->symbol))
                sym = axlDBCreateSymbol(passRefdes px py nil 0)
                (unless sym
                  (printf "group_parts: WARNING — failed to place %s\n" passRefdes)
                )
              )

              col = col + 1
              (when (ngreaterp col maxCols)
                col = 0
                row = row + 1
              )
            )
          )

          ; Compute width of this IC subgroup
          (let (subgroupCols subgroupRows subW subH)
            subgroupCols = min(length(passives) maxCols)
            subgroupRows = plus(1 (quotient (length passives) (max maxCols 1)))
            subW = plus(times(subgroupCols passGrid) icSpacing)
            subH = times(subgroupRows passGrid)
            groupStartX = plus(groupStartX subW)
            (when (ngreaterp subH groupWidth)
              groupWidth = subH
            )
          )
        )

        ; Advance Y for next page group
        curY = difference(curY (plus groupWidth pageGapY))
      )
    )

    ; -------------------------------------------------------------------------
    ; Commit transaction
    ; -------------------------------------------------------------------------
    axlDBTransactionCommit()

    axlUIStatusMessage("group_parts: Placement complete. Use Ctrl+Z to undo all placements.")
    (printf "group_parts: Placement complete.\n")
    t
  )
)

; =============================================================================
; Utilities
; =============================================================================

; Safe min — returns smaller of two numbers
(procedure (min a b)
  (if (nlessp a b) a b)
)

; Safe max — returns larger of two numbers
(procedure (max a b)
  (if (ngreaterp a b) a b)
)

; =============================================================================
; End of group_parts_by_schematic.il
; =============================================================================
(printf "group_parts_by_schematic.il loaded. Type 'group_parts' to run.\n")
