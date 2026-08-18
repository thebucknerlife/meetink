/* C surface over WebRTC's AudioProcessing (AEC3) for the capture binary.
 *
 * The capture uniquely HAS the echo reference: the sys stream is exactly
 * what the speakers play. Feed it as the far end, run the mic through as
 * the near end, and speaker bleed never enters the transcription pipeline.
 *
 * All functions are thread-safe; feed_far and process_near may be called
 * from different queues (SCK delegate vs mic tap), matching WebRTC's own
 * render/capture threading model.
 */
#ifndef MEETINK_AEC_SHIM_H
#define MEETINK_AEC_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

/* One canceller instance at the given rate (mono float32 samples). */
void *mk_aec_create(int sample_rate);
void  mk_aec_destroy(void *handle);
/* Clear learned delay/filter state after an input/output route change. */
void  mk_aec_reset(void *handle);

/* Far-end (speaker/sys) audio. Any count; buffered into 10 ms frames. */
void  mk_aec_feed_far(void *handle, const float *samples, int count);

/* Near-end (mic) audio, cleaned IN PLACE. Output lags input by <10 ms
 * (the first call's head is zero-padded while the pipeline primes). */
void  mk_aec_process_near(void *handle, float *samples, int count);

#ifdef __cplusplus
}
#endif

#endif /* MEETINK_AEC_SHIM_H */
