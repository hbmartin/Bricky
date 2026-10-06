# ADR 0016: Hands-free "next" follows one advance policy; Spotlight is opt-in

- Status: Accepted. Voice stays behind a developer flag until the Phase 1
  hands-free checks pass; Siri asks every time; Spotlight is opt-in.
- Date: 2026-10-05

## Context

Building needs both hands, so the guide should be usable without touching
the phone: hear the step, say "next". ADR 0001 says the user confirms every
step, and ADR 0008 says the verifier is advisory and nothing auto-advances.
A voice command is a user act. But it is easier to trigger by accident than
a tap: a sentence that happens to contain "next", the app's own narration,
or Siri while the phone is in a pocket. It also arrives without the user
looking at the screen, so a check that says the step is not done would go
unseen.

`BuildSessionController` already owns progress, and it never rewinds on a
confirm (PR #11).

## Decision

**One policy decides every hands-free "next".** `AdvancePolicy.decide` is
pure and tested row by row. `BuildSessionController.requestAdvance` applies
it for voice now and for Siri / App Intents (M2.8b).

| Situation | "next" | "next anyway" |
|---|---|---|
| Hands-free, and no guide on screen in the foreground | refuse | refuse |
| The step on screen is not the next one to build | browse forward | browse forward |
| Every step already confirmed | refuse | refuse |
| Check says complete, or cannot tell (uncertain), or there is no check | advance | advance |
| Check says incomplete or misplaced | hold, and say why (with the repair, ADR 0015) | advance |

- An abstaining check is not a reason to hold. Holding on "uncertain" would
  make hands-free useless exactly where depth cannot see, which is plates
  and tiles.
- A negative check holds "next" and is spoken, so the user hears it. "Next
  anyway" is the explicit override. Evidence windows record it as one
  (ADR 0007 amendment 2).
- Progress never moves backward through this path. On a browsed step,
  "next" only moves the view. Recovery remains the only rewind.
- A verdict counts only for the step on screen.
- On-screen taps keep their current behaviour. They are attended by
  construction.

**Voice listens for a closed set of commands, on device.**
- `VoiceCommandService` uses `SpeechAnalyzer` with a `DictationTranscriber`
  (the system dictation models, on device). It is biased toward the
  command phrases with `AnalysisContext.contextualStrings`. Only a
  **finalized** result whose **whole utterance** is a command acts.
  "Next week" and "what's next" do nothing, and neither does a volatile
  result.
- Audio comes from an `AVAudioEngine` input tap, converted by
  `AnalyzerInputConverter`. `CaptureInputSequenceProvider` would start a
  second `AVCaptureSession` beside ARKit's, so it is not used.
- The microphone is gated while narration plays and for 600 ms after it ends
  (`MicGate`). The tap feeds silence then, so the app never transcribes
  itself and the analyzer's time line stays continuous.
- Nothing is stored: no audio and no transcripts, in evidence or anywhere
  else.
- The grammar is English. On other locales the service says so and stays
  off.
- Microphone permission only, as Apple's 2026 sample does. Whether
  `SpeechAnalyzer` also needs speech-recognition authorization is
  unverified (apple-speech guide gap G21), so `NSSpeechRecognitionUsageDescription`
  is not added until a device run says it is needed.

**Narration uses AVFoundation speech synthesis.** There is no newer
text-to-speech API for apps (Apple staff, forum thread 834149). The
narrator speaks:
- the step on screen: one part by name, several by count;
- why "next" held, with the repair sentence from `RepairPhrasebook`;
- refusals.

All of these strings live in the String Catalog under the same forbidden-word
test as the phrasebook.

**Off by default.** Hands-free sits behind
`AppConfig.Defaults.handsFreeEnabled` ("Hands-free in the AR guide", in
developer settings). It turns on by default only after the Phase 1
checklist passes on an iPhone 17 Pro class device:
- 0 false advances in 30 minutes of background noise;
- command recall ≥ 95% in a quiet room;
- narration never triggers a command;
- it works with Speech Recognition denied in Settings (G21);
- thermals and memory hold with AR, speech and the VLM together.

**Siri and Shortcuts go through the same policy and always ask first.**
`NextStepIntent` ("Next step in Bricky") has `supportedModes = .background`:
it never opens the app.
- Attendance: a guide must be on screen while the app is not in the
  background. Inactive still counts, because Siri's own overlay makes the
  app inactive. Locked or backgrounded, the intent refuses without asking.
- It always calls `requestConfirmation` before anything moves, and the
  prompt says exactly what will happen ("Mark step 4 done and show step
  5?").
- When the AR guide's check says the step is unfinished, the prompt leads
  with the repair sentence and asks "Go on anyway?". Confirming is the
  user's "next anyway".
- Declining throws and changes nothing. If the guide moved while the
  prompt was up, nothing changes either.
- The AR guide reports its latest check and worded repair to the session
  (`reportVerification`), so Siri judges by what the screen shows.

**Spotlight holds models only when the user asks.**
- `InstructionModelEntity` is an `AppEntity` and an `IndexedEntity`
  carrying a title and a step count. It never carries progress, photos or
  evidence.
- Indexing happens only while "Show models in Spotlight" (Settings,
  Privacy) is on. It is off by default.
- Every sync first empties the app's named index
  (`deleteAppEntities(ofType:)`). With the setting off, that is all it
  does. With it on, it rewrites the whole set, so a replaced model never
  lingers.
- Syncs run at launch, after an import, and when the setting changes.
- Nothing leaves the device: this is the on-device Spotlight index.
- A Spotlight result opens the app. It does not open a model; that would
  need an `OpenIntent`, which is not built.

## Consequences

- Voice and Siri cannot advance a step the check says is unfinished without
  the words "next anyway". They cannot advance anything from the background.
- A voice advance during verification writes an `override` window when the
  verdict was not complete, the same as any other move past the verifier.
- Siri and the voice service reuse `requestAdvance`. Unlike voice, Siri
  is not behind the hands-free flag: it refuses unless a guide is on screen,
  and it asks every time.
- The Phase 1 checklist adds: Siri refuses when the app is backgrounded or
  locked, and Spotlight entries disappear when the setting is turned off.
- `.frequentFinalization` with the `phrase` preset is a guess at the
  fastest finalization for short commands. Its latency on the dictation
  models is a Phase 1 measurement.
