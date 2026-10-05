# ADR 0003: Local MLX recovery requires runtime admission

- Status: Accepted with physical-device release gate
- Date: 2026-08-02

## Context

The pinned VLM is approximately 3.09 GB and runs concurrently with an AR
session. A successful weight load is not evidence that production inference
fits reliably.

## Decision

Download the immutable model revision resumably into Application Support,
default to Wi-Fi, and verify every file's length and SHA-256. Admit recovery only
after AR world-tracking support, storage, live-memory preflight, and a
production-shaped 1024×1024 guided warm-up while AR is active. Keep one shared
load task and container, serialize calls, cancel and await generation when the
app backgrounds, and provide no cloud inference fallback.

The plan requested `mlx-swift-lm` 3.31.4 together with
`MLXGuidedGeneration`. ✅ VERIFIED from the upstream package manifests: that tag
does not export that product. Bricky therefore pins an immutable upstream
commit and excludes `MLXFoundationModels` from its target graph. The pin
originally recorded here (`cd1ab3dd98ceb02d095490aa25e61298ea3e2f5b`) was
superseded during review; `Packages/RecoveryMLX/Package.swift` pins
`d2424294a6c3bbd0de37a0761d80efc05e6813dd` and is the source of truth for the
exact revision.

## Consequences

Guide-only use remains available on rejected devices. The shipping memory floor
and admitted-device list remain blocked on physical Instruments measurements.

## Amendment (2026-09-25): measured admission, memory governor, thermal policy

**Budget, not a snapshot.** Admission reads the process budget from the
kernel's own accounting: `os_proc_available_memory()` plus `phys_footprint`
(`MemoryGovernor`, `Bricky/Services/Recovery/MemoryGovernor.swift`). MLX's
allocator counters (`Memory.snapshot()`) are never used, because they see
only MLX's buffers. The model's headroom is the budget less everything else
the process holds, so a re-check with the model loaded credits the model's
own resident bytes instead of refusing it for them. Once admitted, a model
keeps its admission until headroom falls 256 MiB below the floor, so AR's
allocation churn cannot flap it.

**Pressure.** A `.critical` memory-pressure event cancels and drains
in-flight inference and unloads the model before iOS terminates the process
for it. A `.warning` does the same only when the loaded model's headroom has
fallen below the floor less the margin. The budget is re-read 500 ms after
the release, once the kernel has reclaimed the pages; that reading is kept
(`lastPressureRelief`), and if even the released model would not fit,
admission is withdrawn until the user retries. Downloads keep running,
because they hold no model memory. Unloading an idle model is a developer
setting, off by default, because re-warming costs a full load.

**Thermal policy** (`InferencePolicy`):

| Thermal state | Recovery | Step check |
| --- | --- | --- |
| nominal, fair | geometric, then VLM fallback | VLM |
| serious | geometric only | VLM (one call) |
| critical | geometric only | deferred |

When VLM recovery is withheld and the geometric pass does not conclude, the
estimate is insufficient with cause `thermal_deferred`, and the manual picker
takes over. Geometric work is never withheld: it is what keeps recovery
available on a hot device. `thermalState` can misreport, so every trace
records thermal state before and after each call next to its decode rate,
which lets Phase 1 calibrate the policy against real throttling.

**Deliberately not done.** A cloud-assist offer on `thermal_deferred`. ADR
0011 offers cloud assist only after the local pipeline returned uncertain,
and recovery has no cloud path at all, so an offer here needs an ADR 0011
amendment first.

**Floor.** The floor is to be measured, not chosen: the peak
(`ledger_phys_footprint_peak` less the footprint before load) of a
production-shaped warm-up and recovery with AR, scene mesh, and ICP running,
plus 25%. Every admission records the inputs (`AdmissionSnapshot`:
footprint before load, the lifetime peak before load, and the warm-up
lifetime peak) on evidence sessions.

`ledger_phys_footprint_peak` is a lifetime value and never resets. A sample
counts only when the warm-up peak is above the peak before load
(`AdmissionSnapshot.modelPeakCostBytes`). Otherwise an earlier load (for
example, before an idle unload) or an AR spike set the peak, and the sample
is masked (`isPeakMasked`). Profile in a fresh process: launch, start AR,
then load. Until Phase 1 measures this on an iPhone 17 Pro, the 5.5 GB floor
stays 🟡 RECONSTRUCTED.

## Amendment (2026-09-25): background delivery

The model now downloads through a background `URLSession`
(`BackgroundURLSessionDelivery`), so a 3 GB download survives backgrounding
and termination. Leaving the app stops model work only, never the download.
Three rules keep the original guarantees:

- **Transfers start only from the foreground button.** The session is not
  discretionary. A relaunch re-attaches to transfers already running; it
  never starts new ones. Each task is described as `<revision>/<asset>`, so
  a transfer that an older app version started for a superseded pin has no
  destination and is dropped.
- **Nothing is published unverified.** The session delegate only moves a
  finished file aside as `<asset>.downloaded`, because hashing 3 GB would
  outlast a background launch. The next foreground `reconcile` (run by
  every admission check) hashes it, publishes it, or deletes it.
- **Retries are bounded.** Resume data is kept as `<asset>.resume`. After a
  failure, a fresh request replaces it, because an expired signed CDN URL
  would fail again. An asset that fails three attempts surfaces an error
  instead of looping.

The part pack stays on the foreground downloader. Device QA is Phase 1
step 2: background the app for 10 minutes, force-quit and relaunch, and
resume after 2 hours to see whether the signed URL expired.
