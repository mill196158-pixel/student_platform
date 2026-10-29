# Visual regression environment

Accepted environment: Flutter **3.47.2**, framework `d3b14c8769`, engine
`a804b26164`, Dart 3.13.2; Windows runner, Android theme platform,
DPR 1, text scale 1. Tests use Flutter's deterministic test font (Ahem),
not production typography. Real font readability still needs device QA.

Run `flutter test test/visual_parity_golden_test.dart` from this package.
Do not increase tolerance to hide differences. Review changes before using
`--update-goldens`; retain `*_before` comparison images.

## 2026-10-29 investigation

All 16 current renderings were compared with an isolated `git archive fa423a5`
of this package, executed with the same SDK. All 16 RGBA outputs were identical.
The historical checkout also failed the same 16 comparisons. The four other
tests check existence of before-images, not visual equality.

Jobs baselines predated the compact layout in fa423a5 (buttons changed from
stacked to horizontal). Other differences include test-font rendering and Home
vertical layout. Exact old-SDK attribution is unproven; historical reproduction
establishes that these fixtures have no recent source regression.

After inspection of all 16 current images at both sizes, current references were
deliberately accepted for this environment. The test now pins platform, scale,
and DPR explicitly; Jobs additionally asserts horizontal non-overlapping actions.
No production widget was changed and no tolerance was introduced.
The before-images are unchanged. Full package rerun: **167 PASS**.
