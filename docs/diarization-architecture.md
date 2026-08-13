# Diarization Architecture

Current state of speaker identification as of 2026-08-12, and the
condensed lessons of how it got here. Companion to
`audio-architecture.md`; the field history lives in the commit log.

## The system

**Embedding model: NVIDIA TitaNet (192-D) via sherpa-onnx, CPU**, since
Aug 2 (`~/.meetink/models/speaker-embedding-titanet.onnx`, 101 MB). It
replaced WeSpeaker ResNet34-LM (256-D, 26 MB) — that switch was the big
quality jump and invalidated all prior profiles (`pre-titanet-backup/`).
WeSpeaker ResNet293-LM (114 MB) sits on disk as the next candidate: a
benchmark increment, not a leap, and CPU cost is a non-issue on Apple
Silicon (~2-4× TitaNet, still ms-scale per window). Not worth switching
until the current gates prove insufficient. Thresholds are calibrated
PER MODEL — TitaNet runs threshold 0.48 / margin 0.06 / cluster 0.5;
the 0.65 defaults in code are the old model's numbers.

**Three identification passes:**

1. **Live** — capture accumulates 10 s windows (3 s overlap) of system
   audio and POSTs to `:8179/identify`. Match → uppercased profile name
   becomes the live label; no match → online clustering assigns
   "Speaker N". Mic chunks are always ME.
2. **Refine (at stop)** — offline global clustering over the whole
   session with sentence granularity, matched against profiles;
   rewrites the transcript. Temporal fold dissolves orphan
   one-off clusters into the nearest voice.
3. **Relabel / Reprocess** — rerun (2) on demand after profile
   improvements.

**Profile store** (`~/.meetink/profiles/`): one `<Name>.npz` per person —
raw sample embeddings (cap 500, 180-day time decay), k-means centroids
(≤3), per-sample timestamps. Matching scores against the BEST centroid
(multimodal voices keep their modes). Sidecars: `emails.json`
(email → profile name, one profile / many emails — the join between
calendar attendees and voices), and `audio/<Name>/*.wav` (rolling 20
raw enrollment snippets, so a future model swap re-embeds losslessly
instead of re-enrolling everyone). Placeholder profiles (0 samples)
reserve a name for email links and later assignment; the min-samples
gate keeps them out of identification.

**Acceptance gates in `identify()`**, in order:

- Whitelist (when set): only expected attendees are nameable. Derived
  at meeting start from calendar attendees — exact email links first,
  name-token match as fallback.
- Min samples: profiles under 6 samples can't label anyone (a 1-sample
  profile is a single utterance's fingerprint and matches near-random
  voices).
- Threshold + margin over runner-up; single-candidate floor 0.78;
  close-pair mode (top-two cross-sim ≥ 0.80 → margin drops to 0.03,
  letting a consistent small advantage decide between genuinely similar
  voices).
- **Tightness-adaptive threshold**: the threshold rises by the
  profile's tightness deficit below 0.78 (cap +0.08). Loose/diffuse
  profiles claim strangers — the max-over-centroids score gives a
  spread-out sample cloud a wide acceptance radius.
- **Impostor test** (whitelist sessions): the winner must beat the best
  NON-whitelisted profile by the same margin. "Sounds like several
  people" is resemblance, not identity.
- **Borderline hysteresis**: a score within threshold+0.07 labels only
  on the second consecutive window agreeing — one-off grazes stay
  Speaker N.
- **Confirmed-present relaxation**: after a mid-call assignment, that
  profile's gates relax (threshold −0.06, margin ×0.5) — the user
  vouched they're in the room. Assignment also folds SIBLING clusters
  (other anonymous letters of the same voice at threshold+0.03) and
  rewrites their transcript lines.

**Learning loops:**

- Auto-train: high-confidence matches fold back into the profile
  (guardrails: confidence floor, margin multiplier, min samples,
  tightness floor to stop accelerating drift).
- Assignment (sidebar): folds the session cluster's samples in, with
  per-sample outlier rejection (floor 0.4).
- **Segment reassignment harvest**: correcting transcript segments cuts
  those exact spans from the kept stems (sys for remote voices, mic for
  self), enrolls them (≥3.5 s only, longest-first, cap 8/operation).
  A manual correction is the highest-quality label that exists. The
  sidebar assign falls back to the same harvest when no live session
  data exists.
- Hygiene: `/profile prune <name>` drops orphan centroids (minority
  cluster under 0.55 sim to its siblings = another person folded in)
  and stray samples.

## What worked vs. what bit us

**Worked on merit:**
- TitaNet over ResNet34 — the single biggest accuracy jump.
- Strict gates biased toward "unknown": wrong-name errors hurt far more
  than Speaker-N errors (refine cleans the latter automatically).
- Whitelisting by attendees, especially with exact email links.
- Harvest-from-stems: rebuilding Allen and Judd from labeled meeting
  audio produced tighter profiles (0.87 / 0.80) than weeks of
  incremental accumulation.
- The refine pass's temporal fold for singleton-cluster spam.

**Paid-for lessons:**
- **Thin profiles are landmines.** A 1-sample profile claimed a line in
  a meeting its owner wasn't in → min-samples identify gate.
- **Auto-train during a mislabeled meeting poisons fast.** One meeting
  where Allen's speech carried a JUDD label made Allen the MAJORITY
  centroid of Judd's profile (Allen↔Judd similarity 0.951 — same-voice
  territory for two different people). Prune's minority rule can't
  catch majority pollution; the fix was delete-and-rebuild from a
  known-clean meeting. Watch `nearest` on the profiles listing — a
  cross-profile sim above ~0.8 that isn't a real voice twin means
  pollution.
- **Loose profiles claim strangers.** A 500-sample tightness-0.73
  profile claimed a brand-new guest at 0.66 → tightness-adaptive
  threshold.
- **Case-insensitive filesystem vs case-sensitive profile dict.**
  "ED"/"Ed" fought over one npz; renaming DOUG→Doug deleted the file it
  had just saved → canonical name matching + recase-aware rename.
- **Assignments without voice data ghost.** Assigning a new name after
  a server restart renamed transcript lines but created no profile,
  silently → loud alerts, archive-harvest fallback, placeholder
  profiles.
- **37 "speakers" in a 6-person call** was a long tail of one-off hard
  windows each minting a fresh cluster letter — not misclustering →
  sibling folds + confirmed relaxation + hysteresis attack the causes;
  refine's fold cleans the residue.
- **Server restarts lose session voice data.** Mid-day restarts cost
  two enrollment opportunities (and nearly cost the Doug profile).
  Restart the diarize server only between meetings, and only after
  pending assignments are done.

## Configuration surface

Presets `default` / `focused` / `strict` (`/diarize sensitivity`), plus
env overrides: `MEETINK_DIARIZE_THRESHOLD` / `_MARGIN` /
`_CLUSTER_THRESHOLD` / `_SINGLE_FLOOR` / `_CLOSE_PAIR_THRESHOLD` /
`_CLOSE_PAIR_MARGIN`, `MEETINK_IDENTIFY_MIN_SAMPLES` (6),
`MEETINK_DIARIZE_CONFIRMED_RELAX` (0.06), `MEETINK_DIARIZE_BORDER_BAND`
(0.07), `MEETINK_PROFILE_AUDIO_KEEP` (20), `MEETINK_DIARIZE_MODEL`,
`MEETINK_DIARIZE_PRESET`. Auto-train knobs via `/diarize auto-train`.

## Open threads

- Field-validate the new gate stack (tightness bump, impostor,
  hysteresis) across a week of real meetings before touching the model.
- ResNet293 swap when desired: re-embed `profiles/audio/` snippets,
  harvest archived meetings for the rest, recalibrate thresholds.
- Possible next prior: pre-confirm expected voices per event from email
  links (the session_confirmed treatment, applied at meeting start).
