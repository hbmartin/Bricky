# ADR 0005: AR alignment is manual and transient

- Status: Accepted
- Date: 2026-08-02

## Context

Reliable automatic registration of arbitrary partial brick builds is a separate
computer-vision problem and cannot be implied by plane detection.

## Decision

Use the fixed 1 LDU = 0.4 mm scale and a user-positioned horizontal-plane
anchor. Provide translation, yaw nudge, and reset controls. Dim completed
geometry and highlight new placements. Never persist `ARAlignment`; require
realignment after relaunch or unrecoverable tracking loss.

## Consequences

The experience makes its precision boundary explicit and remains deterministic
across guide, recovery-board, and AR renders.
