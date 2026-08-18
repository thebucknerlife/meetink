"""Shared capture-stem health checks for transcript and playback policy."""
from __future__ import annotations

from typing import Any

import numpy as np


def assess_mic_health(mic: np.ndarray, sys_: np.ndarray,
                      rate: int = 16000) -> dict[str, Any]:
    """Return a conservative verdict about whether the mic is usable.

    A quiet participant is not a failed mic: a real microphone still carries
    quantized room/device noise.  The hard failures we act on are a missing or
    badly truncated timeline, or a timeline made almost entirely of literal
    digital zeroes.  When sys is absent (an in-person recording), mic is the
    only source and length parity is not meaningful.
    """
    mic_n = int(len(mic))
    sys_n = int(len(sys_))
    mic_s = mic_n / max(1, rate)
    sys_s = sys_n / max(1, rate)
    reference_n = max(mic_n, sys_n)
    duration_coverage = mic_n / reference_n if reference_n else 0.0

    if mic_n:
        # One int16 LSB. This intentionally distinguishes a muted/zero-valued
        # device callback from ordinary quiet room tone without imposing a
        # speech-energy threshold.
        if np.issubdtype(mic.dtype, np.integer):
            nonzero = mic != 0
        else:
            nonzero = np.abs(mic) >= (1.0 / 32768.0)
        nonzero_fraction = float(np.mean(nonzero))
        block = max(1, rate)
        full = mic_n // block
        if full:
            active_blocks = np.any(
                nonzero[:full * block].reshape(full, block), axis=1)
            signal_block_fraction = float(np.mean(active_blocks))
        else:
            signal_block_fraction = 1.0 if nonzero_fraction else 0.0
    else:
        nonzero_fraction = 0.0
        signal_block_fraction = 0.0

    reason = "healthy"
    healthy = True
    if mic_n == 0:
        healthy, reason = False, "missing"
    elif sys_n >= rate * 5 and duration_coverage < 0.80:
        healthy, reason = False, "truncated"
    elif sys_n >= rate * 5 and (nonzero_fraction < 0.001
                                or signal_block_fraction < 0.01):
        healthy, reason = False, "digital-silence"

    return {
        "healthy": healthy,
        "reason": reason,
        "mic_seconds": round(mic_s, 3),
        "sys_seconds": round(sys_s, 3),
        "duration_coverage": round(duration_coverage, 4),
        "nonzero_fraction": round(nonzero_fraction, 6),
        "signal_block_fraction": round(signal_block_fraction, 4),
    }


def mic_health_summary(health: dict[str, Any]) -> str:
    return (
        f"mic {health['reason']} "
        f"({health['mic_seconds']:.1f}s/{health['sys_seconds']:.1f}s, "
        f"coverage {health['duration_coverage'] * 100:.1f}%)"
    )
