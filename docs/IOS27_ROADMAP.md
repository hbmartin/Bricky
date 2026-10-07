# Using Apple's iOS 27 on-device AI for mid-flight build and repair in Bricky

Status: accepted as the program plan on 2026-09-25.
- Phase 0 (no device needed) shipped in PR #10; its review findings were
  fixed in PR #11.
- Phase 2's device-free work merged in PR #12, one commit per item:
  - evidence windows;
  - segmented geometry and range draws;
  - the placement index;
  - the build diff in shadow;
  - in-step repair with camera-relative wording (ADR 0015);
  - the synthetic recovery suite and the tie-break, off;
  - suggested placement, behind a flag;
  - the hands-free advance policy, voice, Siri and opt-in Spotlight
    (ADR 0016);
  - the cross-step planner, flag off and Proposed.
- Phase 3's device-free work is on `feat/ios27-phase3` (PR #13), one commit
  per item:
  - one check-verdict schema, and the photo check's pose and delta box in
    evidence;
  - the colour tag pass, the colour table and in-scene calibration;
  - the non-learned colour term in shadow, with block-only authority behind
    a developer setting (ADR 0008 amendment, Proposed);
  - repair wording by the on-device language model, validated against the
    plan, behind a setting (ADR 0017), with an Evaluations suite and a
    blinded preference test;
  - the step-check advisor seam and the Foundation Models shadow check
    (ADR 0018, Proposed).
  - Not done:
    - Private Cloud Compute: the owner is not eligible (ADR 0011 note).
    - The Core AI colour CNN (M3.6): only if the non-learned term fails
      on real data.
    - The embedding pre-filter: needs ≥150 labelled cases.
- Phase 4's device-free work is on `feat/ios27-phase4` (PR #14), one commit
  per item. The Qwen3-VL-2B fast tier is deferred (owner, 2026-10-06).
  - **Stud keypoints, measure first** (ADR 0020, Proposed):
    - the lattice runner-up, contests and tallies reach evidence;
    - a synthetic lattice suite;
    - device lattice rows and the `STUD_KEYPOINTS_ENTRY` readout;
    - stud identity through the flatten, stud-ID renders, geometry-only
      labels, and pseudo-labels for photo captures;
    - a Core AI detector seam that nothing calls.
  - **LoRA** (ADR 0019, Proposed):
    - physical-build labels;
    - an `adapter` variant axis, with `compare_arms.py` refusing mixed
      weights and unrestricted adapter arms;
    - runtime adapter loading;
    - a stdlib exporter;
    - a `Tools/Training` uv project;
    - an end-to-end smoke with Python/Swift parity.
  - **Not done:**
    - any trained model or adapter, because the entry criteria are unmet;
    - the embedding pre-filter, which needs at least 150 labelled cases;
    - the 2B tier.
- Everything gated on device data stays off or in shadow until Phase 1
  measures it, using the add-on checklist in
  [NEXT_STEPS_AND_FOLLOWUP.md](NEXT_STEPS_AND_FOLLOWUP.md) §1a.
- Still waiting:
  - M2.1 and M2.5, for the Phase 1 step-5 verifier trace;
  - every authority flip;
  - background-download QA on a device;
  - the `thermal_deferred` cloud offer, which needs an ADR 0011 amendment
    first.

Owner decisions (answers to §7):
1. Floor: iPhone 17 Pro / Pro Max only (ADR 0012 amendment).
2. Repair scope: in-step fixes first. The build diff observes earlier-step
   problems from day one, but cross-step "remove and re-add" plans wait for
   a new ADR that amends the CONTEXT.md / ADR 0001 / ADR 0004 boundary.
   A suggested ghost placement is acceptable only when the user confirms it.
3. VLM: decided after the Foundation Models shadow test, with data from
   the phone only (owner, 2026-10-06; ADR 0018, Proposed).
4. Release gates are judged on one-sided 95% confidence bounds. The
   authored-model diversity floor is still to be decided.

Corrections from a code audit on 2026-09-25:
- §2a item 2 overstates the cache defect. The bridge drops forced spans
  shorter than one token, so the letters themselves do reach the KV cache.
  What is lost is the sampled token before multi-token forced spans (key
  names, enum tails), so the context is still corrupted.
- §2a item 1 understates the silence: xgrammar never emits the
  `uniqueItems` warning at all.
- Found in the audit, not in the original:
  - `capture_angle` is always `"left,center,right"`, so the release
    validator's variety check can never pass.
  - Geometric recovery is gated on VLM admission.
  - The verifier runs inside the ICP tracking loop.
  - The project targets iPad as well.


Sources. Seven parallel agents read the installed Apple skills: foundation-models, core-ai, mlx, metal-tensorops, ai-evaluations, on-device-ai, ai-migration, ai-shipping, speech and app-intents. I read Bricky's code and ADRs myself. Claims taken from the skills keep the skills' own evidence markers: ✅ verified, 🟡 reconstructed, 🟠 community or suggestive, 🔴 gap, ⚠️ silent failure. Findings about Bricky's code say either "verified in code" (I read the lines myself) or "read, not run" (it needs a runtime check).

---

Summary

1. With LiDAR required, the iPhone 17 floor means only the iPhone 17 Pro and 17 Pro Max. The iPhone 17 and iPhone Air have no LiDAR. That leaves one hardware tier: A19 Pro, 12 GB of RAM, and Apple's higher on-device model tier. This makes testing much simpler, but it does not remove the memory or heat limits (§1).
2. The best near-term improvements need no new framework. Several defects in the VLM recovery path, the scorer and the model download are quietly degrading mid-flight recovery today (§2). Until they're fixed, any A/B test of new Apple technology measures these bugs instead.
3. The real product gap for "repair" is structural. Bricky matches the build against whole authored steps. Real mid-build states look like "step 12 minus one part", "wrong colour" or "rotated 90°". The core feature to add is a placement-level build diff that produces a deterministic repair plan (§3). The new Apple technology then fits in at specific points.
4. Which technology for which job:

┌─────────────────────────────────────────────────┬───────────────────────────────────┬─────────────────────────────────────────────────┐
│                       Job                       │            Technology             │                  What changes                   │
├─────────────────────────────────────────────────┼───────────────────────────────────┼─────────────────────────────────────────────────┤
│ Geometry (registration, verification)           │ Stays CPU/simd plus the one       │ Batch renders; no TensorOps                     │
│                                                 │ render pass                       │                                                 │
├─────────────────────────────────────────────────┼───────────────────────────────────┼─────────────────────────────────────────────────┤
│ New learned perception (colour check, stud      │ Core AI on the Neural Engine      │ Keeps the GPU free for RealityKit and MLX       │
│ keypoints, rendered-vs-real embeddings)         │                                   │                                                 │
├─────────────────────────────────────────────────┼───────────────────────────────────┼─────────────────────────────────────────────────┤
│                                                 │                                   │ Change how it's called: score by                │
│ VLM fallback                                    │ Stays on MLX with Qwen3-VL        │ log-probability, budget image tokens, bump the  │
│                                                 │                                   │ pin                                             │
├─────────────────────────────────────────────────┼───────────────────────────────────┼─────────────────────────────────────────────────┤
│ Repair wording, answers                         │ Foundation Models system model    │ Given deterministic facts; never the source of  │
│                                                 │ with @Generable                   │ truth                                           │
├─────────────────────────────────────────────────┼───────────────────────────────────┼─────────────────────────────────────────────────┤
│ Hands-free                                      │ SpeechAnalyzer +                  │ Voice commands, spoken steps, "resume my build" │
│                                                 │ AVSpeechSynthesizer; App Intents  │                                                 │
├─────────────────────────────────────────────────┼───────────────────────────────────┼─────────────────────────────────────────────────┤
│ Evaluation                                      │ Python scorer stays the gate      │ Evaluations framework only for the language     │
│                                                 │ authority                         │ layer                                           │
└─────────────────────────────────────────────────┴───────────────────────────────────┴─────────────────────────────────────────────────┘

5. Don't:
   - port Qwen3-VL-4B to Core AI;
   - write TensorOps or flash-attention kernels;
   - enable the MLXFoundationModels trait at the current pin;
   - plan on Foundation Models adapters: they are a hard compile error on a 27.0 target ✅;
   - ask any model for coordinates or offsets.

---

1. What "iOS 27 + iPhone 17" means in practice

┌─────────────────────────┬───────┬────────┬────────────────────────┬────────────────────┐
│          Model          │ LiDAR │ RAM 🟠 │    Apple model tier    │ Works with Bricky? │
├─────────────────────────┼───────┼────────┼────────────────────────┼────────────────────┤
│ 17 Pro (iPhone18,1)     │ Yes   │ 12 GB  │ AFM 3 Core Advanced ✅ │ Yes                │
├─────────────────────────┼───────┼────────┼────────────────────────┼────────────────────┤
│ 17 Pro Max (iPhone18,2) │ Yes   │ 12 GB  │ Core Advanced ✅       │ Yes                │
├─────────────────────────┼───────┼────────┼────────────────────────┼────────────────────┤
│ Air (iPhone18,4)        │ No    │ 12 GB  │ Core Advanced ✅       │ No                 │
├─────────────────────────┼───────┼────────┼────────────────────────┼────────────────────┤
│ 17 (iPhone18,3)         │ No    │ 8 GB   │ AFM 3 Core ✅          │ No                 │
├─────────────────────────┼───────┼────────┼────────────────────────┼────────────────────┤
│ 17e                     │ No    │ 8 GB   │ AFM 3 Core             │ No                 │
└─────────────────────────┴───────┴────────┴────────────────────────┴────────────────────┘

What that buys you, and what it doesn't:

- One device class. One chip, one RAM size, one Core AI architecture code (h18p for the 17 Pro 🟠; the Pro Max code is unverified 🔴), and a guaranteed Core Advanced tier when Apple Intelligence is on. No API tells you the tier 🔴.
- 12 GB is not much headroom.
  - A 17 Pro on an iOS 27 beta showed only about 6.1–6.4 GB of os_proc_available_memory() while idle, before any AR 🟠.
  - Bricky's 5.5 GB admission floor would leave roughly 0.6–0.9 GB for ARKit, the scene mesh, ICP and RealityKit.
  - Apple's iOS guidance is to keep models under 2 GB ✅; Qwen3-VL-4B is 3.09 GB.
  - Whether the VLM is admitted with AR running is unmeasured 🔴. This is the first device measurement to take.
- Heat is the regime that matters.
  - After about 10 minutes of sustained load, MLX on the GPU kept about 38% of its burst speed, versus about 67% for the Neural Engine 🟠.
  - thermalState can read "nominal" while the device is throttling ⚠️.
  - A user 30 minutes into a build, with AR rendering at 60 fps, is exactly this case. Latency gates measured on a cold device overstate what users will see.
- The A19's GPU neural accelerators speed up prefill, not decode ✅ (Apple's M5/A19 tech talk). Bricky's VLM calls are dominated by prefill: about 1,024 image tokens in, 48–192 tokens out.
  - MLX has kernels for these accelerators (called "NAX"). Whether they switch on for A19 Pro at Bricky's pin is unconfirmed 🔴.
  - The vendored MLX core (0.31.1, March 2026) predates the NAX "wrong numbers" fixes merged June–August ⚠️.
- Decision for you. Requiring the 17 Pro drops owners of iPhone 12–16 Pro, and their geometric features work fine without the VLM. The alternative is to keep LiDAR as the app floor and make "measured 12 GB class" the gate for VLM features only.

---

2. Fix these first

2a. The VLM recovery vote is probably corrupted

1. The ranking grammar doesn't prevent duplicate letters. Verified in code.
   - The vendored xgrammar lists uniqueItems as unsupported (json_schema_converter.cc:2042), and that warning is never shown.
   - So ["B","B","B"] is legal output. The finalist vote in HierarchicalRecoveryEstimator and the harness's benchmarkRow both count duplicates.
2. The model doesn't see its own letters. Read, not run.
   - In the pinned GuidedGenerationLoop.run, when the grammar forces tokens after a sampled token, only the forced tokens are fed back into the model (lines 360–372). The sampled token is fed back only on the other branch (line 392).
   - In the rank JSON, a forced " follows almost every sampled letter. So letters 2 through n are chosen without the model's cache containing the letters it already picked. The first letter is fine; later positions are close to noise.
   - To confirm: assert that the cache offset equals prompt length plus emitted tokens.
3. The finalist pass always puts the likely answer in slot B. Verified in code. Finalists are [leader−1, leader, leader+1], sorted (HierarchicalRecoveryEstimator.swift:70). Whenever the narrowing pass was right, the true step is slot B, so a model that just favours the middle tile scores perfectly.
4. The token-budget reasoning is stale. Verified in code.
   - The closing bias only runs if a closingBias is passed in, and Bricky never passes one. So the reasoning behind the 96→192 rankMaxTokens change, and the "check token budget" A/B row in NEXT_STEPS, don't apply.
   - prematureEOS is declared but never thrown, so that termination can never be recorded.
5. The step check compares against the wrong viewpoint. Verified in code.
   - StepCheckView renders the target with image(forStepIndex:), which uses a fixed 38° guide camera.
   - Recovery, by contrast, renders from the pose where the photo was taken.
   - So the VLM judges a phone photo from an arbitrary angle against a render from a fixed angle.

The fix direction, which sets up §4.2: trust only the first slot, read probabilities instead of generated JSON, rotate the slot order across views, and render at the registered pose.

2b. Gates that pass while measuring nothing (all verified in code)

- False-complete gate. score_results.py:308 reports a false-complete rate of 0.0 when there are no negatives.
- Latency gates. At :277-279, (median or 0) > limit means a corpus with no geometric rows never checks the 8 s gate.
- Replay rows pass as device rows. validate_release_corpus never rejects device_model: "replay:…" rows. The harness copies physical_case and legal_use_confirmed from the staged declaration, so Mac replays can pass release validation.
- Dropped rows improve the score. SyntheticRGBDMain.swift:161 drops expected-complete rows that aren't "strong". That is deliberate, but a verifier change that downgrades detectability then deletes its own recall failures and the score goes up. Guard row counts in baseline.json.
- Sample sizes are too small to prove the gates. This is the evaluation agent's binomial arithmetic, not a skill claim.
  - Proving false-complete ≤2% with zero failures observed takes at least 149 negatives. The real-tower "0.0" rests on at most 12.
  - 40/40 top-3 only demonstrates about 0.93 at 95% confidence.
  - NEXT_STEPS says ≥150 cases from ≥10 models, but the scorer enforces ≥40 from ≥6. Pick one.
- Missing mistake types. The only synthetic mistake is an 8 mm shift along X. A colour swap is invisible to depth, so today it would be called complete: an unmeasured false-complete class.

2c. Shipping hygiene (all verified in code)

- The 3.09 GB model goes into backups. applicationSupportRoot() sets isExcludedFromBackup = false (InstructionModelImporter.swift:246), and the model lives under that root.
- The 3 GB download dies in the background. It runs on a foreground .ephemeral URLSession (VerifiedAssetDownloader.swift:79).
- The depth renderer is expensive per call. ExpectedDepthRenderer compiles its shader from source for every instance, allocates buffers and textures on every render, and blocks on waitUntilCompleted. The verifier runs 3 renders per frame, plus 4 lattice renders every third frame, on the same GPU as RealityKit and MLX.

2d. Plumbing any mid-flight feature needs

- Step progress lives in three places: GuideView, ARGuideView and StepCheckView, each with its own @State. A voice or Siri command that changes the step would save it without updating the screen. Put progress in one BuildSessionController.
- Parts show as raw file names (3001.dat, GuideView.swift:148). Any spoken or written instruction needs part descriptions from each file's header line.
- "Open in Bricky" probably does nothing. Info.plist declares LDraw document types, but nothing handles onOpenURL. Needs checking on a device.

---

3. The core gap: from "which step?" to "what's different?"

Today recovery answers "which authored step matches best?", and verification answers "is this step's addition complete, incomplete, or one stud off?". Common mid-build states that neither can express:

- a part skipped three steps ago, then more steps built on top;
- the right shape in the wrong colour, which depth can't see;
- an asymmetric part rotated 90° or 180°. Verification only tests translations; lattice rotations exist only in registration.
- a plate one layer off. At 3.2 mm that is below reliable LiDAR resolution.
- a half-finished step, or a submodel built but not yet attached.

Proposal: a placement-level build diff.

- How it works. For each authored placement, estimate its state: present, absent, displaced (by what offset), colour mismatch, or not observable.
  - The existing expected-depth pass would render a placement-ID buffer alongside depth, so evidence can be attributed per part instead of per step.
  - Recovery then finds the latest step whose placements are present, apart from a small set of explained exceptions. Today's verifier becomes one special case.
- Output: a deterministic repair plan. An ordered list of actions derived from authored order and placements only. For example: "remove the 2 parts added in steps 11–12; add the missing blue 1×2 plate from step 9; re-add them". Each action carries its confidence and whether it was observable.
- Why this fits Bricky. The actions only ever refer to authored placements, so they stay grounded in authored steps (ADR 0001).
- It crosses a stated product boundary. CONTEXT.md excludes "teardown diagnosis", and ADR 0004 excluded "missing-part diagnosis and teardown repair". This needs your decision (§7).
- Recovery also has setup friction. It needs a manual ghost placement first, which is awkward for a lost user. A suggested placement that the user confirms might help. CONTRIBUTING forbids claiming automatic registration, so that is also your call.

Where the Apple technology plugs in:
- Core AI supplies colour and presence evidence where depth is blind (§4.1).
- Batched rendering makes per-placement scoring cheap (§4.3).
- Foundation Models phrases the plan (§4.4).
- Speech speaks it and takes commands (§4.5).

---

4. Ideas by technology

4.1 Core AI: small purpose-built models on the Neural Engine

Why Core AI. On iPhone the Neural Engine's lasting advantage isn't speed. At matched bytes on a 17 Pro it measured 83 tok/s against MLX's 73 🟠, close to parity. What matters is that it doesn't compete with RealityKit, the depth renderer and MLX for the GPU, and that it throttles less.

1. RGB "part present / colour matches" check. This is the support term ADR 0008 still owes; marginal-detectability steps currently have complete-recall 0.0.
   - Model. A small fp16 CNN. Inputs: the observed RGB crop of the expected mask, plus expected-colour renders at steps k and k−1.
   - API.
     - AIModel(contentsOf:options:) preferring the Neural Engine, loadFunction(named:), run(inputs:) ✅.
     - Allocate inputs with NDArrayDescriptor.preferredStrides; otherwise a layout copy runs on every inference ⚠️.
     - Author to the Neural Engine rules: static shapes, fp16 only. A stray Python float literal or F.silu moves ops off the Neural Engine without any error ⚠️.
     - Confirm residency on the Instruments Core AI Neural Engine track ✅.
   - Prerequisites. A colour plane on RegistrationFrameInput, an expected-colour render pass, and RGB captured in evidence bundles.
   - Order of work. Build a non-learned colour-agreement baseline first. Train only if it fails, and only on real crops: ADR 0008 forbids an invented colour sensor model.
   - Rule. The term may block or corroborate a depth verdict, never push it toward complete on its own. This check also catches the colour-swap case.
2. Rendered-vs-real embedding pre-filter.
   - Encode the capture and the N candidate renders, then compare them by cosine similarity. Do that maths in Swift/vDSP, not inside the model graph: optimize() miscompiles distance/Gram forms (open issue ⚠️).
   - It narrows 8 candidates to 3 before any VLM call, which could cut 5–8 VLM calls per recovery to 1–2.
   - Evidence bundles already contain matching tiles, captures and labels for contrastive fine-tuning.
3. Stud keypoint heatmap. (Entry measurement, labels and seam: ADR 0020, Proposed.) It would resolve the 8 mm stud-grid aliasing and sharpen "misplaced" verdicts. LDraw stud primitives give free synthetic labels, but expect a gap between synthetic and real images. ICP itself stays CPU/simd.

Core AI operational traps:
- coreai-build exits 0 for any architecture ⚠️. Ahead-of-time compile for h18p specifically.
- CI needs the Metal Toolchain component ✅.
- Core AI is absent from the Simulator SDK ✅. Bricky's CI runs on the Simulator, so Core AI code would silently compile out there.
- The specialization cache is purged on every OS update ✅. Prepare models when the user opts in, never mid-build.
- Every concurrent run allocates its own scratch memory with no cap ⚠️. Limit it to 1–2 in flight.

Blocked on:
- labelled physical data (the corpus is about zero rows);
- whether ARKit contends for the Neural Engine 🔴;
- zero-copy CVPixelBuffer input, which is undemonstrated 🔴.

Separately, and not from the skills (verify first): Vision's hand-pose request could mask the user's hands out of the depth evidence. Hands in view are a very common mid-build occlusion.

4.2 MLX: keep Qwen3-VL, change how it's used

1. Score by probability instead of generating JSON.
   - Stop at the first ranking slot and read the probabilities of the legal A–H tokens. Read P(insufficient) at the status field.
   - Take certainty from the gap between the top two, and set the step check's P(complete) threshold to meet the ≤2% false-complete gate.
   - This avoids both the duplicate-letter and cache defects from §2a.
   - It also removes 30–60 forced single-token forward passes per call; each forced token costs a full pass ✅.
   - Rotate the tile order across the three views to cancel any slot bias.
   - Risk: whether each letter is a single token right after " 🔴.
2. Measure before changing anything.
   - Fork the guided loop into RecoveryMLX; it only needs public API.
   - Record prefill and decode time separately, prompt and image token counts, and per-slot log-probabilities.
   - Assert the cache offset (§2a) and that input.image != nil after prepare; the pinned source warns of a silent fallback to text-only.
   - Separately, harness replay only sums finalist-pass latencies. Fix that.
3. Spend image tokens deliberately.
   - A 1024² board costs about 1,024 language-model tokens, one per 32×32 pixel block.
   - Each candidate tile gets only about 62 tokens, probably too few to tell adjacent steps apart by one plate.
   - Use finalist boards with at most 4 larger tiles; 5 slots are empty today. Use shorter boards for the broad passes, and highlight the delta on each tile.
   - UserInput.Processing(resize:minPixels:maxPixels:) works per call ✅.
4. Bump the pin, as an A/B test. The current d2424294 lacks:
   - #455, per-image vision attention (peak memory 28.7→12.6 GB on one image, measured on a Mac 🟠);
   - #439, the .updateUsage launch-abort fix;
   - #475, image-position state across turns.
   It probably pulls in mlx-swift ≥0.31.5, whose build plugin needs -skipPackagePluginValidation. Treat the bump as a model change: take device benchmark rows and compare replays against replays.
5. Check the A19 Pro fast path. Record a Metal System Trace of one production recovery call on a 17 Pro and read the neural-accelerator utilisation. This is the only TensorOps-adjacent work worth doing, and it is exactly the profiling evidence ADR 0006 asks for.
6. Memory governance.
   - Run WiredMemoryUtils.tune(userInput:…) on the production board with AR, scene mesh and ICP active ✅.
   - Compute the budget as os_proc_available_memory() + phys_footprint 🟠.
   - Don't use Memory.snapshot() for admission; it reports MLX's allocator, not what jetsam measures ✅.
   - Add hysteresis, cancel queued passes when memory is critical, and confirm an unload freed memory by re-sampling about 500 ms later.
7. Try Qwen3-VL-2B as a fast tier. Same family, processor and grammar, with about half the weights, which is nearer Apple's under-2 GB guidance. A/B it on MLX before considering anything else.
8. Training, later. (Tooling and the variant seam: ADR 0019, Proposed.)
   - Use mlx-vlm LoRA only. mlx_lm's save_config deletes vision_config ✅.
   - Swift and Python LoRA scale defaults differ (10 vs 20) ⚠️.
   - Split train and test by authored model.
   - With idea 1 in place, the natural training target is the first-slot letter.
9. Keep traits: []. At the pin, MLXFoundationModels still calls .updateUsage, the launch-abort pattern ⚠️. It also forces a 256 MB process-wide buffer cache and reports truncation as metadata instead of throwing.

4.3 Metal TensorOps: no kernels

- TensorOps doesn't fit Bricky's work:
  - Most of TensorOps is 26.x ✅.
  - The 27-only FP4/FP8 block-32 scale formats don't match MLX's affine 4-bit, so adopting them means re-quantizing the model.
  - ICP's normal equations are 4×4 sums over about 12k points and bound by memory gathers, and Bricky accumulates in simd_double4x4 (Metal has no fp64).
  - MLX already dispatches accelerated attention.
  - The skill's own flash-attention kernel is 🟡, never compiled.
  - Its known traps give plausible wrong numbers: cooperative tensors aren't zero-initialised, and one reduce_rows overload computes max(0,row).
- Do this instead:
  - One shared renderer, created once, with persistent textures.
  - Render N hypotheses in one command buffer (lattice alternatives, recovery candidates, per-placement IDs), with asynchronous completion. It is still an ordinary render pipeline, so it needs one sentence in ADR 0006.
  - Parallelise geometric recovery on the CPU with a TaskGroup; DepthICPTracker.solve is a pure function. Add signposts first, because building snapshots and sampling points are the likelier cost.

4.4 Foundation Models: wording, not judgement

Facts:
- Image input: the on-device model takes images, via Attachment in a Prompt ✅.
- Context: 4,096 tokens; read contextSize at runtime rather than hardcoding it ✅.
- Per-image cost: unpublished 🔴, and tokenCount(for:) throws on prompts that contain images 🟡.
- Localisation: it names what's in an image but can't reliably say where; Apple points to Vision for that ✅.
- Memory: it runs outside the app's process, so it costs Bricky no memory budget ✅.
- Adapters: SystemLanguageModel.Adapter is obsoleted in 27.0, a hard compile error ✅.
- Private Cloud Compute requires all three of: App Store Small Business Program membership, fewer than 2M lifetime first-time downloads, and a managed entitlement ✅. Constructing it without the entitlement is a fatalError, not a thrown error ⚠️.
- Trust boundary: Instructions are trusted and Prompt is not. LDraw model names, comments and author lines are attacker-controllable text, and a successful injection doesn't throw ⚠️.

Ideas:
1. Repair wording from the deterministic plan.
   - Pass the facts as a @Generable value in the Prompt, not through tools; Apple says to skip tools when the facts are fixed ✅.
   - Output @Generable enum fields: action, part reference, camera-relative direction, stud count.
   - Validate the output against the plan, and fall back to a template on any mismatch. Templates may turn out to be enough.
   - This fixes today's "Brick looks misplaced by about one stud", which hides the direction the user needs ("one stud toward you").
2. Shadow-test the system model as an advisory checker. Replay existing evidence bundles through it in bricky-harness on a macOS 27 M3+ Mac, which is also Core Advanced tier ✅.
   - Whether the Mac and iPhone run identical weights is unknown 🔴.
   - Score false-complete first, since ADR 0008 documents VLM yes-bias.
   - If it passes, the step check no longer needs 3 GB resident.
   - For marginal steps, use Apple's "locate with geometry, crop, ask a closed question" pattern ✅. It may only move a verdict toward incomplete, never toward complete.
3. Private Cloud Compute as a second cloud-assist provider, if Bricky is eligible. It needs no user API key and accepts images. It amends ADR 0011, which names Anthropic and rules out provider fallback chains. The same per-image consent sheet applies.
4. One schema source. Declare the rank and check result types once, then export GenerationSchema JSON for the MLX grammar and for the cloud schema. No bridge needed.

Silent failures to plan for:
- a refusal arrives as ordinary text in string mode ⚠️;
- a Siri-toggle availability bug is unresolved for stable 27.0 🔴;
- guardrails update outside OS releases;
- there is no model pinning, so re-run the eval suite on every OS build.

4.5 Shipping

- Delivery.
  - Exclude the model from backup; download it with a background URLSession.
  - Put a ModelDelivery protocol in front of the transport, and adopt Background Assets later. Its rules for multi-GB non-Core-AI files are unverified 🔴.
  - Add a Remove button and clean up old revisions.
- Thermal policy. At .serious, don't start the 5–8-call VLM recovery; prefer the geometric path and offer cloud assist. At .critical, geometric only. Use decode rate as the temperature signal, because thermalState misreports ⚠️. Pause ghost rendering and the verifier during a VLM burst.
- Benchmark protocol.
  - Release builds only.
  - Bucket runs into cold, warm and sustained (after 30 or more minutes of AR). Gate p50 on the sustained bucket and report p95.
  - Interleave A/B arms, at least 8 repetitions, with a control arm; session-to-session drift reached 16% 🟠.
  - Don't count differences under about 5%.
  - Add to each trace: OS build, device identifier, GPU architecture string, thermal state before and after, minutes since AR started, battery and charging state.

4.6 Evaluation

- Keep score_results.py as the gate authority.
  - The Evaluations framework is a Swift-only beta tied to Xcode 27, and it ships no κ or confidence intervals.
  - Judging images is undemonstrated 🔴.
  - Bricky's harness-macos CI job runs Xcode 16.4 and can't import it.
- Use Evaluations for the language layer. Check repair wording with code checks plus a text judge whose agreement with humans you calibrate (κ > 0.6, which you have to hand-write).
- If an agent is ever built, add tool-trajectory tests with disallowed: [advanceStep].
- Use paired McNemar tests for A/Bs. A variant needs at least 6 wins and 0 losses among the cases where the arms disagree to reach p < 0.05.
- Add a separate challenge set:
  - a shift along the other horizontal axis;
  - a plate one layer up or down;
  - a 90°/180° rotation of an asymmetric part;
  - a rotation of a symmetric part (expected: complete);
  - a same-footprint wrong part;
  - a colour swap, recorded as an expected failure until the RGB term ships.
- DNIKit. Skip network inspection. Split LoRA train and test by authored model and by physical build.

---

5. Don't do these (but consider then for future work)

- Don't port Qwen3-VL-4B to Core AI.
  - The only VLM recipe covers the 2B model ✅.
  - On a 17 Pro, the Neural Engine bundle died at warm-up; only a GPU ahead-of-time build worked 🟠.
  - The fastest Core AI engine exposes no logits, so no grammar-constrained output.
  - It adds re-specialization after every OS update.
- No TensorOps, flash-attention or ICP kernels.
- Don't enable MLXFoundationModels at the current pin.
- Don't fine-tune with mlx_lm or plan on Foundation Models adapters.
- Don't ask any model for bounding boxes, coordinates or stud offsets. Geometry measures; models only phrase.
- Don't let judged labels or replay: rows into a release corpus.
- Don't use tools, KV-cache quantization or speculative decoding for the stateless enum calls.
- Don't use ChatSession for VLM calls; it resizes images to 512 by default.
- Don't trust the Simulator, cold runs or Mac replays as device latency or device numerics.

---

6. ADR changes this implies

┌───────────────────────┬────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│          ADR          │                                                     Change                                                     │
├───────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 0001 / CONTEXT        │ Repair plans: either in-step fixes only, or cross-step "remove and re-add" plans. The second needs a boundary  │
│ boundary              │ change.                                                                                                        │
├───────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 0003                  │ Measured admission (peak + 25% with AR running); memory governor; thermal policy.                              │
├───────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 0006                  │ One sentence permitting layered/instanced render passes. No compute kernels.                                   │
├───────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 0007                  │ RGB captures in evidence bundles. A judge-triage upload, if ever done, is a new egress.                        │
├───────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 0008                  │ RGB term delivered as a learned or baseline model trained on real data, with asymmetric authority.             │
├───────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 0010                  │ The VLM path is "frozen"; log-probability scoring and board changes need an amendment.                         │
├───────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 0011                  │ Private Cloud Compute as a second consented provider.                                                          │
├───────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 0012                  │ The floor becomes 17 Pro / Pro Max, or LiDAR app floor plus a VLM gate.                                        │
├───────────────────────┼────────────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│ 0013                  │ Pin bump; a possible 2B fast tier.                                                                             │
└───────────────────────┴────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘

---

7. Suggested order and your decisions

- Phase 0, no device needed:
  - fix everything in §2;
  - add the telemetry fields;
  - make the scorer honest;
  - add the challenge set;
  - build BuildSessionController and the part-description table;
  - fix the Files "Open in" import.
- Phase 1, on a 17 Pro:
  - collect the first real evidence bundles;
  - measure admission with AR running;
  - record the NAX trace;
  - take sustained-latency rows;
  - A/B log-probability scoring, image-token budgets and the pin bump.
- Phase 2:
  - the placement-level diff and repair plan;
  - camera-relative templated instructions;
  - spoken steps and voice commands;
  - App Intents.
- Phase 3:
  - the RGB term (baseline, then Core AI);
  - the embedding pre-filter once there are 150 or more labelled cases;
  - the Foundation Models shadow test;
  - Private Cloud Compute, if eligible.
- Phase 4: mlx-vlm LoRA, the 2B tier, stud keypoints. (Device-free work in
  PR #14; the 2B tier deferred.)

Decisions I need to make:
1. Floor: 17 Pro/Pro Max only, or LiDAR as the app floor with a 12 GB-class gate for the VLM?
2. Repair scope: fixes within the current step, or cross-step "remove and re-add" plans (which crosses the teardown boundary)? Related: would a suggested ghost placement that the user confirms be acceptable?
3. VLM: if the system model passes the shadow test, should the 3 GB VLM leave the step check, or leave the app entirely?
