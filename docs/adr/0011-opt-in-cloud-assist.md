# ADR 0011: Opt-in cloud assist with a user-supplied API key

- Status: Accepted
- Date: 2026-08-03

## Context

Some steps are honestly unverifiable on device: undetectable deltas
(ADR 0008) and ambiguous recoveries leave the local pipeline uncertain. A
frontier cloud VLM is a useful second opinion exactly there, but the privacy
promise — nothing leaves the device — was absolute, and no key-holding
server exists or is wanted.

## Decision

Soften the promise to explicit per-image consent, implemented with a
user-supplied Anthropic API key stored in the Keychain and called directly
from the device. Three gates, all required: a default-off settings toggle, a
per-send confirmation sheet showing the exact frame to be uploaded, and
availability only when the local pipeline has already returned uncertain or
inconclusive. The payload is one JPEG (board or frame plus expected-step
render) and minimal step context; responses are constrained to the same
enums the local grammars produce, so cloud and local verdicts decode into
identical domain types.

Deliberately not built: any server or relay, accounts, response history,
multi-frame or video upload, automatic sends, provider fallback chains, and
telemetry. Instruction models and LDraw files never leave the device under
any setting.

## Consequences

The privacy line becomes "images never leave the device without explicit
per-image consent", which the consent UX enforces structurally. Only users
willing to obtain an API key benefit, and that is accepted: cloud assist is
an escape hatch, not a load-bearing feature, and adding a relay later
remains possible behind the same provider protocol.
