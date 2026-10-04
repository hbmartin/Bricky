# ADR 0012: The floor is iOS 27 on LiDAR-equipped iPhones

- Status: Accepted
- Date: 2026-08-03

## Context

Registration fits scene depth, verification reads it, and occlusion needs
the scene mesh — every triad feature assumes LiDAR-class sensing. Splitting
the app into capability tiers would preserve reach but double the AR test
surface and keep the manual-only mode as a permanently maintained sibling.
iOS 27 additionally brings reference-object tracking to iPhone and
RealityView everywhere, and every LiDAR-equipped iPhone runs it.

## Decision

Raise the floor for the whole app: iOS 27, LiDAR required. One runtime gate
(`ARCameraManager.isSupported`: world tracking, `.mesh` scene
reconstruction, `.sceneDepth` frame semantics) is the single source of
truth, checked at the app root and by admission. Unsupported devices see an
explicit explanation, not a degraded mode. No Info.plist capability key
expresses LiDAR, so the runtime gate is the enforcement mechanism; App Store
metadata must state the requirement.

## Consequences

The audience shrinks to Pro-class iPhones and release waits for iOS 27 GA —
accepted, since the triad release gates are unmet before then anyway. In
exchange there is exactly one sensor and API matrix, and depth may be
assumed unconditionally everywhere.

## Amendment (2026-09-25): the floor is the iPhone 17 Pro class

Decision: the floor narrows from "any LiDAR iPhone on iOS 27" to iPhone 17 Pro
and iPhone 17 Pro Max (`iPhone18,1`, `iPhone18,2`) or a later Pro-class iPhone.

- **One hardware tier.** These are the only LiDAR iPhones with the A19 Pro and
  12 GB of memory. The iPhone 17 and iPhone Air have no LiDAR, and every
  earlier LiDAR iPhone has 8 GB or less. On-device inference beside a running
  AR session is only plausible in this tier, and a single tier is what makes
  the device measurements (admission, thermal, latency) meaningful. The
  memory limits themselves remain; this ADR does not relax ADR 0003.
- **One gate.** `DeviceFloor.evaluate` replaces `ARCameraManager.isSupported`
  as the single source of truth, at the app root and in VLM admission. In
  order, it rejects:
  - the app running on a Mac;
  - devices without LiDAR-class AR (the old check);
  - identifiers that are not `iPhone<major ≥ 18>,<n>`, which covers LiDAR
    iPads in compatibility mode;
  - devices reporting less than 10 × 10⁹ bytes of physical memory, a
    RECONSTRUCTED margin to confirm on the first 17 Pro.

  Each rejection gets its own explanation screen.
- **iPhone only.** `TARGETED_DEVICE_FAMILY` is `1`. `UIRequiredDeviceCapabilities`
  gains `arkit`. Nothing at install time can express LiDAR or a model floor,
  and iPads can still install iPhone apps in compatibility mode, so the
  runtime gate remains the enforcement. **Before the first App Store
  submission, confirm that adding required capabilities is allowed for this
  bundle ID** (it is not for an update that would drop previously supported
  devices).
- **App Store metadata** must state "Requires iPhone 17 Pro or iPhone 17 Pro
  Max, or a later Pro model". Mac (Designed for iPhone) and visionOS
  availability are turned off.
- **Testing.** A Debug-only `-BrickyDeviceFloorOverride <verdict>` launch
  argument lets UI tests reach the app in the Simulator, which has no LiDAR.
  The UI tests now run in CI.

Consequence: owners of the iPhone 12–16 Pro lose the geometric features that
would have worked for them. That trade was chosen deliberately over a LiDAR
floor with a separate memory-class gate for the VLM.
