---
type: reference
owner: docs
updated: 2026-11-10
---

# Hardware and Judging Conditions

- **The Studio Display cannot validate HDR**: 5120×2880, ~600 nits, SDR-only, no EDR.
- **The 12.9″ M2 iPad Pro is the reference**: Liquid Retina XDR, 2732×2048, 600 nits SDR /
  1000 full-screen HDR / 1600 peak, P3. Display headroom is **not a fixed number**: it varies with
  the brightness setting and the displayed content (observed 2026-11-10: up to **16×**, reference
  modes fixed at **10×**, daily use down to **2.67×**, extreme cases **1.67×**). A recipe cap of
  1…8 (max 3 st = 8×) can therefore exceed what the panel can present in its low-headroom states —
  "authored beyond the display headroom" *is* observable on this device (the band is implemented
  and pinned by the parity test).
- **Sidecar/AirPlay are not a validated HDR path** (Sidecar is compressed and latency-bound, AirPlay
  is SDR). Composition only, never final highlight judgement.
- **A cheap, repeatable validation loop:** AirDrop the final HEIC plus a map-stripped SDR copy; view
  both in Photos at ~50 % brightness with True Tone/Night Shift off, moderate room light, cool iPad;
  toggle View Full HDR for the A/B.
- **Calibrate expectations.** The iPad is a consumer display with Apple's tone mapping, not a
  calibrated reference. Judge relative naturalness and detail survival, not nits.

## Device acceptance

Reference iPad: iPad Pro 12.9″ 6th gen (M2, Liquid Retina XDR), iPadOS 27, UDID
`00008112-001E055E3EF0C01E`. Install/launch the Debug build, connect to `appctl serve` on the Mac
(LAN host/port/token), judge, post the recipe, run `appctl deliver`, then open the delivered HEIC in
**Photos** and **Safari** on the iPad: both must show the intended HDR with an SDR view that still
matches Capture One. The Mac's built-in Studio Display is SDR-only; a Mac with an external HDR
display may judge through the iOS app (Designed for iPad), but it is a supplement, not the primary
surface. The full device acceptance log lives in [the acceptance report](../plans/p3-report.md).
