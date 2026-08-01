# Cross-Viewer Form Compatibility Verification

**Issue:** T-126 (pdf-mh2w)  
**Parent Epic:** Phase 7 (pdf-ocb)  
**Date:** 2026-08-01  
**Fixture:** `test/fixtures/pdfs/seven_type_form.pdf`

## Overview

This document records manual verification steps for PDF forms authored in the application across multiple PDF viewers: Adobe Acrobat and Chrome's built-in PDFium viewer. The automated test suite (`test/quire/pdf_forms_compat_test.exs`) validates the engine-level round-trip behavior; this document provides the human-in-the-loop verification checklist.

## Automated Coverage

The test suite validates:

- ✅ All seven field types (text, checkbox, radio, combo box, list box, push button, signature) are authored correctly
- ✅ Tab order matches authored field order in `/AcroForm /Fields` array
- ✅ `FormData.write` persists values across save/reopen cycles
- ✅ Gate 7: signature on rotated/cropped page survives save/reload
- ✅ Field names and types are preserved through round-trip

## Manual Verification Steps

### Test Fixture

Use the committed fixture: `test/fixtures/pdfs/seven_type_form.pdf`

This fixture contains one page with seven form fields in authored order:

| # | Field Name       | Type       | Description              |
|---|------------------|------------|--------------------------|
| 1 | first_name       | Text       | Single-line text field   |
| 2 | agree_checkbox   | Checkbox   | Boolean checkbox         |
| 3 | option_radio     | Radio      | Radio button group       |
| 4 | country_combo    | Combo Box  | Dropdown selection       |
| 5 | fruit_list       | List Box   | Multi-select list        |
| 6 | submit_btn       | Button     | Push button              |
| 7 | sign_field       | Signature  | Digital signature field  |

### Adobe Acrobat (DC Pro / Reader)

#### Opening and Rendering
- [ ] Open `test/fixtures/pdfs/seven_type_form.pdf` in Acrobat
- [ ] Verify all seven fields render visibly on the page
- [ ] Verify field rectangles are outlined or highlighted (Acrobat's form field overlay)

#### Tab Order
- [ ] Click in the document to activate form navigation
- [ ] Press Tab repeatedly
- [ ] **Expected:** Focus moves through fields in order: first_name → agree_checkbox → option_radio → country_combo → fruit_list → submit_btn → sign_field
- [ ] **Record:** Actual tab order observed: _______________
- [ ] **Pass/Fail:** Tab order matches authored order? [ ] YES  [ ] NO

#### Field Interaction
- [ ] Click "first_name" field, type "Ada Lovelace"
- [ ] Click "agree_checkbox", toggle to checked
- [ ] Click "option_radio", select "ChoiceA"
- [ ] Click "country_combo", select "CA" from dropdown
- [ ] Click "fruit_list", select "Cherry"
- [ ] Click "submit_btn", verify button click is registered (may show no action without JS)
- [ ] Click "sign_field", verify signature dialog appears (Acrobat's signature workflow)

#### Save and Reopen
- [ ] Save the filled PDF to a new file: `seven_type_form_filled_acrobat.pdf`
- [ ] Close and reopen the saved file
- [ ] **Verify:** All field values persist:
  - [ ] first_name = "Ada Lovelace"
  - [ ] agree_checkbox = checked
  - [ ] option_radio = "ChoiceA"
  - [ ] country_combo = "CA"
  - [ ] fruit_list = "Cherry"
- [ ] **Pass/Fail:** Values persist after save/reopen? [ ] YES  [ ] NO

#### Calculated Fields (if applicable)
- [ ] **Note:** The current fixture does not include calculated fields (no `/AA` actions or `/Calc` entries)
- [ ] **Future work:** Create a separate fixture with calculated fields to test Acrobat's JavaScript engine
- [ ] **Manual step:** If calculated fields are added, verify they recompute after value changes

### Chrome Built-in PDF Viewer (PDFium)

#### Opening and Rendering
- [ ] Open `test/fixtures/pdfs/seven_type_form.pdf` in Chrome (drag-and-drop or `chrome://file` URL)
- [ ] Verify all seven fields render visibly on the page
- [ ] Verify field rectangles are outlined or highlighted

#### Tab Order
- [ ] Click in the document to activate form navigation
- [ ] Press Tab repeatedly
- [ ] **Expected:** Focus moves through fields in order: first_name → agree_checkbox → option_radio → country_combo → fruit_list → submit_btn → sign_field
- [ ] **Record:** Actual tab order observed: _______________
- [ ] **Pass/Fail:** Tab order matches authored order? [ ] YES  [ ] NO

#### Field Interaction
- [ ] Click "first_name" field, type "Ada Lovelace"
- [ ] Click "agree_checkbox", toggle to checked
- [ ] Click "option_radio", select "ChoiceA"
- [ ] Click "country_combo", select "CA" from dropdown
- [ ] Click "fruit_list", select "Cherry"
- [ ] Click "submit_btn", verify button click is registered (may show no action without JS)
- [ ] Click "sign_field", verify signature dialog appears (Chrome's signature workflow)

#### Save and Reopen
- [ ] Use Chrome's "Save" or "Download" button to save the filled PDF: `seven_type_form_filled_chrome.pdf`
- [ ] Close and reopen the saved file in Chrome
- [ ] **Verify:** All field values persist:
  - [ ] first_name = "Ada Lovelace"
  - [ ] agree_checkbox = checked
  - [ ] option_radio = "ChoiceA"
  - [ ] country_combo = "CA"
  - [ ] fruit_list = "Cherry"
- [ ] **Pass/Fail:** Values persist after save/reopen? [ ] YES  [ ] NO

#### Calculated Fields (if applicable)
- [ ] **Note:** Chrome's PDFium has limited JavaScript support compared to Acrobat
- [ ] **Expected:** Calculated fields may NOT recompute in Chrome (known limitation)
- [ ] **Future work:** Test calculated fields separately; document Chrome's limitations

### Gate 7 Fixture (Rotated/Cropped Page with Signature)

**Fixture:** Generated by `SevenFieldForm.build_rotated_cropped_sig()` (not committed as fixture; use test to generate)

#### Adobe Acrobat
- [ ] Open the rotated/cropped signature PDF in Acrobat
- [ ] Verify the page renders with correct rotation (90° landscape)
- [ ] Verify CropBox is applied (page appears cropped)
- [ ] Verify signature field is visible and clickable
- [ ] Click signature field, verify signature dialog appears
- [ ] Save and reopen, verify signature field still present
- [ ] **Pass/Fail:** Signature field survives save/reload? [ ] YES  [ ] NO

#### Chrome Built-in Viewer
- [ ] Open the rotated/cropped signature PDF in Chrome
- [ ] Verify the page renders with correct rotation (90° landscape)
- [ ] Verify CropBox is applied (page appears cropped)
- [ ] Verify signature field is visible and clickable
- [ ] Click signature field, verify signature dialog appears
- [ ] Save and reopen, verify signature field still present
- [ ] **Pass/Fail:** Signature field survives save/reload? [ ] YES  [ ] NO

## Known Limitations

### Chrome PDFium
- **Limited JavaScript support:** Calculated fields using `/AA` (additional actions) or `/Calc` may not recompute
- **Signature workflow:** Chrome's signature implementation differs from Acrobat; may require manual verification
- **Form flattening:** Chrome's save behavior may differ from Acrobat's; test both

### Adobe Acrobat
- **JavaScript security:** Acrobat may prompt for JavaScript execution; ensure "Enable JavaScript" is selected
- **Signature certificates:** Acrobat requires a digital certificate for signature fields; manual setup required

## Test Results Template

Use this template to record manual verification results:

```
Viewer: Adobe Acrobat DC Pro v2024.x / Chrome vXXX
Date: YYYY-MM-DD
Tester: [name]

Tab Order Test:
  Expected: first_name → agree_checkbox → option_radio → country_combo → fruit_list → submit_btn → sign_field
  Observed: [record actual order]
  Result: [PASS / FAIL]

Field Interaction Test:
  All fields clickable and editable: [PASS / FAIL]

Save/Reopen Test:
  Values persist after save/reopen: [PASS / FAIL]

Signature Field Test (Gate 7):
  Signature field survives save/reload: [PASS / FAIL]

Notes:
  [any observations, bugs, or deviations]
```

## Regression Testing

When modifying form authoring logic:
1. Run automated test suite: `mix test test/quire/pdf_forms_compat_test.exs`
2. Regenerate fixture if needed: `SevenFieldForm.build()` → save to `test/fixtures/pdfs/seven_type_form.pdf`
3. Perform manual verification in both viewers (or at minimum, one viewer + spot-check the other)

## Related Issues

- **T-121:** Forms palette and field authoring UI
- **T-125:** Auto-create fields from scanned forms
- **Gate 7:** Authored forms work in Acrobat + Chrome; signatures survive (pdf-ge7h)

## References

- plan3.md §9.8 (Forms acceptance criteria)
- plan3.md §13 (Exercise acceptance criteria against the corpus)
- PDF 1.7 specification, §12.7 (Interactive Forms)
- ISO 32000-1:2008 (AcroForm structure)
