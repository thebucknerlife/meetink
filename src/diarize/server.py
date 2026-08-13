#!/usr/bin/env python3
"""Speaker identification sidecar for meetink.

Listens on 127.0.0.1:8179. The Swift capture binary POSTs ~10s WAV windows
to /identify; /profile add (in the REPL) POSTs 3 enrollment samples per
person to /enroll. Profiles persist as .npz files at $MEETINK_PROFILES_DIR
(default: ~/.meetink/profiles/<name>.npz).

Identification is two-stage:
  1. Compare to enrolled profiles. If top match clears THRESHOLD and beats
     the runner-up by MARGIN, return that name.
  2. Otherwise the embedding is "unknown" → group it into an in-memory
     cluster (online clustering) and return `Speaker 1`, `Speaker 2`, ... so the
     live transcript still distinguishes voices. After the meeting the user
     runs `/profile assign A Alice`, which converts the cluster to a real
     profile and lets the launcher rewrite past transcript lines.

Cluster state is per-session: cleared by POST /session/clear (which the
launcher calls on /start), and never persisted to disk. Lettering is
monotonic — assigning cluster A doesn't free "A" for the next unknown.

Accuracy
--------
- Multi-sample profiles: each name is a centroid of all enrollment samples
  (L2-normalised before averaging). Adding more samples sharpens the centroid
  rather than dilutes it.
- Threshold: cosine similarity ≥ THRESHOLD (default 0.65) is required to claim
  a profile match. Below that we cluster.
- Margin: the top profile match must beat the runner-up by ≥ MARGIN
  (default 0.07). If two profiles score similarly, we cluster instead of
  guessing — avoids the Bob-misidentified-as-Alex failure mode.
- CLUSTER_THRESHOLD (default 0.65): cosine similarity required to join an
  existing cluster vs. starting a new one.

Endpoints
---------
GET    /                              health + profile names + cluster count
GET    /profiles                      list profile names + sample counts
POST   /identify                      body=WAV → {speaker, confidence, runner_up?, cluster?}
POST   /enroll?name=<name>            body=WAV → appends one sample to that profile
DELETE /profiles/<name>               remove
POST   /profiles/<name>/pop?count=N   drop last N samples, recompute centroid
                                      (count defaults to 1; refuses if it
                                      would empty the profile — use DELETE
                                      for that)

GET    /session/clusters              list current clusters (letter, count)
POST   /session/clear                 reset clusters (called by /start)
POST   /session/load                  replace session clusters with the refine
                                      pass's final analysis (JSON body); makes
                                      post-call assignment enroll real voice data
POST   /session/assign?cluster=A&name=Alice
                                      cluster accepts an id, "Speaker 3", or an
                                      assigned label ("GREG") — reassign works
                                      promote cluster A to a real profile
POST   /session/merge?from=A&into=B   merge cluster A's samples into cluster B
POST   /session/rename?from=bob&to=flavio
                                      rename a profile, OR fold its samples
                                      into an existing profile if `to` already
                                      exists (used to fix split identities like
                                      bob/flavio being the same person)
GET    /session/sensitivity           current threshold/margin/cluster_threshold
POST   /session/sensitivity?mode=focused|default|strict
                                      apply a preset; takes effect on next
                                      /identify, no restart required
GET    /session/auto-train            current auto-train settings
POST   /session/auto-train?enabled=true|false&floor=0.88
                                      &margin_multiplier=2.0&min_samples=5
                                      tweak any subset; high-confidence
                                      /identify matches fold back into the
                                      profile when guardrails all pass
GET    /session/whitelist             current per-session profile whitelist
POST   /session/whitelist?profiles=alex,stacey
                                      restrict /identify to a subset of
                                      profiles (others won't match → cluster
                                      as Speaker N). Eliminates the "Mike's
                                      voice scores 0.89 against ALEX" risk
                                      when going into a meeting with people
                                      who aren't all enrolled.
POST   /session/whitelist?clear=true  drop the whitelist (match all profiles)
POST   /session/adopt-last?name=Mike&age_max_s=20
                                      pull the most recent /identify
                                      embedding (system audio, i.e. someone
                                      else's voice) and append it to profile
                                      `name`. Powers /profile train mid-
                                      meeting so the user can click "train
                                      Mike" right after Mike speaks and
                                      actually grab Mike's voice, not their
                                      own mic input.
"""

from __future__ import annotations

import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

import numpy as np

MK_HOME = Path(os.environ.get("MEETINK_HOME", os.path.expanduser("~/.meetink")))
MODEL_PATH = Path(os.environ.get("MEETINK_DIARIZE_MODEL", MK_HOME / "models" / "speaker-embedding.onnx"))
PROFILES_DIR = Path(os.environ.get("MEETINK_PROFILES_DIR", MK_HOME / "profiles"))
PORT = int(os.environ.get("MEETINK_DIARIZE_PORT", "8179"))

# --- Sensitivity presets ----------------------------------------------------
#
# Three knobs control how the server hands out names:
#   threshold         — cosine ≥ this is required to claim a profile match
#   margin            — top profile must beat runner-up by ≥ this
#   cluster_threshold — cosine ≥ this is required to join an existing cluster
#
# Different meetings want different bias. The presets below are sized
# around the failure modes we've seen, not just nudges to the defaults.
#
# focused  — 1:1s and small meetings with familiar speakers.
#            Wide MARGIN guards against bob-vs-flavio confusion when two
#            enrolled profiles sit close in voice space (the common
#            failure: Flavio scoring 0.66 against BOB and 0.62 against
#            FLAVIO, false-naming as BOB). Low CLUSTER_THRESHOLD keeps
#            an unmatched speaker as one cluster instead of splintering
#            into Speaker 1/2/3 across the call.
#
# default  — what shipped before sensitivity was a runtime knob. Kept as
#            a baseline for backwards compatibility, not because it's
#            the universal best.
#
# strict   — large meetings with strangers. Higher THRESHOLD avoids
#            misnaming an unknown speaker as someone enrolled. Higher
#            CLUSTER_THRESHOLD preserves distinct voices as distinct
#            clusters even when they're tonally similar.
PRESETS: dict[str, dict[str, float]] = {
    "focused": {"threshold": 0.62, "margin": 0.12, "cluster_threshold": 0.55},
    "default": {"threshold": 0.65, "margin": 0.07, "cluster_threshold": 0.72},
    "strict":  {"threshold": 0.70, "margin": 0.10, "cluster_threshold": 0.78},
}

# Live settings — every code path reads these via dict lookup so a POST
# /session/sensitivity update takes effect on the very next /identify
# without a server restart. Env-var overrides at boot still win on the
# initial read; presets are applied on top of them when chosen.
#
# `single_profile_floor` patches a real correctness hole: when /identify
# only has ONE candidate (whitelist of size 1, or only one enrolled
# profile), the MARGIN check is meaningless because runner-up similarity
# defaults to -1.0 and `top - (-1.0)` always exceeds MARGIN. So a Mike-
# voice scoring 0.68 against Ethan would confidently get labeled ETHAN
# even though it's clearly not him by absolute confidence. The floor
# raises the bar in that case (default 0.78 — about 13pp above the
# default THRESHOLD of 0.65, well into "this is really the same speaker"
# territory). Set to <= THRESHOLD to disable the extra check.
settings: dict[str, float] = {
    "threshold": float(os.environ.get(
        "MEETINK_DIARIZE_THRESHOLD",
        str(PRESETS["default"]["threshold"]),
    )),
    "margin": float(os.environ.get(
        "MEETINK_DIARIZE_MARGIN",
        str(PRESETS["default"]["margin"]),
    )),
    "cluster_threshold": float(os.environ.get(
        "MEETINK_DIARIZE_CLUSTER_THRESHOLD",
        str(PRESETS["default"]["cluster_threshold"]),
    )),
    "single_profile_floor": float(os.environ.get(
        "MEETINK_DIARIZE_SINGLE_FLOOR", "0.78",
    )),
    # Close-pair adaptive margin. When the top profile and runner-up
    # cross-match heavily (cross-sim ≥ close_pair_threshold), the
    # WeSpeaker embedding model literally cannot separate them by much,
    # so the standard MARGIN requirement makes the call un-labelable.
    # In that regime, even a small consistent advantage in audio score
    # is meaningful (Alex's voice systematically scores slightly higher
    # on Alex than Ethan despite the centroid overlap). Drop to a much
    # smaller floor — the THRESHOLD gate still protects against
    # absolute-low scores from unrelated voices.
    "close_pair_threshold": float(os.environ.get(
        "MEETINK_DIARIZE_CLOSE_PAIR_THRESHOLD", "0.80",
    )),
    "close_pair_margin": float(os.environ.get(
        "MEETINK_DIARIZE_CLOSE_PAIR_MARGIN", "0.03",
    )),
}
# Track which preset (if any) the user explicitly selected, so GET
# /session/sensitivity can echo "focused" instead of always "custom".
settings_preset: str = os.environ.get("MEETINK_DIARIZE_PRESET", "default")


# --- Auto-train ------------------------------------------------------------
#
# When /identify scores well above noise against an enrolled profile, fold
# the embedding back into that profile's samples. Continuous self-improvement
# from real conversational audio without manual /profile train calls.
#
# Three guardrails to prevent the failure mode that bit FLAVIO earlier
# today (pollution from a wrong-but-confident match):
#
#   1. Confidence floor — match cosine must clear `floor` (much higher
#      than the matching THRESHOLD). 0.88 by default vs the matching
#      THRESHOLD of 0.62-0.70.
#   2. Margin multiplier — top match must beat runner-up by at least
#      `margin_multiplier` × the current MARGIN. So in default mode
#      (MARGIN=0.07) we require 0.14+ separation; in focused mode
#      (MARGIN=0.12) we require 0.24+. Either way, two-profiles-tied
#      situations don't auto-train.
#   3. Min samples — profiles with very few samples (cold start) skip
#      auto-train; one bad sample on a 3-sample profile shifts the
#      centroid 25%, which is too risky.
#
# Anything that does land in the profile is plain append-via-_add_sample,
# so /profile undo <name> N peels recent auto-additions cleanly. Server
# also stderr-logs every auto-add so /diarize log surfaces them.
auto_train_settings: dict = {
    "enabled": os.environ.get(
        "MEETINK_AUTO_TRAIN", "true",
    ).lower() in ("1", "true", "yes", "on"),
    "floor": float(os.environ.get("MEETINK_AUTO_TRAIN_FLOOR", "0.88")),
    "margin_multiplier": float(
        os.environ.get("MEETINK_AUTO_TRAIN_MARGIN_MULT", "2.0"),
    ),
    "min_samples": int(
        os.environ.get("MEETINK_AUTO_TRAIN_MIN_SAMPLES", "5"),
    ),
    # Hysteresis floor on profile tightness. When tightness drops below
    # this — meaning recent samples are clustering loosely or pulling
    # the centroid apart — auto-train is suspended for that profile
    # until the user manually intervenes (re-train, /profile rm-then-
    # re-add, /profile assign from a fresh cluster). Catches runaway
    # drift: once a non-target voice gets confidently auto-trained in,
    # subsequent /identify scores skew, more wrong samples land, the
    # centroid keeps drifting. Pausing auto-train when tightness drops
    # gives the user a window to fix it before it snowballs.
    "tightness_floor": float(
        os.environ.get("MEETINK_AUTO_TRAIN_TIGHTNESS_FLOOR", "0.75"),
    ),
}


# Auto-train activity log so the REPL footer / /profile output can show
# users when auto-train is actually doing useful work. Without this,
# auto-train was a black box — samples would silently grow (or not) and
# users had no signal beyond /diarize log. Capped at 100 to bound memory
# (the count metric is unbounded; the per-event detail is tail-only).
_auto_train_log: list[dict] = []
_AUTO_TRAIN_LOG_MAX = 100


# --- Profile representation tuning ----------------------------------------
#
# Three changes from the original "single centroid + uniform mean" model
# that the user hit pollution issues with:
#
#   1. Outlier rejection. New samples must score ≥ OUTLIER_FLOOR against
#      at least one existing centroid before being accepted. Catches the
#      common failure modes: a different speaker briefly bleeding into a
#      /profile train sample, or a /session/assign / /session/rename fold
#      where the user mistakenly identifies two distinct speakers as one.
#   2. k-means per profile. A single centroid can't represent multimodal
#      voice (calm vs excited, headset vs laptop mic, etc.) — averaging
#      them lands you in the middle of voice space, fitting neither
#      mode. With up to MAX_CENTROIDS centroids per profile, matching
#      scores against the *best* mode, not the mean of all modes.
#   3. Time decay. Old samples are weighted exponentially less in the
#      centroid computation, so the profile tracks the speaker's
#      *current* voice characteristics (new headset, recovered from cold,
#      etc.). Default TAU=180 days is conservative — recent samples
#      dominate but old ones still meaningfully contribute.
#
# All three are conservative defaults; can be disabled / loosened via
# env vars without code changes.
PROFILE_MAX_CENTROIDS = int(os.environ.get("MEETINK_PROFILE_MAX_CENTROIDS", "3"))
PROFILE_SAMPLES_PER_CENTROID = int(
    os.environ.get("MEETINK_PROFILE_SAMPLES_PER_CENTROID", "10")
)
PROFILE_OUTLIER_FLOOR = float(
    os.environ.get("MEETINK_PROFILE_OUTLIER_FLOOR", "0.40")
)
# Time decay TAU in seconds. 0 = disabled (uniform weights). Default
# 180 days: a sample from TAU seconds ago has weight 1/e ≈ 0.37.
PROFILE_TIME_DECAY_TAU_S = float(
    os.environ.get(
        "MEETINK_PROFILE_TIME_DECAY_TAU_S",
        str(180 * 24 * 3600),
    )
)
# Cap k-means iterations. Spherical k-means on ~100 samples × 3 centroids
# converges in 5-10 iters; 20 is plenty of headroom.
_KMEANS_MAX_ITERS = 20

# Hard cap on samples retained per profile. The auto-train path (_add_sample)
# appends a row on every high-confidence /identify match; without a cap a
# single frequently-matched speaker grows the profile matrix unboundedly over
# a long-running session — the same np.vstack-growth pattern that fragments
# libmalloc and leaked tens of GB via the cluster path. 500 recent samples is
# far more than anyone enrols manually, so this only ever bounds runaway
# auto-train accumulation. Time-decay still weights within the retained window.
PROFILE_MAX_SAMPLES = int(os.environ.get("MEETINK_PROFILE_MAX_SAMPLES", "500"))


# --- Session whitelist ----------------------------------------------------
#
# When set, /identify only considers this subset of profiles. Voices that
# would otherwise have matched a profile outside the whitelist fall through
# to clustering (Speaker N) — which is exactly what you want when you go into
# a meeting with people who aren't all enrolled. Auto-train naturally
# inherits the restriction (it operates on identify's output).
#
# None = no whitelist, match against everything (default, backwards-compat).
# []   = match against nothing, always cluster.
session_whitelist: "list[str] | None" = None

# Profiles the user has CONFIRMED are in this meeting by assigning a
# cluster to them mid-call. That's a strong prior — the person is
# definitely in the room — so identify() relaxes its gates a notch for
# these names (field case: assigned mid-sentence, the very next window
# fell back to "Speaker 38" because it scored 0.61 against a 0.65
# threshold). Cleared on /start.
session_confirmed: "set[str]" = set()

# Borderline-label hysteresis: a match scoring just above threshold gets
# labeled only when the PREVIOUS window (within the window cadence)
# matched the same name — one-off grazes of a profile stay Speaker N
# instead of stamping a wrong name on a single line. Confident scores
# and user-confirmed (session_confirmed) names label immediately.
BORDERLINE_BAND = float(os.environ.get("MEETINK_DIARIZE_BORDER_BAND", "0.07"))
_borderline_pending: dict = {"name": None, "ts": 0.0}


# --- Recent embedding ring -------------------------------------------------
#
# /profile train <name> mid-meeting used to record from the user's mic,
# which is the wrong stream for training someone else (the call audio is
# the system stream — heard via the capture binary's ScreenCaptureKit
# pipeline, which POSTs 10 s windows here to /identify). Result: every
# `train` call appended room tone / breathing to the target profile and
# polluted the centroid away from the actual speaker.
#
# The ring keeps the most-recent N embeddings seen by /identify so the
# `/session/adopt-last` endpoint can grab the latest one and fold it
# into the right profile. N is small (10) because the relevant window
# is "what just happened in the meeting" — a 10 s identify cadence ×
# 10 entries = ~100 s of history, plenty for a click-after-speaking
# UX. 256-D embeddings at float32 = 1 KB each, so the ring is ~10 KB.
_recent_embeddings: list[dict] = []
_RECENT_RING_MAX = 10


def _push_recent_embedding(emb: np.ndarray) -> None:
    """Append a copy of `emb` to the ring, evict oldest if over cap.
    Stores a copy so caller-side mutation can't corrupt history."""
    _recent_embeddings.append({"ts": time.time(), "emb": emb.copy()})
    while len(_recent_embeddings) > _RECENT_RING_MAX:
        _recent_embeddings.pop(0)


def _maybe_auto_train(
    emb: np.ndarray,
    name: str,
    confidence: float,
    runner_up_confidence: float,
) -> bool:
    """Append `emb` to profile `name` if all guardrails pass. Returns
    True iff a sample was actually added."""
    if not auto_train_settings["enabled"]:
        return False
    if confidence < auto_train_settings["floor"]:
        return False
    # Margin requirement scales with the active sensitivity preset's
    # MARGIN: stricter presets demand stricter auto-train margin.
    margin_gap = confidence - runner_up_confidence
    required = settings["margin"] * auto_train_settings["margin_multiplier"]
    if margin_gap < required:
        return False
    profile = profiles.get(name)
    if profile is None:
        return False
    if profile["samples"].shape[0] < auto_train_settings["min_samples"]:
        return False
    # Hysteresis guard: if the profile's recent samples have started
    # spreading (tightness < floor), don't accelerate the drift by
    # adding more auto-train samples. The user can resume by manually
    # /profile train (which forces an /enroll regardless of tightness)
    # or by re-establishing a clean profile.
    tight = _profile_tightness(profile)
    if tight < auto_train_settings["tightness_floor"]:
        print(
            f"auto-train suspended for {name}: tightness {tight:.3f} < "
            f"floor {auto_train_settings['tightness_floor']:.3f}",
            file=sys.stderr,
        )
        return False
    # `_add_sample` runs the outlier check as well. An auto-train sample
    # that scored 0.88+ in /identify will easily clear the 0.40 outlier
    # floor, so this is effectively a no-op for legitimate matches —
    # but it does protect against the edge case where the auto-train
    # centroid is held together by old samples and the new one is
    # actually from a similar-sounding stranger.
    if _auto_session_count.get(name, 0) >= AUTO_TRAIN_SESSION_CAP:
        return False
    _, accepted, _ = _add_sample(name, emb, source="auto")
    if accepted:
        _auto_session_count[name] = _auto_session_count.get(name, 0) + 1
    if accepted:
        _auto_train_log.append({
            "ts": time.time(), "name": name,
            "confidence": round(confidence, 3),
        })
        while len(_auto_train_log) > _AUTO_TRAIN_LOG_MAX:
            _auto_train_log.pop(0)
    return accepted

PROFILES_DIR.mkdir(parents=True, exist_ok=True)

if not MODEL_PATH.exists():
    print(f"error: speaker-embedding model not found at {MODEL_PATH}", file=sys.stderr)
    print("  Run /diarize install or set MEETINK_DIARIZE_MODEL.", file=sys.stderr)
    sys.exit(1)

try:
    import sherpa_onnx
except ImportError:
    print("error: sherpa-onnx not installed in this venv", file=sys.stderr)
    print("  Run /diarize install.", file=sys.stderr)
    sys.exit(1)

# Default to CPU because sherpa-onnx's CoreML provider has been
# unreliable for the WeSpeaker model on recent macOS — every
# `compute()` returns "Unable to compute the prediction using a
# neural network model" with no useful diagnostic. The model is
# small (25 MB) and the inference is fast on CPU (~5-10 ms per 10 s
# audio window), so the performance trade is negligible. Override
# via MEETINK_DIARIZE_PROVIDER=coreml if you want to opt back in.
DIARIZE_PROVIDER = os.environ.get("MEETINK_DIARIZE_PROVIDER", "cpu")

print(
    f"loading model: {MODEL_PATH} (provider={DIARIZE_PROVIDER})",
    file=sys.stderr,
)
extractor = sherpa_onnx.SpeakerEmbeddingExtractor(
    sherpa_onnx.SpeakerEmbeddingExtractorConfig(
        model=str(MODEL_PATH),
        num_threads=2,
        debug=False,
        provider=DIARIZE_PROVIDER,
    )
)

# Embedding dimensionality of the ACTIVE model — used by the profile
# loader's dimension guard (see _load_all) so profiles enrolled under a
# different embedding model are skipped instead of crashing every cosine.
_extractor_dim = int(getattr(extractor, "dim", 0) or 0)



# ---------------------------------------------------------------------------
# Profile storage
#
# Each profile dict contains:
#   centroids    K×D float32  — K cluster centroids (L2-normalised). K is
#                                derived from sample count, capped at
#                                PROFILE_MAX_CENTROIDS.
#   samples      N×D float32  — every enrollment / train / assign / auto
#                                sample, in addition order.
#   cluster_ids  N int32      — index into `centroids` for each sample.
#   timestamps   N float64    — unix epoch per sample; drives time decay.
#
# On disk: .npz with the four fields above. The legacy single-centroid
# format ({centroid, samples}) is loaded with cluster_ids all zero and
# fake-old timestamps so existing profiles keep working until they get
# re-saved (which happens on any mutation).
# ---------------------------------------------------------------------------


def _l2(v: np.ndarray) -> np.ndarray:
    n = float(np.linalg.norm(v))
    return v if n == 0.0 else v / n


def _l2_rows(m: np.ndarray) -> np.ndarray:
    """Row-wise L2-normalise an N×D matrix."""
    norms = np.linalg.norm(m, axis=1, keepdims=True)
    norms[norms == 0.0] = 1.0
    return m / norms


def _centroid(samples: np.ndarray) -> np.ndarray:
    """Simple L2-normalised mean. Used by the in-memory session-cluster
    state where multi-centroid + time-decay don't apply (clusters are
    per-session, single-voice by definition)."""
    return _l2(samples.mean(axis=0))


def _pick_k(n: int) -> int:
    """Number of centroids for a profile with N samples. Single centroid
    until we have enough samples to support more; capped at the env-tuned
    MAX_CENTROIDS so we don't over-split."""
    if n < PROFILE_SAMPLES_PER_CENTROID:
        return 1
    return min(PROFILE_MAX_CENTROIDS, max(1, n // PROFILE_SAMPLES_PER_CENTROID))


def _time_weights(timestamps: np.ndarray) -> np.ndarray:
    """exp(-(now - t) / TAU). Older samples get less weight in the
    centroid. Returns ones if decay is disabled (TAU <= 0)."""
    if PROFILE_TIME_DECAY_TAU_S <= 0:
        return np.ones_like(timestamps, dtype=np.float64)
    now = time.time()
    ages = np.maximum(0.0, now - timestamps)
    return np.exp(-ages / PROFILE_TIME_DECAY_TAU_S)


def _farthest_point_init(samples: np.ndarray, k: int) -> list[int]:
    """Pick K well-separated sample indices to seed k-means. Greedy:
    start with sample 0, then iteratively add the sample with the lowest
    max-cosine-similarity to the picked set. Robust on the unit sphere."""
    n = samples.shape[0]
    if k >= n:
        return list(range(n))
    seeds = [0]
    for _ in range(k - 1):
        sims = samples @ samples[seeds].T  # N×|seeds|
        max_sims = np.max(sims, axis=1)
        for s in seeds:
            max_sims[s] = np.inf  # exclude already-picked
        seeds.append(int(np.argmin(max_sims)))
    return seeds


def _kmeans(samples: np.ndarray, k: int) -> np.ndarray:
    """Spherical k-means on L2-normalised embeddings. Returns an int32
    array of cluster assignments (length N). Uses cosine (= dot product
    on the unit sphere) as the similarity."""
    n = samples.shape[0]
    if k <= 1 or n <= 1:
        return np.zeros(n, dtype=np.int32)
    if k >= n:
        # Each sample is its own cluster (degenerate but well-defined)
        return np.arange(n, dtype=np.int32)

    seed_idx = _farthest_point_init(samples, k)
    centroids = samples[seed_idx].copy()

    prev_assign: np.ndarray | None = None
    for _ in range(_KMEANS_MAX_ITERS):
        sims = samples @ centroids.T              # N×K cosine matrix
        assign = np.argmax(sims, axis=1).astype(np.int32)
        if prev_assign is not None and np.array_equal(assign, prev_assign):
            break
        # Recompute centroids as L2-normalised means of their members.
        # Empty clusters (rare with farthest-point init) keep stale value.
        for ci in range(k):
            mask = assign == ci
            if mask.any():
                m = samples[mask].mean(axis=0)
                norm = float(np.linalg.norm(m))
                if norm > 0:
                    centroids[ci] = (m / norm).astype(np.float32)
        prev_assign = assign

    return assign


def _compute_centroids(
    samples: np.ndarray,
    cluster_ids: np.ndarray,
    k: int,
    timestamps: np.ndarray | None = None,
) -> np.ndarray:
    """L2-normalised time-weighted mean per cluster. Cluster with no
    members gets a zero vector (won't match anything — fine)."""
    d = samples.shape[1]
    centroids = np.zeros((k, d), dtype=np.float32)
    weights = _time_weights(timestamps) if timestamps is not None else None
    for ci in range(k):
        mask = cluster_ids == ci
        if not mask.any():
            continue
        if weights is None:
            mean_vec = samples[mask].mean(axis=0)
        else:
            w = weights[mask].astype(np.float32)
            wsum = float(w.sum())
            if wsum <= 0:
                mean_vec = samples[mask].mean(axis=0)
            else:
                mean_vec = (samples[mask] * w[:, None]).sum(axis=0) / wsum
        norm = float(np.linalg.norm(mean_vec))
        if norm > 0:
            centroids[ci] = (mean_vec / norm).astype(np.float32)
    return centroids


def _rebuild_profile(
    samples: np.ndarray, timestamps: np.ndarray,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Cluster samples + compute centroids. Returns (centroids, cluster_ids,
    samples) — samples is returned for symmetry but unchanged."""
    n = samples.shape[0]
    k = _pick_k(n)
    cluster_ids = _kmeans(samples, k)
    # k might have been overridden by the degenerate case in _kmeans
    actual_k = int(cluster_ids.max()) + 1 if n > 0 else 1
    actual_k = max(actual_k, k)
    centroids = _compute_centroids(samples, cluster_ids, actual_k, timestamps)
    return centroids, cluster_ids, samples


profiles: dict[str, dict] = {}


def _load_all() -> None:
    profiles.clear()
    for path in PROFILES_DIR.glob("*.npz"):
        try:
            data = np.load(path)
            keys = set(data.files)
            samples = data["samples"].astype(np.float32)
            # Dimension guard: profiles are tied to the embedding model that
            # made them (256-D WeSpeaker vs 192-D TitaNet, etc.). A stale
            # profile after a model switch would crash every cosine with a
            # shape mismatch — skip it loudly instead; the user re-enrolls.
            if _extractor_dim and samples.shape[1] != _extractor_dim:
                print(
                    f"profile skipped (embedding-dim mismatch after model "
                    f"switch): {path.stem} has {samples.shape[1]}-D samples, "
                    f"model produces {_extractor_dim}-D — re-enroll with "
                    f"/profile add {path.stem}",
                    file=sys.stderr,
                )
                continue
            n = samples.shape[0]
            if "centroids" in keys:
                # New format with k centroids + per-sample metadata.
                profiles[path.stem] = {
                    "centroids": data["centroids"].astype(np.float32),
                    "samples": samples,
                    "cluster_ids": data["cluster_ids"].astype(np.int32),
                    "timestamps": data["timestamps"].astype(np.float64),
                    # Legacy files have no provenance — everything counts
                    # as AUTO until trusted samples arrive.
                    "sources": (data["sources"].astype(np.int8)
                                if "sources" in keys
                                else np.zeros(n, dtype=np.int8)),
                }
            else:
                # Legacy: single "centroid" key. Synthesise the new fields
                # with all samples in cluster 0 and a single old timestamp.
                # First mutation re-clusters into the new format.
                old_centroid = data["centroid"].astype(np.float32)
                profiles[path.stem] = {
                    "centroids": old_centroid[np.newaxis, :],
                    "samples": samples,
                    "cluster_ids": np.zeros(n, dtype=np.int32),
                    "timestamps": np.full(
                        n, time.time() - 30 * 24 * 3600, dtype=np.float64,
                    ),
                }
        except Exception as e:
            print(
                f"warning: failed to load profile {path}: {e}",
                file=sys.stderr,
            )
    # Even-older format: .npy with one embedding (1-sample profile).
    for path in PROFILES_DIR.glob("*.npy"):
        if path.stem in profiles:
            continue
        try:
            emb = _l2(np.load(path).astype(np.float32))
            profiles[path.stem] = {
                "centroids": emb[np.newaxis, :],
                "samples": emb[np.newaxis, :],
                "cluster_ids": np.zeros(1, dtype=np.int32),
                "timestamps": np.array(
                    [time.time() - 30 * 24 * 3600], dtype=np.float64,
                ),
            }
        except Exception as e:
            print(
                f"warning: failed to load legacy profile {path}: {e}",
                file=sys.stderr,
            )


def _save(name: str) -> None:
    p = profiles[name]
    np.savez(
        PROFILES_DIR / f"{name}.npz",
        centroids=p["centroids"],
        samples=p["samples"],
        cluster_ids=p["cluster_ids"],
        timestamps=p["timestamps"],
        sources=_profile_sources(p),
    )


# Raw enrollment audio, kept alongside the embedding profiles so a
# future embedding-model upgrade can RE-EMBED every profile from the
# exact audio that built it (embeddings are model-specific; without the
# audio, a model swap means re-enrolling everyone from scratch). Rolling
# cap per profile; 0 disables.
PROFILE_AUDIO_KEEP = int(os.environ.get("MEETINK_PROFILE_AUDIO_KEEP", "20"))


def _save_profile_audio(name: str, samples: np.ndarray,
                        src: "str | None" = None) -> None:
    if PROFILE_AUDIO_KEEP <= 0:
        return
    try:
        import wave
        d = PROFILES_DIR / "audio" / name
        d.mkdir(parents=True, exist_ok=True)
        clip = samples[: 16000 * 10]           # cap 10 s per snippet
        path = d / f"{int(time.time() * 1000)}.wav"
        with wave.open(str(path), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16000)
            w.writeframes(
                (np.clip(clip, -1.0, 1.0) * 32767).astype(np.int16).tobytes())
        # Manifest: which meeting/span each snippet came from, and under
        # which embedding model it was accepted — a future model swap
        # (or a poisoning investigation) can trace every retained sample.
        try:
            with open(d / "manifest.jsonl", "a", encoding="utf-8") as mf:
                mf.write(json.dumps({
                    "file": path.name,
                    "ts": round(time.time(), 1),
                    "src": src or "live-session",
                    "model": MODEL_PATH.stem,
                    "seconds": round(len(clip) / 16000.0, 1),
                }) + "\n")
        except OSError:
            pass
        stale = sorted(d.glob("*.wav"))[:-PROFILE_AUDIO_KEEP]
        for f in stale:
            f.unlink()
    except Exception as e:
        print(f"warning: profile audio save failed for {name}: {e}",
              file=sys.stderr)


def _move_profile_audio(src_name: str, dst_name: str) -> None:
    """Keep the audio dir in lockstep with profile renames (merge =
    move the snippets in; the rolling cap prunes on the next save)."""
    try:
        src = PROFILES_DIR / "audio" / src_name
        if not src.is_dir():
            return
        dst = PROFILES_DIR / "audio" / dst_name
        if not dst.exists():
            src.rename(dst)
        else:
            for f in src.glob("*.wav"):
                f.rename(dst / f.name)
            src.rmdir()
    except Exception:
        pass


def _canonical_profile_name(name: str) -> str:
    """The existing profile whose name matches case-insensitively, else
    the name as given. Assigning "ED" while "Ed" is enrolled must train
    "Ed": macOS's default filesystem is case-INsensitive, so ED.npz and
    Ed.npz are the same file and two in-memory profiles differing only
    by case silently overwrite each other on disk (field incident: the
    DOUG → Doug rename deleted the file it had just saved)."""
    low = name.lower()
    for existing in profiles:
        if existing.lower() == low:
            return existing
    return name


def _outlier_reject(name: str, new_emb_l2: np.ndarray) -> tuple[bool, float]:
    """Check whether `new_emb_l2` is too dissimilar from profile `name`'s
    existing centroids to be the same speaker. Returns (rejected, best_sim).
    No-op if the profile is new or empty."""
    if name not in profiles:
        return False, 1.0
    centroids = profiles[name]["centroids"]
    if centroids.shape[0] == 0:
        return False, 1.0
    sims = centroids @ new_emb_l2
    best_sim = float(np.max(sims))
    return best_sim < PROFILE_OUTLIER_FLOOR, best_sim


# --- Provenance (Sol review, tier 1) ---------------------------------------
#
# Every sample carries a source class: TRUSTED (manual enrollment, user
# assignment, segment harvest, rename merges of trusted data) vs AUTO
# (auto-train, sibling folds). Rules:
#   - eviction under the size cap removes AUTO samples first (oldest
#     first); the trusted core is never auto-removed,
#   - /prune never drops trusted samples,
#   - auto-train may add at most AUTO_TRAIN_SESSION_CAP samples per
#     profile per SESSION — the Judd poisoning (one mislabeled meeting's
#     auto-train made Allen the MAJORITY of Judd's profile) becomes
#     structurally impossible: a bad meeting tops out at a small
#     minority against any trusted core.
AUTO_TRAIN_SESSION_CAP = int(os.environ.get(
    "MEETINK_AUTO_TRAIN_SESSION_CAP", "8"))
_auto_session_count: dict[str, int] = {}


def _trusted_source(source: str) -> bool:
    return not source.startswith(("auto", "assign-sibling"))


def _profile_sources(p: dict) -> np.ndarray:
    """Per-sample provenance, defaulting legacy profiles to AUTO (0)."""
    src = p.get("sources")
    n = p["samples"].shape[0]
    if src is None or src.shape[0] != n:
        return np.zeros(n, dtype=np.int8)
    return src


def _cap_recent(
    samples: np.ndarray, timestamps: np.ndarray, sources: np.ndarray, n: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Cap to `n` rows, evicting AUTO samples oldest-first; the trusted
    core is only touched when it alone exceeds the cap.

    Returns contiguous copies (NOT slice views) so the oversized pre-cap array
    is released — a numpy view would keep its base alive and defeat the bound.
    Capping keeps every subsequent allocation the same size class, so the
    libmalloc MEDIUM magazine stops fragmenting (root cause of the RSS leak)."""
    total = samples.shape[0]
    if total <= n:
        return samples, timestamps, sources
    keep = np.ones(total, dtype=bool)
    over = total - n
    auto_idx = np.where(sources == 0)[0]
    evict = auto_idx[np.argsort(timestamps[auto_idx])][:over]
    keep[evict] = False
    over = int(keep.sum()) - n
    if over > 0:
        tr_idx = np.where(keep & (sources == 1))[0]
        evict = tr_idx[np.argsort(timestamps[tr_idx])][:over]
        keep[evict] = False
    return samples[keep].copy(), timestamps[keep].copy(), sources[keep].copy()


def _add_sample(
    name: str, embedding: np.ndarray, source: str = "manual",
) -> tuple[int, bool, float]:
    """Append a single sample to a profile. Re-clusters and re-saves.
    Returns (total_samples_after, accepted, best_sim_against_existing).

    `accepted = False` only when outlier rejection fires (sample's cosine
    against every existing centroid is below PROFILE_OUTLIER_FLOOR).
    Fresh profiles always accept.
    """
    new = _l2(embedding).astype(np.float32)
    rejected, best_sim = _outlier_reject(name, new)
    if rejected:
        print(
            f"outlier rejected: {name} "
            f"(best_sim={best_sim:.3f} < {PROFILE_OUTLIER_FLOOR}, "
            f"source={source})",
            file=sys.stderr,
        )
        existing_n = (
            profiles[name]["samples"].shape[0] if name in profiles else 0
        )
        return existing_n, False, best_sim

    now = time.time()
    trusted = np.int8(1 if _trusted_source(source) else 0)
    if name in profiles:
        all_samples = np.vstack([profiles[name]["samples"], new[None, :]])
        all_timestamps = np.concatenate(
            [profiles[name]["timestamps"], [now]]
        )
        all_sources = np.concatenate(
            [_profile_sources(profiles[name]), [trusted]]).astype(np.int8)
        all_samples, all_timestamps, all_sources = _cap_recent(
            all_samples, all_timestamps, all_sources, PROFILE_MAX_SAMPLES,
        )
    else:
        all_samples = new[None, :]
        all_timestamps = np.array([now], dtype=np.float64)
        all_sources = np.array([trusted], dtype=np.int8)

    centroids, cluster_ids, all_samples = _rebuild_profile(
        all_samples, all_timestamps,
    )
    profiles[name] = {
        "centroids": centroids,
        "samples": all_samples,
        "cluster_ids": cluster_ids,
        "timestamps": all_timestamps,
        "sources": all_sources,
    }
    _save(name)
    return all_samples.shape[0], True, best_sim


def _add_samples_bulk(
    name: str,
    embeddings: np.ndarray,
    source: str = "manual",
    skip_outliers: bool = True,
    sources_in: "np.ndarray | None" = None,
) -> tuple[int, int]:
    """Append M samples to a profile in one shot. Used by /session/assign
    (folding a cluster into a profile) and /session/rename (merging two
    profiles). Returns (added_count, rejected_count).

    Outlier filtering applies the same per-sample floor as /enroll, so a
    /session/assign of a cluster that *doesn't actually match* the target
    profile drops the off-voice samples instead of polluting the centroid.
    """
    if embeddings.shape[0] == 0:
        return 0, 0
    new = _l2_rows(embeddings).astype(np.float32)

    accepted_mask = np.ones(new.shape[0], dtype=bool)
    if skip_outliers and name in profiles:
        sims = new @ profiles[name]["centroids"].T  # M×K
        max_sims = np.max(sims, axis=1)
        accepted_mask = max_sims >= PROFILE_OUTLIER_FLOOR
        rejected_count = int((~accepted_mask).sum())
        if rejected_count:
            print(
                f"bulk outlier reject: {name} "
                f"dropped {rejected_count}/{new.shape[0]} "
                f"(source={source}, floor={PROFILE_OUTLIER_FLOOR})",
                file=sys.stderr,
            )
    else:
        rejected_count = 0

    accepted = new[accepted_mask]
    added = int(accepted.shape[0])
    if added == 0:
        return 0, rejected_count

    now = time.time()
    timestamps_new = np.full(added, now, dtype=np.float64)
    if sources_in is not None and sources_in.shape[0] == embeddings.shape[0]:
        sources_new = sources_in[accepted_mask].astype(np.int8)
    else:
        sources_new = np.full(
            added, 1 if _trusted_source(source) else 0, dtype=np.int8)
    if name in profiles:
        all_samples = np.vstack([profiles[name]["samples"], accepted])
        all_timestamps = np.concatenate(
            [profiles[name]["timestamps"], timestamps_new]
        )
        all_sources = np.concatenate(
            [_profile_sources(profiles[name]), sources_new]).astype(np.int8)
        all_samples, all_timestamps, all_sources = _cap_recent(
            all_samples, all_timestamps, all_sources, PROFILE_MAX_SAMPLES,
        )
    else:
        all_samples = accepted
        all_timestamps = timestamps_new
        all_sources = sources_new

    centroids, cluster_ids, all_samples = _rebuild_profile(
        all_samples, all_timestamps,
    )
    profiles[name] = {
        "centroids": centroids,
        "samples": all_samples,
        "cluster_ids": cluster_ids,
        "timestamps": all_timestamps,
        "sources": all_sources,
    }
    _save(name)
    return added, rejected_count


def _profile_tightness(p: dict) -> float:
    """Mean of (sample · best-centroid) across the profile's samples.
    1.0 = every sample sits exactly on a centroid (single-mode, very
    tight). 0.7 = samples spread across multiple modes; 0.5 or below
    typically means pollution from another speaker. Useful diagnostic
    when /identify keeps mis-routing — a low-tightness profile won't
    match its own speaker reliably either.
    """
    samples = p["samples"]
    if samples.shape[0] == 0:
        return 0.0
    sims = samples @ p["centroids"].T   # N×K cosine matrix
    return float(np.mean(np.max(sims, axis=1)))


def _profile_nearest(name: str, p: dict) -> dict | None:
    """Closest other profile by best-centroid-vs-best-centroid cosine.
    Surfaces "Mike's profile is 0.84 away from Ethan" — the proximate
    cause of cross-matching. Returns None when there's only one profile.
    """
    best_name: str | None = None
    best_sim = -1.0
    if p["centroids"].shape[0] == 0:
        return None
    for other_name, other in profiles.items():
        if other_name == name or other["centroids"].shape[0] == 0:
            continue
        cross = p["centroids"] @ other["centroids"].T
        sim = float(np.max(cross))
        if sim > best_sim:
            best_sim = sim
            best_name = other_name
    if best_name is None:
        return None
    return {"name": best_name, "sim": round(best_sim, 3)}


def _trim_profile(name: str, count: int) -> tuple[int, int]:
    """Drop the last `count` samples (and their metadata) from a profile,
    re-cluster, re-save. Returns (removed, remaining)."""
    p = profiles[name]
    n = p["samples"].shape[0]
    drop = min(count, n)
    new_samples = p["samples"][:-drop] if drop > 0 else p["samples"]
    new_timestamps = (
        p["timestamps"][:-drop] if drop > 0 else p["timestamps"]
    )
    remaining = new_samples.shape[0]
    centroids, cluster_ids, new_samples = _rebuild_profile(
        new_samples, new_timestamps,
    )
    profiles[name] = {
        "centroids": centroids,
        "samples": new_samples,
        "cluster_ids": cluster_ids,
        "timestamps": new_timestamps,
    }
    _save(name)
    return drop, remaining


_load_all()
print(
    f"loaded {len(profiles)} profile(s): "
    + (
        ", ".join(
            f"{k}({v['samples'].shape[0]}s/{v['centroids'].shape[0]}c)"
            for k, v in profiles.items()
        )
        or "(none)"
    ),
    file=sys.stderr,
)
print(
    f"profile tuning: max_centroids={PROFILE_MAX_CENTROIDS} "
    f"samples_per_centroid={PROFILE_SAMPLES_PER_CENTROID} "
    f"outlier_floor={PROFILE_OUTLIER_FLOOR} "
    f"time_decay_tau_days={PROFILE_TIME_DECAY_TAU_S / 86400:.0f}",
    file=sys.stderr,
)


# ---------------------------------------------------------------------------
# Audio + matching
# ---------------------------------------------------------------------------


def parse_wav(data: bytes) -> np.ndarray:
    """16-bit mono 16 kHz WAV → float32 [-1, 1]."""
    if len(data) < 44:
        raise ValueError("audio too short")
    return np.frombuffer(data[44:], dtype=np.int16).astype(np.float32) / 32768.0


def embed(samples: np.ndarray) -> np.ndarray:
    stream = extractor.create_stream()
    stream.accept_waveform(16000, samples)
    stream.input_finished()
    return np.asarray(extractor.compute(stream), dtype=np.float32)


def cosine(a: np.ndarray, b: np.ndarray) -> float:
    na = float(np.linalg.norm(a))
    nb = float(np.linalg.norm(b))
    if na == 0.0 or nb == 0.0:
        return 0.0
    return float(np.dot(a, b) / (na * nb))


def identify(emb: np.ndarray) -> dict:
    """Return {speaker, confidence, runner_up, runner_up_confidence}.

    `speaker` is None unless top match clears THRESHOLD AND beats runner-up
    by at least MARGIN. This biases toward "unknown" rather than guessing —
    avoiding the Bob-misidentified-as-Alex failure mode.
    """
    if not profiles:
        return {"speaker": None, "confidence": 0.0, "runner_up": None, "runner_up_confidence": 0.0}

    # Apply session whitelist if set. Profiles outside it are simply
    # invisible to this match — voices that resemble them fall through
    # to clustering (Speaker N) just like any other unknown speaker.
    candidates = profiles
    if session_whitelist is not None:
        candidates = {
            n: p for n, p in profiles.items() if n in session_whitelist
        }
        if not candidates:
            return {"speaker": None, "confidence": 0.0, "runner_up": None, "runner_up_confidence": 0.0}

    # Thin profiles are landmines: a 1-sample centroid is a single
    # utterance's fingerprint and matches near-random voices with high
    # confidence (field case: a 1-sample profile claimed a line in a
    # meeting its owner wasn't in). They stay enrolled and keep
    # accumulating samples via explicit assignment, but they don't get
    # to LABEL anyone until they have enough data to be trustworthy.
    min_id_samples = int(os.environ.get("MEETINK_IDENTIFY_MIN_SAMPLES", "6"))
    candidates = {
        n: p for n, p in candidates.items()
        if p["samples"].shape[0] >= min_id_samples
    }
    if not candidates:
        return {"speaker": None, "confidence": 0.0, "runner_up": None, "runner_up_confidence": 0.0}

    # Per-profile score is the cosine to the BEST-matching centroid (not
    # a mean across centroids). Multimodal voices — same person with
    # different recording conditions or mood — get their best mode used
    # for matching instead of averaging modes into the middle.
    emb_l2 = _l2(emb).astype(np.float32)
    sims = sorted(
        (
            (name, float(np.max(p["centroids"] @ emb_l2)))
            for name, p in candidates.items()
        ),
        key=lambda kv: kv[1],
        reverse=True,
    )
    top_name, top_sim = sims[0]
    second_name, second_sim = (sims[1] if len(sims) > 1 else (None, -1.0))

    # Single-candidate path: no runner-up to disambiguate against, so
    # the margin check is trivially satisfied. Require a higher absolute
    # floor instead — otherwise any voice that vaguely resembles the
    # only candidate confidently gets labeled (today's Mike-as-Ethan
    # failure mode). When two or more candidates exist, the standard
    # threshold + margin gates apply, *unless* the top two profiles
    # cross-match heavily (close-pair mode — see comment above the
    # settings dict).
    reason: str | None = None
    close_pair = False
    effective_margin = settings["margin"]
    top_p = candidates[top_name]
    # LOOSE profiles claim strangers: max-over-centroids scoring means a
    # diffuse sample cloud (low tightness — pollution, or 500 samples of
    # very varied capture conditions) has a wide acceptance radius. Ask
    # more of it: the threshold rises by the tightness deficit, capped.
    # Field case: a 500-sample tightness-0.73 profile claimed a brand-new
    # unenrolled voice; tight profiles (0.78+) are unaffected.
    tightness_bump = min(0.08, max(0.0, 0.78 - _profile_tightness(top_p)))
    eff_threshold = settings["threshold"] + tightness_bump
    if len(sims) == 1:
        accepted = top_sim >= settings["single_profile_floor"] + tightness_bump
        if not accepted:
            reason = "below_single_floor"
    else:
        # Compute centroid-vs-centroid cosine between the top two
        # profiles. When it's high, two real-different speakers sit
        # close in WeSpeaker space and the standard MARGIN cannot be
        # satisfied — drop to a smaller floor that lets the consistent
        # advantage carry the decision.
        runner_p = candidates[second_name]
        cross_sim = float(np.max(top_p["centroids"] @ runner_p["centroids"].T))
        close_pair = cross_sim >= settings["close_pair_threshold"]
        effective_margin = (
            settings["close_pair_margin"] if close_pair else settings["margin"]
        )
        if top_sim < eff_threshold:
            accepted = False
            reason = "below_threshold"
        elif (top_sim - second_sim) < effective_margin:
            accepted = False
            reason = (
                "below_close_pair_margin" if close_pair else "below_margin"
            )
        else:
            accepted = True
    # IMPOSTOR test (whitelist only): the whitelist narrows who can be
    # NAMED, but every enrolled profile still competes as evidence. If a
    # profile outside the whitelist matches this voice nearly as well as
    # the winner, the match is "sounds like several people", not
    # identity — exactly how a guest gets labeled as someone's loose
    # near-neighbor. Near-duplicates of the winner (centroid cross-sim
    # >= close_pair_threshold) don't count as impostors.
    if accepted and session_whitelist is not None:
        best_imp = -1.0
        best_imp_name = None
        for iname, ip in profiles.items():
            if iname in candidates or ip["samples"].shape[0] < 3:
                continue
            cross = float(np.max(top_p["centroids"] @ ip["centroids"].T))
            if cross >= settings["close_pair_threshold"]:
                continue
            s_imp = float(np.max(ip["centroids"] @ emb_l2))
            if s_imp > best_imp:
                best_imp, best_imp_name = s_imp, iname
        if best_imp_name is not None                 and (top_sim - best_imp) < settings["margin"]:
            accepted = False
            reason = "impostor"
            print(
                f"identify reject: {top_name}@{top_sim:.3f} vs impostor "
                f"{best_imp_name}@{best_imp:.3f} gap="
                f"{top_sim - best_imp:.3f} < margin={settings['margin']}",
                file=sys.stderr,
            )
    # CONFIRMED-PRESENT rescue: the user assigned this profile during
    # THIS meeting, so the person is definitely in the room — a strong
    # prior the plain gates don't know about. Retry the failed gate with
    # a relaxed threshold (bounded) and half the margin. This is what
    # keeps a mid-call assignment from immediately minting fresh
    # "Speaker N" letters for the same voice.
    if not accepted and reason != "impostor" \
            and top_name in session_confirmed:
        relax = float(os.environ.get("MEETINK_DIARIZE_CONFIRMED_RELAX", "0.06"))
        if len(sims) == 1:
            rescued = top_sim >= max(
                settings["single_profile_floor"] + tightness_bump - relax,
                0.60)
        else:
            rescued = (
                top_sim >= max(eff_threshold - relax, 0.55)
                and (top_sim - second_sim) >= effective_margin * 0.5
            )
        if rescued:
            print(
                f"identify: {top_name}@{top_sim:.3f} accepted via "
                f"confirmed-present relaxation (was {reason})",
                file=sys.stderr,
            )
            accepted = True
            reason = "confirmed_relaxed"
    # Stderr-log every rejection with the gate that failed and the gap.
    # This is the missing diagnostic users have been hitting: their
    # enrolled person silently falls to Speaker N with no signal as to why.
    # `/diarize log` (tails the same file) now surfaces it.
    if not accepted:
        if reason == "below_single_floor":
            print(
                f"identify reject: {top_name} top_sim={top_sim:.3f} < "
                f"single_floor={settings['single_profile_floor']}",
                file=sys.stderr,
            )
        elif reason == "below_threshold":
            print(
                f"identify reject: {top_name} top_sim={top_sim:.3f} < "
                f"threshold={eff_threshold:.3f}"
                + (f" (loose profile: +{tightness_bump:.3f})"
                   if tightness_bump > 0 else ""),
                file=sys.stderr,
            )
        elif reason == "below_margin":
            print(
                f"identify reject: {top_name}@{top_sim:.3f} vs "
                f"{second_name}@{second_sim:.3f} gap="
                f"{top_sim - second_sim:.3f} < margin={settings['margin']}",
                file=sys.stderr,
            )
        elif reason == "below_close_pair_margin":
            print(
                f"identify reject: close-pair {top_name}@{top_sim:.3f} vs "
                f"{second_name}@{second_sim:.3f} gap="
                f"{top_sim - second_sim:.3f} < close_pair_margin="
                f"{settings['close_pair_margin']}",
                file=sys.stderr,
            )
    return {
        "speaker": top_name if accepted else None,
        "confidence": round(top_sim, 3),
        "runner_up": second_name,
        "runner_up_confidence": round(second_sim, 3) if second_sim > -1.0 else None,
        "reason": reason,
        "close_pair": close_pair,
    }


# ---------------------------------------------------------------------------
# Online clustering for unidentified embeddings
#
# When `identify()` doesn't match an enrolled profile, we keep the embedding
# in a per-session in-memory cluster pool. New embeddings join the closest
# existing cluster (cosine ≥ CLUSTER_THRESHOLD) or seed a new one. The cluster
# letter is the cluster id; the live transcript shows it as Speaker 1, Speaker 2, …
#
# Lettering is monotonic — never reused after a cluster is assigned/merged
# away. So the user's mental model "A was Alice" stays valid for the rest of
# the session even if cluster A gets converted to the Alice profile mid-meeting.
# ---------------------------------------------------------------------------

clusters: list[dict] = []  # each: {"letter": str, "centroid": 1×D, "samples": ≤CLUSTER_MAX_SAMPLES×D}
_next_cluster_idx: int = 0

# Hard cap on samples retained per session cluster. _cluster_or_create appends
# a row on EVERY unmatched /identify; an uncapped np.vstack grew the matrix
# without bound and the monotonic-growth realloc churn fragmented libmalloc's
# MEDIUM magazine — the confirmed cause of the ~44 GB / 5-day RSS leak. A small
# recent-window cap keeps the cluster centroid stable (it converges well before
# 64 samples) while making every allocation the same size class, so the heap
# stops fragmenting. Override via MEETINK_CLUSTER_MAX_SAMPLES.
CLUSTER_MAX_SAMPLES = int(os.environ.get("MEETINK_CLUSTER_MAX_SAMPLES", "64"))

# --- Splinter control -------------------------------------------------------
# Greedy per-chunk assignment against a fixed threshold shatters one real
# voice into many letters on multi-person calls: ~3 s windows of the same
# speaker routinely score below CLUSTER_THRESHOLD against their own cluster,
# and every miss seeds a fresh letter (observed: one speaker -> THEM-A..I in
# a 30-min 1:1). Two mechanisms — the same shape commercial live diarizers
# use — keep clusters coherent:
#
# 1. Sticky-speaker prior. Conversation is temporally sticky: the voice in
#    this chunk is overwhelmingly likely to be the voice from the previous
#    chunk. A near-miss (>= STICKY_THRESHOLD but < CLUSTER_THRESHOLD) against
#    the LAST-assigned cluster, within STICKY_WINDOW_S of that assignment,
#    stays on that letter instead of seeding a new one. A genuinely new voice
#    is unaffected: WeSpeaker cross-speaker cosine sits far below the sticky
#    floor (< ~0.4).
#
# 2. Retroactive merging. When two cluster centroids converge above
#    CLUSTER_MERGE_THRESHOLD, they were the same person all along (each
#    seeded from one noisy window) — fold the smaller into the larger and
#    record the alias. /identify returns the surviving letter from then on,
#    and the launcher rewrites the already-written transcript lines from
#    GET /session/aliases on /stop. Live labels are provisional; evidence
#    accumulates; earlier decisions get healed — same philosophy as Otter's
#    post-hoc re-clustering, scoped to what a per-chunk pipeline can do.
STICKY_THRESHOLD = float(os.environ.get("MEETINK_CLUSTER_STICKY_THRESHOLD", "0.58"))
STICKY_WINDOW_S = float(os.environ.get("MEETINK_CLUSTER_STICKY_WINDOW_S", "12"))
CLUSTER_MERGE_THRESHOLD = float(os.environ.get("MEETINK_CLUSTER_MERGE_THRESHOLD", "0.74"))
# A cluster with <= SMALL_MAX samples is one-or-two noisy windows, not a
# centroid estimate — one bad chunk that dodged both the join bar and the
# sticky prior. Requiring the full MERGE_THRESHOLD against such a "centroid"
# strands it as a permanent orphan letter, so small clusters merge at a
# lower bar. 0.60 stays far above WeSpeaker cross-speaker cosine (< ~0.4,
# the same calibration PROFILE_OUTLIER_FLOOR documents), so a genuinely
# different voice that spoke only once keeps its own letter.
CLUSTER_MERGE_SMALL_MAX = int(os.environ.get("MEETINK_CLUSTER_MERGE_SMALL_MAX", "2"))
CLUSTER_MERGE_SMALL_THRESHOLD = float(
    os.environ.get("MEETINK_CLUSTER_MERGE_SMALL_THRESHOLD", "0.60"))

_last_cluster_letter: str | None = None
_last_cluster_ts: float = 0.0
# loser letter -> surviving letter, kept transitively resolved (values are
# always live cluster letters, never other losers).
cluster_aliases: dict[str, str] = {}


def _touch_sticky(letter: str) -> None:
    global _last_cluster_letter, _last_cluster_ts
    _last_cluster_letter = letter
    _last_cluster_ts = time.time()


def _resolve_alias(letter: str) -> str:
    """Map a possibly-merged-away letter to its surviving cluster letter."""
    return cluster_aliases.get(letter, letter)


# --- Session journal (Sol review, tier 1) -----------------------------------
#
# Every session-cluster mutation appends one JSON line; on boot the
# server replays the journal since the last "start" event, so a restart
# mid-day no longer loses the session's voice data (the operational rule
# "only restart between meetings" existed purely because this state was
# memory-only — it cost two enrollment opportunities in one day).
SESSION_JOURNAL = MK_HOME / "session-journal.jsonl"
_journal_replaying = False


def _journal(ev: dict) -> None:
    if _journal_replaying:
        return
    try:
        with open(SESSION_JOURNAL, "a", encoding="utf-8") as f:
            f.write(json.dumps(ev) + "\n")
    except OSError:
        pass


def _journal_reset() -> None:
    if _journal_replaying:
        return
    try:
        with open(SESSION_JOURNAL, "w", encoding="utf-8") as f:
            f.write(json.dumps({"ev": "start", "ts": time.time()}) + "\n")
    except OSError:
        pass


def _replay_session_journal() -> None:
    """Rebuild clusters / aliases / confirmed set from the journal. Runs
    once at boot, before the HTTP server starts. Profile mutations are
    NOT replayed — those already persisted to their npz files; an
    "assign" event only replays the cluster removal + confirmation."""
    global _journal_replaying, _next_cluster_idx
    try:
        lines = SESSION_JOURNAL.read_text(encoding="utf-8").splitlines()
    except OSError:
        return
    _journal_replaying = True
    try:
        obs = 0
        for line in lines:
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            kind = ev.get("ev")
            if kind == "start":
                clusters.clear()
                cluster_aliases.clear()
                session_confirmed.clear()
                _auto_session_count.clear()
                _next_cluster_idx = 0
                obs = 0
            elif kind == "new":
                emb = np.asarray(ev.get("emb") or [], dtype=np.float32)
                if emb.size == 0:
                    continue
                clusters.append({
                    "letter": str(ev.get("letter")),
                    "centroid": _l2(emb),
                    "samples": _l2(emb)[np.newaxis, :],
                })
                try:
                    _next_cluster_idx = max(_next_cluster_idx,
                                            int(ev.get("letter")))
                except (TypeError, ValueError):
                    pass
                obs += 1
            elif kind == "add":
                emb = np.asarray(ev.get("emb") or [], dtype=np.float32)
                c = _find_cluster(str(ev.get("letter")))
                if c is not None and emb.size:
                    _add_to_cluster(c, emb)
                    obs += 1
            elif kind == "merge":
                loser = _find_cluster(str(ev.get("loser")))
                winner = _find_cluster(str(ev.get("winner")))
                if loser is not None and winner is not None:
                    combined = np.vstack([winner["samples"],
                                          loser["samples"]])
                    if combined.shape[0] > CLUSTER_MAX_SAMPLES:
                        combined = combined[-CLUSTER_MAX_SAMPLES:].copy()
                    winner["samples"] = combined
                    winner["centroid"] = _centroid(combined)
                    clusters.remove(loser)
                _record_alias(str(ev.get("loser")), str(ev.get("winner")))
            elif kind == "assign":
                c = _find_cluster(str(ev.get("letter")))
                if c is not None:
                    clusters.remove(c)
                name = ev.get("name")
                if name:
                    session_confirmed.add(str(name))
        if clusters or obs:
            print(f"session journal replayed: {len(clusters)} cluster(s), "
                  f"{obs} observation(s), "
                  f"{len(session_confirmed)} confirmed",
                  file=sys.stderr)
    finally:
        _journal_replaying = False


def _record_alias(loser: str, winner: str) -> None:
    global _last_cluster_letter
    # Keep the map transitively flat: anything that resolved to the loser
    # now resolves to the winner (C->B recorded, then B loses to A: C->A).
    for k, v in list(cluster_aliases.items()):
        if v == loser:
            cluster_aliases[k] = winner
    cluster_aliases[loser] = winner
    if _last_cluster_letter == loser:
        _last_cluster_letter = winner
    _journal({"ev": "merge", "loser": loser, "winner": winner})


def _add_to_cluster(cluster: dict, emb: np.ndarray) -> None:
    _journal({"ev": "add", "letter": cluster["letter"],
              "emb": [round(float(x), 4) for x in _l2(emb)]})
    new_samples = np.vstack([cluster["samples"], _l2(emb)[np.newaxis, :]])
    # Cap to the most-recent CLUSTER_MAX_SAMPLES rows. .copy() so the
    # pre-cap array is released — see CLUSTER_MAX_SAMPLES (leak history).
    if new_samples.shape[0] > CLUSTER_MAX_SAMPLES:
        new_samples = new_samples[-CLUSTER_MAX_SAMPLES:].copy()
    cluster["samples"] = new_samples
    cluster["centroid"] = _centroid(new_samples)


def _maybe_merge_clusters() -> None:
    """Fold together any cluster pair whose centroids exceed
    CLUSTER_MERGE_THRESHOLD. Called after every sample add (the only time
    centroids move). Loops until no pair qualifies — a merge moves the
    winner's centroid, which can bring a third cluster into range."""
    merged = True
    while merged:
        merged = False
        for i in range(len(clusters)):
            for j in range(i + 1, len(clusters)):
                a, b = clusters[i], clusters[j]
                sim = cosine(a["centroid"], b["centroid"])
                small = min(a["samples"].shape[0], b["samples"].shape[0]) \
                    <= CLUSTER_MERGE_SMALL_MAX
                bar = CLUSTER_MERGE_SMALL_THRESHOLD if small \
                    else CLUSTER_MERGE_THRESHOLD
                if sim < bar:
                    continue
                # More samples wins (more evidence behind its centroid);
                # ties go to the earlier letter.
                winner, loser = (a, b) if (
                    a["samples"].shape[0] >= b["samples"].shape[0]
                ) else (b, a)
                combined = np.vstack([winner["samples"], loser["samples"]])
                if combined.shape[0] > CLUSTER_MAX_SAMPLES:
                    combined = combined[-CLUSTER_MAX_SAMPLES:].copy()
                winner["samples"] = combined
                winner["centroid"] = _centroid(combined)
                clusters.remove(loser)
                _record_alias(loser["letter"], winner["letter"])
                print(
                    f"cluster merge: {loser['letter']} -> {winner['letter']} "
                    f"(centroid sim={sim:.3f}, "
                    f"combined={combined.shape[0]} samples)",
                    file=sys.stderr,
                )
                merged = True
                break
            if merged:
                break


def _letter_for(idx: int) -> str:
    """0→"1", 1→"2", … (monotonic, never reused). Cluster ids are 1-based
    speaker numbers; the live transcript renders them as "Speaker <n>".
    (Historically these were letters — THEM-A/B/C — hence the function
    name, kept to avoid churn at the call sites.)"""
    return str(idx + 1)


def _new_cluster(emb: np.ndarray) -> dict:
    global _next_cluster_idx
    letter = _letter_for(_next_cluster_idx)
    _next_cluster_idx += 1
    _journal({"ev": "new", "letter": letter,
              "emb": [round(float(x), 4) for x in _l2(emb)]})
    cluster = {
        "letter": letter,
        "centroid": _l2(emb),
        "samples": _l2(emb)[np.newaxis, :],
    }
    clusters.append(cluster)
    return cluster


def _cluster_or_create(emb: np.ndarray) -> tuple[str, float]:
    """Find closest cluster ≥ CLUSTER_THRESHOLD; else give the LAST-assigned
    cluster a discounted second chance (sticky-speaker prior); else seed a
    new one. Returns (letter, similarity_to_chosen_cluster_centroid)."""
    if clusters:
        best = max(clusters, key=lambda c: cosine(emb, c["centroid"]))
        sim = cosine(emb, best["centroid"])
        if sim >= settings["cluster_threshold"]:
            _add_to_cluster(best, emb)
            _touch_sticky(best["letter"])
            _maybe_merge_clusters()
            return _resolve_alias(best["letter"]), round(sim, 3)
        # Sticky prior: below the normal join bar, but the previous chunk's
        # speaker gets a lower one — people don't change mid-sentence.
        if _last_cluster_letter is not None and \
                time.time() - _last_cluster_ts <= STICKY_WINDOW_S:
            last = _find_cluster(_last_cluster_letter)
            if last is not None:
                sim_last = cosine(emb, last["centroid"])
                if sim_last >= STICKY_THRESHOLD:
                    _add_to_cluster(last, emb)
                    _touch_sticky(last["letter"])
                    _maybe_merge_clusters()
                    return _resolve_alias(last["letter"]), round(sim_last, 3)
    cluster = _new_cluster(emb)
    _touch_sticky(cluster["letter"])
    return cluster["letter"], 1.0  # similarity to itself


def _find_cluster(letter: str) -> dict | None:
    for c in clusters:
        if c["letter"] == letter:
            return c
    return None


def _find_cluster_by_ref(ref: str) -> dict | None:
    """Resolve a cluster from any spelling the user has in front of them:
    a bare id ("3"), the transcript label ("Speaker 3"), or — for clusters
    loaded from the refine pass — the assigned label itself ("GREG",
    "ADRIANA 2"). Makes RE-assignment of an already-named speaker work."""
    ref = (ref or "").strip()
    if not ref:
        return None
    up = ref.upper()
    m = re.match(r"^SPEAKER\s+(\S+)$", up)
    ids = [up]
    if m:
        ids.append(m.group(1))
    for cand in ids:
        c = _find_cluster(_resolve_alias(cand))
        if c is not None:
            return c
    for c in clusters:
        if (c.get("label") or "").upper() == up:
            return c
    return None


def session_clear() -> None:
    """Reset clusters and the lettering counter. Called on /start."""
    global _next_cluster_idx, _last_cluster_letter, _last_cluster_ts
    _journal_reset()
    clusters.clear()
    _next_cluster_idx = 0
    cluster_aliases.clear()
    session_confirmed.clear()
    _auto_session_count.clear()
    _borderline_pending["name"] = None
    _borderline_pending["ts"] = 0.0
    _last_cluster_letter = None
    _last_cluster_ts = 0.0
    # Auto-train log is a per-session counter; resetting it on /start
    # makes the footer chip honestly track THIS recording's activity.
    _auto_train_log.clear()
    # Recent-embedding ring is also per-session; carrying it across
    # /start would let /profile train adopt audio from a previous call.
    _recent_embeddings.clear()


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------


class Handler(BaseHTTPRequestHandler):
    def _json(self, status: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt: str, *args) -> None:
        return  # quiet — main.swift logs hits separately

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/":
            now = time.time()
            recent_60s = [e for e in _auto_train_log if now - e["ts"] <= 60]
            last = _auto_train_log[-1] if _auto_train_log else None
            self._json(200, {
                "status": "ok",
                "profiles": list(profiles.keys()),
                "threshold": settings["threshold"],
                "margin": settings["margin"],
                "cluster_threshold": settings["cluster_threshold"],
                "single_profile_floor": settings["single_profile_floor"],
                "preset": settings_preset,
                "clusters": len(clusters),
                "whitelist": session_whitelist,
                "auto_train_total": len(_auto_train_log),
                "auto_train_recent_60s": len(recent_60s),
                "auto_train_last": (
                    {
                        "name": last["name"],
                        "age_s": round(now - last["ts"], 1),
                    } if last else None
                ),
            })
            return
        if path.startswith("/profiles/") and path.endswith("/diagnose"):
            # Query values are auto-decoded by parse_qs; path segments are NOT —
            # "Test%202" must become "Test 2" before the profiles lookup.
            name = unquote(path[len("/profiles/"):-len("/diagnose")]).strip()
            if not name or name not in profiles:
                self._json(404, {"error": f"no profile named {name}"})
                return
            p = profiles[name]
            # Per-centroid sample distribution (which sub-cluster each
            # sample belongs to). Useful when figuring out whether the
            # profile is uni-modal or has splintered into noticeable
            # voice modes (e.g. headset vs laptop mic).
            cluster_ids = p["cluster_ids"]
            samples_per_centroid: list[int] = []
            for ci in range(p["centroids"].shape[0]):
                samples_per_centroid.append(int((cluster_ids == ci).sum()))
            # All cross-profile similarities, not just the nearest. Sorted
            # descending so the worst cross-match offenders surface first.
            cross: list[dict] = []
            for other_name, other in profiles.items():
                if other_name == name:
                    continue
                sim = float(np.max(p["centroids"] @ other["centroids"].T))
                cross.append({"name": other_name, "sim": round(sim, 3)})
            cross.sort(key=lambda kv: kv["sim"], reverse=True)
            # Auto-train events targeting this profile
            now = time.time()
            recent_auto = [
                {
                    "ts": e["ts"],
                    "age_s": round(now - e["ts"], 1),
                    "confidence": e.get("confidence"),
                }
                for e in _auto_train_log if e["name"] == name
            ]
            self._json(200, {
                "name": name,
                "samples": int(p["samples"].shape[0]),
                "centroids": int(p["centroids"].shape[0]),
                "samples_per_centroid": samples_per_centroid,
                "tightness": round(_profile_tightness(p), 3),
                "cross_similarities": cross,
                "auto_train_events": recent_auto,
                "whitelist_member": (
                    session_whitelist is None or name in session_whitelist
                ),
            })
            return
        if path == "/session/auto-train-recent":
            now = time.time()
            self._json(200, {
                "events": [
                    {**e, "age_s": round(now - e["ts"], 1)}
                    for e in _auto_train_log[-20:]
                ],
                "total": len(_auto_train_log),
            })
            return
        if path == "/profiles":
            def _file_times(n: str) -> tuple[float, float]:
                """(created, updated) from the npz — birthtime survives
                every in-place rewrite, mtime moves with each _save."""
                for ext in (".npz", ".npy"):
                    fp = PROFILES_DIR / f"{n}{ext}"
                    try:
                        st = fp.stat()
                        return (float(getattr(st, "st_birthtime", st.st_mtime)),
                                float(st.st_mtime))
                    except OSError:
                        continue
                return (0.0, 0.0)
            def _entry(n: str, p: dict) -> dict:
                created, updated = _file_times(n)
                ts = p["timestamps"]
                return {
                    "name": n,
                    "samples": int(p["samples"].shape[0]),
                    "trusted": int((_profile_sources(p) == 1).sum()),
                    "centroids": int(p["centroids"].shape[0]),
                    "tightness": round(_profile_tightness(p), 3),
                    "nearest": _profile_nearest(n, p),
                    "created": created,
                    "updated": updated,
                    # Newest sample's own timestamp — differs from file
                    # mtime when a rename/prune rewrote the file without
                    # adding voice data.
                    "samples_updated": float(ts.max()) if ts.size else 0.0,
                }
            self._json(200, {
                "profiles": [_entry(n, p) for n, p in profiles.items()]
            })
            return
        if path == "/session/sensitivity":
            self._json(200, {
                "preset": settings_preset,
                "threshold": settings["threshold"],
                "margin": settings["margin"],
                "cluster_threshold": settings["cluster_threshold"],
                "single_profile_floor": settings["single_profile_floor"],
                "close_pair_threshold": settings["close_pair_threshold"],
                "close_pair_margin": settings["close_pair_margin"],
                "available": list(PRESETS.keys()),
            })
            return
        if path == "/session/auto-train":
            self._json(200, dict(auto_train_settings))
            return
        if path == "/session/whitelist":
            self._json(200, {
                "whitelist": session_whitelist,
                "profiles_known": list(profiles.keys()),
            })
            return
        if path == "/session/clusters":
            self._json(200, {
                "clusters": [
                    {"letter": c["letter"], "samples": int(c["samples"].shape[0])}
                    for c in clusters
                ]
            })
            return
        if path == "/profiles/centroids":
            # Raw centroid vectors for every enrolled profile, plus the
            # active matching thresholds. Lets an OFFLINE diarizer (the
            # import/refine pass) do global clustering + profile matching
            # itself — statelessly, without touching this server's live
            # session clusters. Payload: ~3 centroids x 256 floats per
            # profile — trivial.
            self._json(200, {
                "profiles": {
                    name: p["centroids"].tolist()
                    for name, p in profiles.items()
                },
                "settings": dict(settings),
            })
            return
        if path == "/session/aliases":
            # Retroactive merges this session: loser letter -> surviving
            # letter (transitively flattened). The launcher reads this on
            # /stop to rewrite already-written Speaker <loser> transcript lines.
            self._json(200, {"aliases": dict(cluster_aliases)})
            return
        self._json(404, {"error": "not found"})

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length)
        url = urlparse(self.path)
        try:
            if url.path == "/embed":
                # Stateless embedding: WAV in, 256-D vector out. No session
                # mutation, no clustering, no auto-train — the offline
                # diarizer (imports) builds its own global view from these.
                samples = parse_wav(body)
                if len(samples) < 16000:  # < 1 s is unreliable
                    self._json(200, {"embedding": None, "reason": "too_short"})
                    return
                vec = embed(samples)
                self._json(200, {"embedding": vec.tolist()})
                return
            if url.path == "/identify":
                samples = parse_wav(body)
                if len(samples) < 16000:  # < 1 second is unreliable
                    self._json(200, {"speaker": None, "confidence": 0.0, "reason": "too_short"})
                    return
                emb = embed(samples)
                # Push into the recent-embedding ring before any matching so
                # /session/adopt-last works even when identify returns None
                # (the user wants to /profile train an unmatched voice).
                _push_recent_embedding(emb)
                result = identify(emb)
                resp = dict(result)
                # Non-mutating probe (?mutate=0) — the capture's mic-guest
                # check: no clustering, no auto-train, no hysteresis
                # state. Mic audio must never mint session clusters.
                if parse_qs(url.query).get("mutate", ["1"])[0] == "0":
                    self._json(200, resp)
                    return
                # Borderline hysteresis (see _borderline_pending). Skips
                # session-confirmed names — the user vouched for them.
                # CLOSE-PAIR decisions that only passed via the lowered
                # close-pair margin defer the same way (Sol review: two
                # hard-to-distinguish voices deserve MORE evidence, not
                # less — a 0.03 one-window advantage becomes a name only
                # when the same candidate wins twice in a row).
                _conf = resp.get("confidence") or 0.0
                _gap = _conf - (resp.get("runner_up_confidence") or 0.0)
                _thin_close_pair = bool(resp.get("close_pair")) \
                    and _gap < settings["margin"]
                if resp["speaker"] is not None \
                        and resp["speaker"] not in session_confirmed \
                        and (_conf < settings["threshold"] + BORDERLINE_BAND
                             or _thin_close_pair):
                    now_ts = time.time()
                    same_recent = (
                        _borderline_pending["name"] == resp["speaker"]
                        and now_ts - _borderline_pending["ts"] <= 45.0
                    )
                    _borderline_pending["name"] = resp["speaker"]
                    _borderline_pending["ts"] = now_ts
                    if not same_recent:
                        print(
                            f"identify defer: {resp['speaker']}@"
                            f"{resp.get('confidence')} "
                            + ("close-pair thin margin"
                               if _thin_close_pair else "borderline")
                            + " — needs a second consecutive window",
                            file=sys.stderr,
                        )
                        resp["deferred"] = resp["speaker"]
                        resp["speaker"] = None
                        resp["reason"] = "borderline_pending"
                if resp["speaker"] is None:
                    # No profile match — assign to a cluster so the live
                    # transcript still distinguishes voices.
                    letter, sim = _cluster_or_create(emb)
                    resp["cluster"] = letter
                    resp["cluster_confidence"] = sim
                    # PENDING BIRTH: one observation is not a durable
                    # identity — a laugh, an interjection, or a blended
                    # window must not mint a visible "Speaker N" (the
                    # 37-speakers tail was born here). The first window
                    # of a brand-new cluster displays as THEM; the letter
                    # goes public only when a SECOND observation lands in
                    # the same cluster. Singletons stay THEM and the
                    # offline pass owns them.
                    c = _find_cluster(letter)
                    if c is not None and c["samples"].shape[0] < 2:
                        resp["speaker"] = "THEM"
                        resp["pending_cluster"] = letter
                    else:
                        resp["speaker"] = f"Speaker {letter}"
                else:
                    # High-confidence profile match → fold the embedding
                    # back into the profile if the auto-train guardrails
                    # all pass. The guardrails (floor / margin multiplier
                    # / min-samples) make this conservative on purpose;
                    # the cost of polluting a profile is much higher
                    # than the cost of skipping a marginal match.
                    runner_up = resp.get("runner_up_confidence") or 0.0
                    if _maybe_auto_train(
                        emb,
                        resp["speaker"],
                        resp.get("confidence") or 0.0,
                        runner_up,
                    ):
                        resp["auto_trained"] = True
                        _save_profile_audio(resp["speaker"], samples)
                        print(
                            f"auto-train: {resp['speaker']} += sample "
                            f"(confidence={resp.get('confidence')}, "
                            f"runner_up={runner_up}, "
                            f"total={profiles[resp['speaker']]['samples'].shape[0]})",
                            file=sys.stderr,
                        )
                    # Transcript display convention: enrolled names appear
                    # uppercased, matching the mic-side ME/<NAME> labels.
                    # Done server-side (after auto-train, which needs the raw
                    # profile-dict key) so the capture client writes the
                    # label verbatim — cluster labels stay "Speaker N".
                    resp["speaker"] = str(resp["speaker"]).upper()
                self._json(200, resp)
                return
            if url.path == "/session/cluster/clear":
                # Remove ONE cluster (vs /session/clear which wipes all).
                # Use when a cluster has been contaminated with two voices
                # so future /identify calls form fresh clusters per voice.
                qs = parse_qs(url.query)
                letter = (qs.get("letter", [""])[0]).strip().upper()
                if not letter:
                    self._json(400, {"error": "need ?letter=A"})
                    return
                cluster = _find_cluster(letter)
                if cluster is None:
                    self._json(404, {"error": f"no cluster named {letter}"})
                    return
                samples = int(cluster["samples"].shape[0])
                clusters.remove(cluster)
                print(
                    f"session: cluster {letter} cleared ({samples} samples)",
                    file=sys.stderr,
                )
                self._json(200, {
                    "ok": True, "letter": letter, "cleared_samples": samples,
                })
                return
            if url.path == "/session/cluster/split":
                # Split one cluster into K via k-means on its samples.
                # The original letter keeps the largest sub-cluster; the
                # remaining sub-clusters get fresh letters allocated from
                # _next_cluster_idx. Useful when a cluster has fused two
                # similar-sounding speakers (strict sensitivity should
                # prevent this, but vocally similar people can still slip
                # through).
                qs = parse_qs(url.query)
                letter = (qs.get("letter", [""])[0]).strip().upper()
                try:
                    k = int(qs.get("k", ["2"])[0])
                except ValueError:
                    self._json(400, {"error": "k must be an integer"})
                    return
                if not letter or k < 2:
                    self._json(400, {"error": "need ?letter=A and k >= 2"})
                    return
                cluster = _find_cluster(letter)
                if cluster is None:
                    self._json(404, {"error": f"no cluster named {letter}"})
                    return
                n = int(cluster["samples"].shape[0])
                if n < k * 2:
                    self._json(400, {
                        "error": (
                            f"cluster {letter} has only {n} samples; "
                            f"need ≥ {k * 2} to split into {k}"
                        ),
                    })
                    return

                assignments = _kmeans(cluster["samples"], k)
                # Find the largest sub-cluster — it keeps the original
                # letter so existing transcript lines stay consistent.
                sub_sizes = [int((assignments == i).sum()) for i in range(k)]
                keeper_sub = int(np.argmax(sub_sizes))

                new_letters: list[str] = []
                global _next_cluster_idx
                # Re-assign each sub-cluster
                old_samples = cluster["samples"]
                for sub_i in range(k):
                    mask = assignments == sub_i
                    sub_samples = old_samples[mask]
                    if sub_samples.shape[0] == 0:
                        continue
                    sub_centroid = _centroid(sub_samples)
                    if sub_i == keeper_sub:
                        # Mutate the original cluster in place
                        cluster["samples"] = sub_samples
                        cluster["centroid"] = sub_centroid
                    else:
                        # Allocate a fresh letter
                        new_letter = _letter_for(_next_cluster_idx)
                        _next_cluster_idx += 1
                        clusters.append({
                            "letter": new_letter,
                            "centroid": sub_centroid,
                            "samples": sub_samples,
                        })
                        new_letters.append(new_letter)

                print(
                    f"session: cluster {letter} split into "
                    f"{[letter] + new_letters} "
                    f"(sizes: {[sub_sizes[keeper_sub]] + [sub_sizes[i] for i in range(k) if i != keeper_sub]})",
                    file=sys.stderr,
                )
                self._json(200, {
                    "ok": True,
                    "letter": letter,
                    "new_letters": new_letters,
                    "sizes": [sub_sizes[keeper_sub]] + [
                        sub_sizes[i] for i in range(k) if i != keeper_sub
                    ],
                })
                return
            if url.path == "/session/adopt-last":
                # Grab the most recent /identify embedding from the ring
                # and append it to profile `name`. This is the mid-meeting
                # /profile train path — the embedding came from the system
                # audio stream (the call), so it actually represents the
                # other speaker's voice rather than the user's mic.
                qs = parse_qs(url.query)
                name = (qs.get("name", [""])[0]).strip()
                try:
                    age_max = float(qs.get("age_max_s", ["20"])[0])
                except ValueError:
                    self._json(400, {"error": "age_max_s must be a number"})
                    return
                if not name:
                    self._json(400, {"error": "need ?name=Mike"})
                    return
                if "/" in name or "\\" in name or name.startswith("."):
                    self._json(400, {"error": "invalid name (no slashes or dots)"})
                    return
                now = time.time()
                fresh = [e for e in _recent_embeddings if now - e["ts"] <= age_max]
                if not fresh:
                    self._json(404, {
                        "error": (
                            "no_recent_embeddings — no /identify within "
                            f"{age_max:.0f}s. Is a recording in flight?"
                        ),
                    })
                    return
                latest = fresh[-1]
                count, accepted, best_sim = _add_sample(
                    name, latest["emb"], source="adopt-last",
                )
                if not accepted:
                    self._json(200, {
                        "ok": False,
                        "rejected": "outlier",
                        "name": name,
                        "samples": count,
                        "best_sim": round(best_sim, 3),
                        "floor": PROFILE_OUTLIER_FLOOR,
                    })
                    return
                age = now - latest["ts"]
                print(
                    f"adopt-last: {name} += sample "
                    f"(age={age:.1f}s, total={count}, "
                    f"best_sim={best_sim:.3f})",
                    file=sys.stderr,
                )
                self._json(200, {
                    "ok": True,
                    "name": name,
                    "samples": count,
                    "age_s": round(age, 1),
                    "best_sim": round(best_sim, 3),
                })
                return
            if url.path == "/session/clear":
                session_clear()
                print("session: clusters cleared", file=sys.stderr)
                self._json(200, {"ok": True})
                return
            if url.path == "/session/load":
                # Replace the session's cluster state with the refine pass's
                # final analysis: {"clusters": [{"label": str,
                # "embeddings": [[...], ...]}, ...]}. After this, post-call
                # assignment (app click-to-name, /profile assign) folds
                # THESE embeddings into profiles — the offline analysis is
                # no longer discarded at the end of the refine.
                try:
                    payload = json.loads(body.decode("utf-8"))
                except (ValueError, UnicodeDecodeError):
                    self._json(400, {"error": "invalid JSON body"})
                    return
                incoming = payload.get("clusters") or []
                session_clear()
                loaded = 0
                for item in incoming:
                    embs = item.get("embeddings") or []
                    rows = []
                    for e in embs:
                        v = np.asarray(e, dtype=np.float32)
                        if _extractor_dim and v.shape[-1] != _extractor_dim:
                            continue
                        rows.append(_l2(v))
                    if not rows:
                        continue
                    M = np.stack(rows)[:CLUSTER_MAX_SAMPLES]
                    c = _new_cluster(M[0])
                    c["samples"] = M
                    c["centroid"] = _l2(M.mean(axis=0))
                    c["label"] = str(item.get("label") or "").strip() or None
                    loaded += 1
                print(f"session: loaded {loaded} refine clusters "
                      f"(replaces live session state)", file=sys.stderr)
                self._json(200, {"ok": True, "clusters": loaded})
                return
            if url.path == "/session/assign":
                qs = parse_qs(url.query)
                letter = (qs.get("cluster", [""])[0]).strip().upper()
                name = (qs.get("name", [""])[0]).strip()
                if not letter or not name:
                    self._json(400, {"error": "need ?cluster=A&name=Alice"})
                    return
                if "/" in name or "\\" in name or name.startswith("."):
                    self._json(400, {"error": "invalid name (no slashes or dots)"})
                    return
                # Accept a bare id, "Speaker 3", or a refine-assigned
                # label ("GREG") — and follow merge aliases. This is what
                # lets an already-named speaker be re-assigned.
                cluster = _find_cluster_by_ref(letter)
                if cluster is None:
                    self._json(404, {"error": f"no cluster named {letter}",
                                     "no_cluster": True})
                    return
                letter = cluster["letter"]
                # "ED" folds into the enrolled "Ed", never a twin profile.
                name = _canonical_profile_name(name)
                # Promote the cluster's samples to the profile via
                # _add_samples_bulk so outlier rejection + k-means kick
                # in. Re-assigning into an existing profile accumulates
                # voice data; the outlier floor drops any cluster samples
                # that clearly don't match the target's centroids (catches
                # the failure mode where /profile assign A flavio is run
                # on a cluster that's actually a different speaker).
                added, rejected = _add_samples_bulk(
                    name, cluster["samples"],
                    source=f"assign:{letter}",
                    # First-time profile creation: nothing to be outlier
                    # vs, so skip the check on `name not in profiles`.
                    skip_outliers=(name in profiles),
                )
                clusters.remove(cluster)
                # The user just confirmed this person is IN the meeting —
                # identify() relaxes its gates for them from here on.
                session_confirmed.add(name)
                _journal({"ev": "assign", "letter": letter, "name": name})
                # Sibling fold: the same voice often spawned OTHER
                # anonymous letters before the assignment (each hard
                # window minted a new one). Any remaining cluster whose
                # centroid strongly matches the updated profile is the
                # same person — fold it too and report its letter so the
                # caller can rewrite those transcript labels as well.
                also_folded: list[str] = []
                fold_bar = settings["threshold"] + 0.03
                prof_centroids = profiles[name]["centroids"]
                for c in list(clusters):
                    sim = float(np.max(prof_centroids @ _l2(c["centroid"])))
                    if sim >= fold_bar:
                        _add_samples_bulk(
                            name, c["samples"],
                            source=f"assign-sibling:{c['letter']}",
                            skip_outliers=True,
                        )
                        clusters.remove(c)
                        also_folded.append(c["letter"])
                        _journal({"ev": "assign", "letter": c["letter"],
                                  "name": name})
                        print(
                            f"session: sibling cluster {c['letter']} → "
                            f"{name} (sim={sim:.3f})",
                            file=sys.stderr,
                        )
                        prof_centroids = profiles[name]["centroids"]
                total = int(profiles[name]["samples"].shape[0])
                print(
                    f"session: cluster {letter} → profile {name} "
                    f"(+{added} samples, {rejected} outliers rejected, "
                    f"total={total})",
                    file=sys.stderr,
                )
                self._json(200, {
                    "ok": True,
                    "cluster": letter,
                    "name": name,
                    "samples": total,
                    "added": added,
                    "rejected": rejected,
                    "also_folded": also_folded,
                })
                return
            if url.path == "/session/merge":
                qs = parse_qs(url.query)
                src_letter = (qs.get("from", [""])[0]).strip().upper()
                dst_letter = (qs.get("into", [""])[0]).strip().upper()
                if not src_letter or not dst_letter:
                    self._json(400, {"error": "need ?from=A&into=B"})
                    return
                if src_letter == dst_letter:
                    self._json(400, {"error": "from and into must differ"})
                    return
                src = _find_cluster(src_letter)
                dst = _find_cluster(dst_letter)
                if src is None or dst is None:
                    self._json(404, {"error": "unknown cluster letter"})
                    return
                merged = np.vstack([dst["samples"], src["samples"]])
                if merged.shape[0] > CLUSTER_MAX_SAMPLES:
                    merged = merged[-CLUSTER_MAX_SAMPLES:].copy()
                dst["samples"] = merged
                dst["centroid"] = _centroid(merged)
                clusters.remove(src)
                # Manual merges get the same alias bookkeeping as automatic
                # ones, so the /stop transcript consolidation covers both.
                _record_alias(src_letter, dst_letter)
                count = int(merged.shape[0])
                print(f"session: cluster {src_letter} merged into {dst_letter} ({count} samples)", file=sys.stderr)
                self._json(200, {
                    "ok": True,
                    "from": src_letter,
                    "into": dst_letter,
                    "samples": count,
                })
                return
            if url.path == "/session/whitelist":
                qs = parse_qs(url.query)
                global session_whitelist
                if qs.get("clear", [""])[0].lower() in ("1", "true", "yes"):
                    session_whitelist = None
                    print("session: whitelist cleared", file=sys.stderr)
                    self._json(200, {"ok": True, "whitelist": None})
                    return
                raw = qs.get("profiles", [""])[0].strip()
                if not raw:
                    self._json(400, {
                        "error": "need ?profiles=alex,stacey or ?clear=true",
                    })
                    return
                requested = [n.strip() for n in raw.split(",") if n.strip()]
                # Filter to profiles we actually know about. Unknown names
                # are reported back so the caller can warn.
                known = [n for n in requested if n in profiles]
                unknown = [n for n in requested if n not in profiles]
                session_whitelist = known
                print(
                    f"session: whitelist set to {known} "
                    f"(unknown ignored: {unknown})",
                    file=sys.stderr,
                )
                self._json(200, {
                    "ok": True,
                    "whitelist": known,
                    "unknown": unknown,
                })
                return
            if url.path == "/session/auto-train":
                qs = parse_qs(url.query)
                changed: dict = {}
                if "enabled" in qs:
                    v = qs["enabled"][0].strip().lower()
                    auto_train_settings["enabled"] = v in (
                        "1", "true", "yes", "on",
                    )
                    changed["enabled"] = auto_train_settings["enabled"]
                if "floor" in qs:
                    try:
                        f = float(qs["floor"][0])
                    except ValueError:
                        self._json(400, {"error": "floor must be a number"})
                        return
                    if not (0.0 <= f <= 1.0):
                        self._json(400, {"error": "floor must be between 0 and 1"})
                        return
                    auto_train_settings["floor"] = f
                    changed["floor"] = f
                if "margin_multiplier" in qs:
                    try:
                        m = float(qs["margin_multiplier"][0])
                    except ValueError:
                        self._json(400, {
                            "error": "margin_multiplier must be a number",
                        })
                        return
                    if m < 0:
                        self._json(400, {
                            "error": "margin_multiplier must be >= 0",
                        })
                        return
                    auto_train_settings["margin_multiplier"] = m
                    changed["margin_multiplier"] = m
                if "min_samples" in qs:
                    try:
                        n = int(qs["min_samples"][0])
                    except ValueError:
                        self._json(400, {
                            "error": "min_samples must be an integer",
                        })
                        return
                    if n < 1:
                        self._json(400, {
                            "error": "min_samples must be >= 1",
                        })
                        return
                    auto_train_settings["min_samples"] = n
                    changed["min_samples"] = n
                if "tightness_floor" in qs:
                    try:
                        t = float(qs["tightness_floor"][0])
                    except ValueError:
                        self._json(400, {
                            "error": "tightness_floor must be a number",
                        })
                        return
                    if not (0.0 <= t <= 1.0):
                        self._json(400, {
                            "error": "tightness_floor must be between 0 and 1",
                        })
                        return
                    auto_train_settings["tightness_floor"] = t
                    changed["tightness_floor"] = t
                if not changed:
                    self._json(400, {
                        "error": (
                            "no settings provided — pass at least one of "
                            "?enabled=&floor=&margin_multiplier=&min_samples="
                            "&tightness_floor="
                        ),
                    })
                    return
                print(f"auto-train updated: {changed}", file=sys.stderr)
                self._json(200, {
                    "ok": True,
                    "changed": changed,
                    **dict(auto_train_settings),
                })
                return
            if url.path == "/session/sensitivity":
                qs = parse_qs(url.query)
                mode = (qs.get("mode", [""])[0]).strip().lower()
                if not mode:
                    self._json(400, {"error": "need ?mode=focused|default|strict"})
                    return
                if mode not in PRESETS:
                    self._json(400, {
                        "error": f"unknown mode '{mode}'",
                        "available": list(PRESETS.keys()),
                    })
                    return
                # Mutate in place so existing dict references stay live.
                # Each consumer reads via dict lookup at call time, so
                # the next /identify hits the new values immediately.
                preset = PRESETS[mode]
                settings["threshold"] = preset["threshold"]
                settings["margin"] = preset["margin"]
                settings["cluster_threshold"] = preset["cluster_threshold"]
                global settings_preset
                settings_preset = mode
                print(
                    f"sensitivity: preset={mode} "
                    f"threshold={settings['threshold']} "
                    f"margin={settings['margin']} "
                    f"cluster_threshold={settings['cluster_threshold']}",
                    file=sys.stderr,
                )
                self._json(200, {
                    "ok": True,
                    "preset": mode,
                    "threshold": settings["threshold"],
                    "margin": settings["margin"],
                    "cluster_threshold": settings["cluster_threshold"],
                })
                return
            if url.path == "/session/rename":
                qs = parse_qs(url.query)
                src_name = (qs.get("from", [""])[0]).strip()
                dst_name = (qs.get("to", [""])[0]).strip()
                if not src_name or not dst_name:
                    self._json(400, {"error": "need ?from=alice&to=alex"})
                    return
                if src_name == dst_name:
                    self._json(400, {"error": "from and to must differ"})
                    return
                if any(c in dst_name for c in "/\\.."):
                    self._json(400, {"error": "invalid name (no slashes or dots)"})
                    return
                if src_name not in profiles:
                    self._json(404, {"error": f"no profile named {src_name}"})
                    return
                # Pure RECASE ("DOUG" → "Doug"): rekey in memory and
                # rewrite the (case-insensitively identical) file. The
                # generic path below deleted the file it had just saved,
                # because src.npz and dst.npz are the same file on a
                # case-insensitive filesystem.
                if src_name.lower() == dst_name.lower():
                    profiles[dst_name] = profiles.pop(src_name)
                    _move_profile_audio(src_name, dst_name)
                    # Unlink BEFORE saving: overwriting through the old
                    # name keeps the old on-disk casing, and _load_all
                    # keys by file stem — the recase would silently
                    # revert on the next server restart.
                    for ext in (".npz", ".npy"):
                        p = PROFILES_DIR / f"{src_name}{ext}"
                        try:
                            if p.exists():
                                p.unlink()
                        except OSError:
                            pass
                    _save(dst_name)
                    count = int(profiles[dst_name]["samples"].shape[0])
                    print(f"recased: {src_name} → {dst_name} "
                          f"({count} samples)", file=sys.stderr)
                    self._json(200, {
                        "ok": True, "from": src_name, "to": dst_name,
                        "samples": count, "merged": False, "rejected": 0,
                    })
                    return
                # Renaming ONTO an enrolled name matches case-insensitively
                # too — "ed" merges into "Ed", never a twin profile.
                dst_name = _canonical_profile_name(dst_name)
                src_samples = profiles[src_name]["samples"]
                src_timestamps = profiles[src_name]["timestamps"]
                merged_into_existing = dst_name in profiles
                rejected = 0
                if merged_into_existing:
                    # Fold via _add_samples_bulk so outlier rejection +
                    # k-means kick in. This is exactly the FLAVIO/BOB
                    # failure path — folding samples from a *different*
                    # speaker would have polluted the destination
                    # centroid. Now: each src sample is checked against
                    # dst's centroids; ones that clearly don't match get
                    # dropped with a per-source log line.
                    _, rejected = _add_samples_bulk(
                        dst_name, src_samples,
                        source=f"rename:{src_name}",
                        skip_outliers=True,
                        sources_in=_profile_sources(profiles[src_name]),
                    )
                else:
                    # Pure rename: rekey, preserving all metadata. No
                    # outlier check (nothing to compare against).
                    profiles[dst_name] = profiles[src_name]
                    _save(dst_name)
                # Drop src from memory and disk regardless of which branch
                # — but NEVER delete dst's own file: on a case-insensitive
                # filesystem src.npz can resolve to the very file _save
                # just wrote for dst.
                profiles.pop(src_name, None)
                _move_profile_audio(src_name, dst_name)
                dst_file = PROFILES_DIR / f"{dst_name}.npz"
                for ext in (".npz", ".npy"):
                    p = PROFILES_DIR / f"{src_name}{ext}"
                    try:
                        if p.exists() and not (
                            dst_file.exists() and p.samefile(dst_file)
                        ):
                            p.unlink()
                    except OSError:
                        pass
                count = int(profiles[dst_name]["samples"].shape[0])
                print(
                    f"renamed: {src_name} → {dst_name} "
                    f"({count} samples, merged={merged_into_existing}, "
                    f"rejected={rejected})",
                    file=sys.stderr,
                )
                self._json(200, {
                    "ok": True,
                    "from": src_name,
                    "to": dst_name,
                    "samples": count,
                    "merged": merged_into_existing,
                    "rejected": rejected,
                })
                return
            if url.path.startswith("/profiles/") and url.path.endswith("/create"):
                # PLACEHOLDER profile: just the name, zero samples — so a
                # person can be named (and email-linked) before any voice
                # data exists. Invisible to /identify (the min-samples
                # gate already skips thin profiles); the first assign or
                # segment-harvest fills it in.
                name = unquote(
                    url.path[len("/profiles/"):-len("/create")]).strip()
                if not name or any(c in name for c in "/\\"):
                    self._json(400, {"error": "invalid name"})
                    return
                canonical = _canonical_profile_name(name)
                if canonical in profiles:
                    self._json(200, {"ok": True, "name": canonical,
                                     "existed": True})
                    return
                dim = _extractor_dim or 192
                profiles[name] = {
                    "centroids": np.zeros((0, dim), dtype=np.float32),
                    "samples": np.zeros((0, dim), dtype=np.float32),
                    "cluster_ids": np.zeros(0, dtype=np.int32),
                    "timestamps": np.zeros(0, dtype=np.float64),
                }
                _save(name)
                print(f"created placeholder profile: {name}", file=sys.stderr)
                self._json(200, {"ok": True, "name": name, "existed": False})
                return
            if url.path.startswith("/profiles/") and url.path.endswith("/prune"):
                # Profile hygiene: drop pollution that accumulated via
                # folds and auto-train. Two passes, then re-cluster:
                #   1. ORPHAN CENTROIDS — a centroid whose best sim to
                #      the profile's other centroids is under
                #      ?cluster_floor (default 0.55) while holding a
                #      MINORITY of the samples is another person folded
                #      in (same-voice modes sit closer than that;
                #      different people sit ~0.4-0.5 in titanet space).
                #   2. STRAY SAMPLES — anything scoring under
                #      ?sample_floor (default 0.45) against every
                #      centroid.
                name = unquote(
                    url.path[len("/profiles/"):-len("/prune")]).strip()
                if name not in profiles:
                    self._json(404, {"error": f"no profile named {name}"})
                    return
                qs = parse_qs(url.query)
                cluster_floor = float(qs.get("cluster_floor", ["0.55"])[0])
                sample_floor = float(qs.get("sample_floor", ["0.45"])[0])
                p = profiles[name]
                before_n = int(p["samples"].shape[0])
                before_tight = round(_profile_tightness(p), 3)
                keep = np.ones(before_n, dtype=bool)
                srcs = _profile_sources(p)
                cents = p["centroids"]
                cids = p["cluster_ids"]
                if cents.shape[0] > 1:
                    cross = cents @ cents.T
                    np.fill_diagonal(cross, -1.0)
                    counts = np.bincount(cids, minlength=cents.shape[0])
                    for ci in range(cents.shape[0]):
                        if float(np.max(cross[ci])) < cluster_floor \
                                and counts[ci] < counts.max():
                            keep &= cids != ci
                sims = p["samples"] @ cents.T
                keep &= np.max(sims, axis=1) >= sample_floor
                # The trusted core (manual/harvest provenance) is never
                # auto-removed — prune only clears machine-added samples.
                keep |= srcs == 1
                removed = before_n - int(keep.sum())
                if removed == 0:
                    self._json(200, {
                        "ok": True, "name": name, "removed": 0,
                        "samples": before_n, "tightness": before_tight,
                    })
                    return
                if not keep.any():
                    self._json(400, {"error": "prune would empty the "
                                     "profile — delete it instead"})
                    return
                new_samples = p["samples"][keep].copy()
                new_ts = p["timestamps"][keep].copy()
                new_src = srcs[keep].copy()
                centroids, cluster_ids, new_samples = _rebuild_profile(
                    new_samples, new_ts)
                profiles[name] = {
                    "centroids": centroids,
                    "samples": new_samples,
                    "cluster_ids": cluster_ids,
                    "timestamps": new_ts,
                    "sources": new_src,
                }
                _save(name)
                after_tight = round(_profile_tightness(profiles[name]), 3)
                print(
                    f"pruned: {name} -{removed} samples "
                    f"({before_n} → {int(keep.sum())}), tightness "
                    f"{before_tight} → {after_tight}",
                    file=sys.stderr,
                )
                self._json(200, {
                    "ok": True, "name": name, "removed": removed,
                    "samples": int(keep.sum()),
                    "tightness_before": before_tight,
                    "tightness_after": after_tight,
                })
                return
            if url.path.startswith("/profiles/") and url.path.endswith("/pop"):
                name = unquote(url.path[len("/profiles/"):-len("/pop")]).strip()
                if not name:
                    self._json(400, {"error": "missing profile name"})
                    return
                if name not in profiles:
                    self._json(404, {"error": f"no profile named {name}"})
                    return
                qs = parse_qs(url.query)
                try:
                    count = int(qs.get("count", ["1"])[0])
                except ValueError:
                    self._json(400, {"error": "count must be an integer"})
                    return
                if count < 1:
                    self._json(400, {"error": "count must be >= 1"})
                    return
                total = int(profiles[name]["samples"].shape[0])
                if count >= total:
                    self._json(400, {
                        "error": (
                            f"can't pop {count} of {total} — would empty "
                            f"the profile. Use DELETE /profiles/{name} "
                            f"instead."
                        ),
                    })
                    return
                removed, remaining = _trim_profile(name, count)
                print(
                    f"popped: {name} -{removed} sample(s), "
                    f"remaining={remaining}",
                    file=sys.stderr,
                )
                self._json(200, {
                    "ok": True,
                    "name": name,
                    "removed": removed,
                    "remaining": remaining,
                })
                return
            if url.path == "/enroll":
                qs = parse_qs(url.query)
                name = (qs.get("name", [""])[0]).strip()
                snippet_src = (qs.get("src", [""])[0]).strip() or None
                if not name:
                    self._json(400, {"error": "missing ?name=..."})
                    return
                if "/" in name or "\\" in name or name.startswith("."):
                    self._json(400, {"error": "invalid name (no slashes or dots)"})
                    return
                samples = parse_wav(body)
                if len(samples) < 16000 * 3:
                    self._json(400, {"error": "need >= 3s of audio"})
                    return
                name = _canonical_profile_name(name)
                count, accepted, best_sim = _add_sample(
                    name, embed(samples), source="enroll",
                )
                if not accepted:
                    # Outlier rejected. The sample's cosine vs every
                    # existing centroid was below PROFILE_OUTLIER_FLOOR
                    # — almost certainly a different voice slipped into
                    # the recording. Surface the score so the caller
                    # can show a helpful warning instead of silently
                    # dropping.
                    self._json(200, {
                        "ok": False,
                        "rejected": "outlier",
                        "name": name,
                        "samples": count,
                        "best_sim": round(best_sim, 3),
                        "floor": PROFILE_OUTLIER_FLOOR,
                    })
                    return
                _save_profile_audio(name, samples, src=snippet_src)
                print(
                    f"enrolled: {name} ({len(samples) / 16000:.1f}s, "
                    f"total={count}, best_sim={best_sim:.3f})",
                    file=sys.stderr,
                )
                self._json(200, {
                    "ok": True,
                    "name": name,
                    "samples": count,
                    "best_sim": round(best_sim, 3),
                })
                return
            self._json(404, {"error": "not found"})
        except Exception as e:
            self._json(500, {"error": str(e)})

    def do_DELETE(self) -> None:
        url = urlparse(self.path)
        if url.path.startswith("/profiles/"):
            name = unquote(url.path[len("/profiles/"):]).strip()
            removed = False
            for ext in (".npz", ".npy"):
                p = PROFILES_DIR / f"{name}{ext}"
                if p.exists():
                    p.unlink()
                    removed = True
            if removed:
                profiles.pop(name, None)
                try:
                    import shutil
                    shutil.rmtree(PROFILES_DIR / "audio" / name,
                                  ignore_errors=True)
                except Exception:
                    pass
                print(f"removed: {name}", file=sys.stderr)
                self._json(200, {"ok": True, "removed": name})
            else:
                self._json(404, {"error": f"no profile named {name}"})
            return
        self._json(404, {"error": "not found"})


def _parent_death_watchdog(poll_s: float = 5.0) -> None:
    """Exit when the owning REPL dies, so we never outlive `meetink`.

    The launcher starts us backgrounded + disowned and stops us via its
    EXIT/HUP/TERM trap (see src/lib/repl.sh). That covers terminal-close and
    SIGTERM. This watchdog is the belt-and-suspenders for the paths a trap
    can't reach — `kill -9` of the REPL, a panic, a power-edge crash.

    We watch MEETINK_OWNER_PID (the REPL's own pid, exported at REPL start),
    NOT our PPID: the Python REPL dispatches every slash command through a
    short-lived `bin/meetink` subprocess, so the process that actually
    spawned us exits within seconds by design and our PPID flips to launchd
    while the REPL is very much alive. (The original PPID-change version of
    this watchdog killed every REPL-started server ~5 s after boot.)

    Without an owner pid (bare-CLI `meetink diarize start`), there is no
    process whose lifetime we should track — run unmanaged, like pre-watchdog
    behaviour. Both REPLs export the variable, so the orphan-leak scenario
    this watchdog exists for (terminal closed, REPL gone) stays covered.
    """
    owner = os.environ.get("MEETINK_OWNER_PID", "")
    if not owner.isdigit():
        print(
            "diarize-server: no MEETINK_OWNER_PID — lifetime watchdog "
            "disabled (stop via /diarize stop)",
            file=sys.stderr,
        )
        return
    owner_pid = int(owner)
    while True:
        time.sleep(poll_s)
        try:
            os.kill(owner_pid, 0)  # signal 0 = liveness probe, no delivery
        except ProcessLookupError:
            print(
                f"diarize-server: owner (pid {owner_pid}) exited, "
                "shutting down",
                file=sys.stderr,
            )
            os._exit(0)
        except PermissionError:
            pass  # pid exists but isn't ours — still alive


# --- Per-model threshold calibration -----------------------------------------
#
# Every threshold default above was calibrated on WeSpeaker ResNet34's cosine
# distribution (same-voice ≳ 0.75, cross < 0.4). TitaNet-L (192-D) scores the
# SAME voice systematically lower (real-world same-voice ≈ 0.55-0.75, cross
# ≈ 0.05-0.35), so under WeSpeaker thresholds almost every chunk fails to
# join its own cluster: a one-hour meeting splintered into "Speaker 203"-
# style labels the day the model shipped. Recalibrate every default for the
# active model family, detected by embedding dimensionality. Explicit env
# vars always win — only unset knobs are rescaled. These TitaNet values are
# literature-informed estimates pending field calibration; all remain
# hot-tunable via /diarize sensitivity and env.
if _extractor_dim == 192:   # TitaNet family
    PRESETS.clear()
    PRESETS.update({
        "focused": {"threshold": 0.42, "margin": 0.10, "cluster_threshold": 0.40},
        "default": {"threshold": 0.48, "margin": 0.06, "cluster_threshold": 0.50},
        "strict":  {"threshold": 0.55, "margin": 0.08, "cluster_threshold": 0.58},
    })
    _preset = PRESETS.get(settings_preset, PRESETS["default"])
    for _k, _env, _v in [
        ("threshold", "MEETINK_DIARIZE_THRESHOLD", _preset["threshold"]),
        ("margin", "MEETINK_DIARIZE_MARGIN", _preset["margin"]),
        ("cluster_threshold", "MEETINK_DIARIZE_CLUSTER_THRESHOLD",
         _preset["cluster_threshold"]),
        ("single_profile_floor", "MEETINK_DIARIZE_SINGLE_FLOOR", 0.60),
        ("close_pair_threshold", "MEETINK_DIARIZE_CLOSE_PAIR_THRESHOLD", 0.60),
        ("close_pair_margin", "MEETINK_DIARIZE_CLOSE_PAIR_MARGIN", 0.03),
    ]:
        if _env not in os.environ:
            settings[_k] = _v
    if "MEETINK_AUTO_TRAIN_FLOOR" not in os.environ:
        auto_train_settings["floor"] = 0.68
    if "MEETINK_AUTO_TRAIN_TIGHTNESS_FLOOR" not in os.environ:
        auto_train_settings["tightness_floor"] = 0.55
    if "MEETINK_PROFILE_OUTLIER_FLOOR" not in os.environ:
        PROFILE_OUTLIER_FLOOR = 0.25
    if "MEETINK_CLUSTER_STICKY_THRESHOLD" not in os.environ:
        STICKY_THRESHOLD = 0.38
    if "MEETINK_CLUSTER_MERGE_THRESHOLD" not in os.environ:
        CLUSTER_MERGE_THRESHOLD = 0.55
    if "MEETINK_CLUSTER_MERGE_SMALL_THRESHOLD" not in os.environ:
        CLUSTER_MERGE_SMALL_THRESHOLD = 0.42
    print(
        "threshold calibration: titanet (192-D) — "
        f"threshold={settings['threshold']} "
        f"cluster={settings['cluster_threshold']} "
        f"merge={CLUSTER_MERGE_THRESHOLD} sticky={STICKY_THRESHOLD}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    _replay_session_journal()
    print(
        f"diarize-server ready on 127.0.0.1:{PORT} "
        f"(preset={settings_preset}, threshold={settings['threshold']}, "
        f"margin={settings['margin']}, "
        f"cluster_threshold={settings['cluster_threshold']})",
        file=sys.stderr,
    )
    threading.Thread(target=_parent_death_watchdog, daemon=True).start()
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
