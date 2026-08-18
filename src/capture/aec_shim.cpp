// See aec_shim.h. Built by build_capture only when the vendored
// webrtc-audio-processing library is present (meetink aec install);
// the Swift side compiles its calls under -D MEETINK_AEC.

#include "aec_shim.h"

#include <algorithm>
#include <deque>
#include <mutex>
#include <vector>

#include <modules/audio_processing/include/audio_processing.h>

namespace {

struct Aec {
    webrtc::scoped_refptr<webrtc::AudioProcessing> apm;
    webrtc::StreamConfig stream;
    int frame;  // samples per 10 ms
    std::mutex mu;
    std::vector<float> farBuf;
    std::vector<float> nearBuf;
    std::deque<float> outBuf;
    int sampleRate;
};

bool configure(Aec *a, int sample_rate) {
    a->apm = webrtc::AudioProcessingBuilder().Create();
    if (!a->apm) return false;
    webrtc::AudioProcessing::Config cfg;
    cfg.echo_canceller.enabled = true;
    cfg.echo_canceller.mobile_mode = false;
    // Cancellation only — the rest of the pipeline (whisper's frontend,
    // offline enhance) owns denoise/gain; APM's extras would color the
    // audio twice.
    cfg.noise_suppression.enabled = false;
    cfg.gain_controller1.enabled = false;
    cfg.gain_controller2.enabled = false;
    cfg.high_pass_filter.enabled = false;
    a->apm->ApplyConfig(cfg);
    a->sampleRate = sample_rate;
    a->stream = webrtc::StreamConfig(sample_rate, 1);
    a->frame = sample_rate / 100;
    return true;
}

}  // namespace

extern "C" {

void *mk_aec_create(int sample_rate) {
    auto *a = new Aec();
    if (!configure(a, sample_rate)) { delete a; return nullptr; }
    return a;
}

void mk_aec_destroy(void *handle) {
    delete static_cast<Aec *>(handle);
}

void mk_aec_reset(void *handle) {
    auto *a = static_cast<Aec *>(handle);
    if (!a) return;
    std::lock_guard<std::mutex> lock(a->mu);
    a->farBuf.clear();
    a->nearBuf.clear();
    a->outBuf.clear();
    configure(a, a->sampleRate);
}

void mk_aec_feed_far(void *handle, const float *samples, int count) {
    auto *a = static_cast<Aec *>(handle);
    if (!a || count <= 0) return;
    std::lock_guard<std::mutex> lock(a->mu);
    a->farBuf.insert(a->farBuf.end(), samples, samples + count);
    const int F = a->frame;
    while (static_cast<int>(a->farBuf.size()) >= F) {
        float in[480], out[480];
        std::copy(a->farBuf.begin(), a->farBuf.begin() + F, in);
        a->farBuf.erase(a->farBuf.begin(), a->farBuf.begin() + F);
        const float *src = in;
        float *dst = out;
        a->apm->ProcessReverseStream(&src, a->stream, a->stream, &dst);
    }
}

void mk_aec_process_near(void *handle, float *samples, int count) {
    auto *a = static_cast<Aec *>(handle);
    if (!a || count <= 0) return;
    std::lock_guard<std::mutex> lock(a->mu);
    a->nearBuf.insert(a->nearBuf.end(), samples, samples + count);
    const int F = a->frame;
    while (static_cast<int>(a->nearBuf.size()) >= F) {
        float in[480], out[480];
        std::copy(a->nearBuf.begin(), a->nearBuf.begin() + F, in);
        a->nearBuf.erase(a->nearBuf.begin(), a->nearBuf.begin() + F);
        const float *src = in;
        float *dst = out;
        // Delay between feed_far and the acoustic echo's arrival is
        // AEC3's own problem — its delay estimator spans the device +
        // room path (50-300 ms in the field), so report 0 here.
        a->apm->set_stream_delay_ms(0);
        if (a->apm->ProcessStream(&src, a->stream, a->stream, &dst) == 0) {
            a->outBuf.insert(a->outBuf.end(), out, out + F);
        } else {
            a->outBuf.insert(a->outBuf.end(), in, in + F);
        }
    }
    // Deliver exactly `count` samples; zero-pad the head only while the
    // pipeline primes (first ~10 ms of the session).
    int have = static_cast<int>(a->outBuf.size());
    int deficit = count - have;
    if (deficit > 0) {
        std::fill(samples, samples + deficit, 0.0f);
        std::copy(a->outBuf.begin(), a->outBuf.end(), samples + deficit);
        a->outBuf.clear();
    } else {
        std::copy(a->outBuf.begin(), a->outBuf.begin() + count, samples);
        a->outBuf.erase(a->outBuf.begin(), a->outBuf.begin() + count);
    }
}

}  // extern "C"
