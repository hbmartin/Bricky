# ADR 0017: A language model may phrase a repair, never decide one

- Status: Accepted behind an off-by-default developer setting; turning it
  on by default is Proposed and waits for the test below
- Date: 2026-10-06

## Context

Repairs are planned deterministically from measurements and authored
placements, and worded from fixed String Catalog templates (ADR 0015). The
templates are correct but stiff, and one template per action and direction
cannot follow what a person just did. iOS 27's on-device Foundation Models
system model can phrase short text with guided generation, runs outside
the app's process (no memory budget), and costs nothing per call.

It also fails in ways that do not throw. A string-mode refusal is ordinary
text, guardrails change outside OS releases, and the model is not pinned:
the same app on a new OS build is a new model. Part names come from LDraw
file headers, which are attacker-controllable text. Phase 1 has not
happened, and this Mac (an M2 Pro) is not the iPhone 17 Pro's model tier,
so nothing measured here describes the phone.

## Decision

**The language layer phrases; geometry and the planner decide.** Behind
`AppConfig.Defaults.languageModelWordingEnabled` ("Reword repairs with the
on-device language model", developer settings, off by default):
- **The facts are fixed first.** `RepairWordingFacts` carries what the
  planner decided: action, part label, count, direction (only when the
  template uses one), studs and turn, plus the template sentence.
- **Trust boundary.** The Instructions are constant and trusted. The facts,
  including the untrusted part label (sanitised and capped), go only in the
  Prompt, as a `@Generable` value.
- **Guided, greedy output.** The model returns the facts' enum fields plus
  one sentence. A string-mode refusal therefore surfaces as a thrown error,
  not as text shown to the user.
- **Validated.** `RepairWordingValidator` requires the enum fields to equal
  the facts and the exact label to appear. The sentence must stay one
  sentence under 160 characters and add nothing: no direction other than
  the facts', no rotation sense, no other number, no colour outside the
  label, none of the forbidden words.
- **Template first.** The template is on screen at once. A validated
  sentence replaces it only if it arrives for the repair still on screen.
  Siri's "next step" and the narrator then read that same line. Every
  failure (unavailable, unsupported locale, refusal, guardrail, timeout,
  rejection) keeps the template.
- **English only**, while the String Catalog is English only.
- **Evidence.** With evidence capture on, every attempt is kept beside its
  template in `wording.ndjson`, with the OS build.

**Turning it on by default is Proposed.** It needs a blinded preference
test on device pairs from `wording.ndjson`: the owner rates template
against model sentence without knowing which is which, and the model
sentence must win on an exact sign test (`score_wording_ab.py`). The
Evaluations suite and any model judge (κ > 0.6 against hand ratings first)
are development tools; they do not replace the device test.

## Consequences

- With the setting off, nothing changes: the templates are shown exactly as
  before.
- With it on, the worst case is the template, never a wrong instruction:
  a sentence that says anything the facts do not is rejected.
- Every OS update can change the model, so device pairs and the preference
  test are re-run per OS build before any default flips.
- Adapters are not used (they are a hard compile error on 27), and no tool
  calling is involved: the facts are fixed before the call.
