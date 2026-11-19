You are the independent reviewer on a macOS real-time video project. Earlier you wrote your own plan (`reviews/01-astra-independent-plan.md`). The lead engineer has now written `PLAN.md`. Review it. You are not being asked whether it is good: you are being asked to find what is wrong, unsupported or missing before any app code is written.

First read `skills/plan-review/SKILL.md` and follow its review output format exactly. Then read, in this order:
1. `PLAN.md` (the thing under review)
2. `RESULTS.md` (the measured numbers)
3. `reviews/phase1-evidence/` (nine raw reports from the evidence agents; the lead's summary may have dropped or bent something)
4. `reviews/01-astra-independent-plan.md` (your own plan)
5. The three implementer skill files: `skills/vt-interpolation/SKILL.md`, `skills/capture-cadence/SKILL.md`, `skills/metal-present/SKILL.md`
6. Raw probe output under `probes/out/` and the SDK headers named in the skill file, whenever a claim needs checking.

## Check these, with your own arithmetic and your own reading of the raw files
1. **Section 3 latency budget.** Recompute every row. Is D = 33.33 ms at 120 Hz right, and is the stated margin right given the measured interpolation times? Does the 59.94 Hz display mode change D or the margin? Is anything double-counted or left out between "capture-only" and "frame generation" (for example the display link's lead time, which applies to both)?
2. **Section 5.2 pacer.** Does a fixed slot step with a dead band actually produce the slip rates claimed for 59.94 Hz input on a 120.000 Hz display and on a 59.94 Hz display? Can it oscillate? What does it do in the first second, and after a cadence break? Compare with the ceiling rule in your own plan and say which is better and why.
3. **Section 5.1 cadence.** Is there a case where a frame is delayed by more than one capture period, or where a wrong midpoint is shown and cannot be cancelled? Is "8 consecutive new frames → native60" safe against a fast pan in a game that really is 30 fps?
4. **Section 6 interfaces.** Can the tasks in section 7 be built in parallel against these types without a hidden dependency? Name any type that will have to change, and any ownership rule in the section 5 table that the interfaces make impossible to follow.
5. **Section 7 phases.** Is each task bounded and testable from its "done when" column alone? Which "done when" could be met without the work being right?
6. **Disagreements with your own plan.** List each point where PLAN.md differs from yours. For each, say who is right given the measurements that now exist.
7. **Evidence the plan misuses.** Any number in PLAN.md or RESULTS.md that does not match the raw file it cites, or is presented more confidently than the source allows.
8. **What is missing.** Anything a first live session with the Elgato will hit that the plan does not cover.

## Constraints
- Read-only. Do not create or edit files. Do not run builds or the probes.
- No installs, no paid APIs, no OBS changes.
- Label every number measured or estimate. Name the file and line, or the header and symbol, for every claim.

## Output
Findings in the skill file's review format, most severe first. Then a section "Changes I would make to PLAN.md" as a numbered list of concrete edits (section, old text in a few words, new text). Then "Not checked".
