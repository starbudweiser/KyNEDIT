#include "CRED.h"
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>

#if __has_include("R3DSDK.h")
#include "R3DSDK.h"
using namespace R3DSDK;

namespace {
std::mutex gInitLock;
bool gInit = false;
}

int red_compiled(void) { return 1; }

int red_init(const char* libDir) {
    std::lock_guard<std::mutex> g(gInitLock);
    if (gInit) return 0;
    InitializeStatus st = InitializeSdk(libDir, OPTION_RED_NONE);
    if (st != ISInitializeOK) { FinalizeSdk(); return -1; }
    gInit = true;
    return 0;
}

struct REDClip {
    Clip* clip = nullptr;
    std::mutex lock;   // Timecode() et DecodeAudio() ne sont pas réentrants
};

REDClip* red_open(const char* path) {
    if (!gInit) return nullptr;
    auto* c = new REDClip();
    c->clip = new Clip();
    if (c->clip->LoadFrom(path) != LSClipLoaded) { red_close(c); return nullptr; }
    return c;
}

void red_close(REDClip* c) {
    if (!c) return;
    delete c->clip;
    delete c;
}

int red_info(REDClip* c, uint32_t* w, uint32_t* h, float* fps, uint64_t* frames) {
    if (!c) return -1;
    *w = (uint32_t)c->clip->Width(); *h = (uint32_t)c->clip->Height();
    *fps = c->clip->VideoAudioFramerate(); *frames = c->clip->VideoFrameCount();
    return *w > 0 && *h > 0 ? 0 : -2;
}

int red_timecode(REDClip* c, uint64_t frame, char* out, uint32_t cap) {
    if (!c) return -1;
    std::lock_guard<std::mutex> g(c->lock);
    const char* t = c->clip->Timecode((size_t)frame);
    if (!t) return -2;
    strncpy(out, t, cap - 1); out[cap - 1] = 0;
    return 0;
}

int red_camera(REDClip* c, char* out, uint32_t cap) {
    if (!c || !c->clip->MetadataExists(RMD_CAMERA_MODEL)) return -1;
    std::string s = c->clip->MetadataItemAsString(RMD_CAMERA_MODEL);
    strncpy(out, s.c_str(), cap - 1); out[cap - 1] = 0;
    return 0;
}

int red_decode(REDClip* c, uint64_t frame, int scale, uint8_t* out, uint32_t cap, uint32_t* w, uint32_t* h) {
    if (!c) return -1;
    static const VideoDecodeMode modes[4] = { DECODE_FULL_RES_PREMIUM, DECODE_HALF_RES_GOOD, DECODE_QUARTER_RES_GOOD, DECODE_EIGHT_RES_GOOD };
    if (scale < 0 || scale > 3) scale = 0;
    size_t div = (size_t)1 << scale;
    size_t width = c->clip->Width() / div, height = c->clip->Height() / div;
    size_t need = width * height * 4;
    if (need > cap) return -2;
    void* buf = nullptr;
    if (posix_memalign(&buf, 16, need + 16) != 0) return -3;   // le SDK exige un tampon aligné sur 16 octets
    VideoDecodeJob job;
    job.Mode = modes[scale];
    job.PixelType = PixelType_8Bit_BGRA_Interleaved;
    job.OutputBuffer = buf;
    job.OutputBufferSize = need;
    job.ImageProcessing = nullptr; job.HdrProcessing = nullptr; job.OutputFrameMetadata = nullptr;
    DecodeStatus st = c->clip->DecodeVideoFrame((size_t)frame, job);
    if (st == DSDecodeOK) { memcpy(out, buf, need); *w = (uint32_t)width; *h = (uint32_t)height; }
    free(buf);
    return st == DSDecodeOK ? 0 : -4;
}

int red_audio_info(REDClip* c, uint32_t* ch, uint32_t* rate, uint32_t* bits, uint64_t* samples) {
    if (!c) return -1;
    size_t n = c->clip->AudioChannelCount();
    if (n == 0) return -2;
    *ch = (uint32_t)n; *rate = 48000; *bits = 16; *samples = c->clip->AudioSampleCount();
    return *samples > 0 ? 0 : -3;
}

int64_t red_audio_read(REDClip* c, int64_t start, uint8_t* out, uint32_t cap, uint32_t maxSamples) {
    if (!c) return -1;
    size_t ch = c->clip->AudioChannelCount();
    if (ch == 0 || start < 0) return -2;
    std::lock_guard<std::mutex> g(c->lock);
    size_t want = maxSamples;
    size_t bytes = want * ch * 4;
    void* buf = nullptr;
    if (posix_memalign(&buf, 512, (bytes + 511) & ~(size_t)511) != 0) return -3;   // tampon aligné sur 512 octets, exigé par le SDK
    size_t samples = want;
    DecodeStatus st = c->clip->DecodeAudio((unsigned long long)start, &samples, buf, (bytes + 511) & ~(size_t)511);
    int64_t result = -4;
    if (st == DSDecodeOK && samples * ch * 2 <= cap) {
        const uint8_t* in = (const uint8_t*)buf;   // mots de 32 bits gros-boutistes, alignés sur le bit de poids fort
        for (size_t i = 0; i < samples * ch; i++) { out[i * 2] = in[i * 4 + 1]; out[i * 2 + 1] = in[i * 4]; }
        result = (int64_t)samples;
    }
    free(buf);
    return result;
}

#else   // compilé sans le SDK R3D : toutes les fonctions échouent proprement
int red_compiled(void) { return 0; }
int red_init(const char*) { return -1; }
REDClip* red_open(const char*) { return nullptr; }
void red_close(REDClip*) {}
int red_info(REDClip*, uint32_t*, uint32_t*, float*, uint64_t*) { return -1; }
int red_timecode(REDClip*, uint64_t, char*, uint32_t) { return -1; }
int red_camera(REDClip*, char*, uint32_t) { return -1; }
int red_decode(REDClip*, uint64_t, int, uint8_t*, uint32_t, uint32_t*, uint32_t*) { return -1; }
int red_audio_info(REDClip*, uint32_t*, uint32_t*, uint32_t*, uint64_t*) { return -1; }
int64_t red_audio_read(REDClip*, int64_t, uint8_t*, uint32_t, uint32_t) { return -1; }
#endif
