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
