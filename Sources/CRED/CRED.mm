#include "CRED.h"
#import <Foundation/Foundation.h>
#include <cstdlib>
#include <dispatch/dispatch.h>
#include <cstring>
#include <mutex>
#include <string>

#if __has_include("R3DSDK.h")
#include "R3DSDK.h"
#include "R3DSDKMetal.h"
#import <Metal/Metal.h>
using namespace R3DSDK;

namespace {
std::mutex gInitLock;
bool gInit = false;
bool gMetalInit = false;   // SDK initialisé avec Metal
}

int red_compiled(void) { return 1; }

int red_init(const char* libDir) {
    std::lock_guard<std::mutex> g(gInitLock);
    if (gInit) return 0;
    InitializeStatus st = InitializeSdk(libDir, OPTION_RED_METAL);
    if (st == ISInitializeOK) { gMetalInit = true; gInit = true; return 0; }
    FinalizeSdk();
    st = InitializeSdk(libDir, OPTION_RED_NONE);   // repli : décodage CPU seul
    if (st != ISInitializeOK) { FinalizeSdk(); return -1; }
    gInit = true;
    return 0;
}


// ---- Décodage GPU : décompression asynchrone multi-fils (CPU) puis dématriçage Metal ----
@interface REDGPU : NSObject
@property (nonatomic) id<MTLDevice> device;
@property (nonatomic) id<MTLCommandQueue> queue;
@end
@implementation REDGPU @end

namespace {
std::mutex gGpuLock;          // une file Metal, un décodeur asynchrone : une image GPU à la fois
REDGPU* gGpu = nil;
REDMetal* gMetal = nullptr;
EXT_METAL_API* gApi = nullptr;
AsyncDecoder* gAsync = nullptr;
bool gGpuTried = false, gGpuOK = false;

struct DecompressWait { dispatch_semaphore_t sem; DecodeStatus status; };
void onDecompressed(AsyncDecompressJob* item, DecodeStatus st) {
    auto* w = (DecompressWait*)item->PrivateData;
    w->status = st;
    dispatch_semaphore_signal(w->sem);
}

bool gpuReady() {   // appelé avec gGpuLock tenu
    if (gGpuTried) return gGpuOK;
    gGpuTried = true;
    if (!gMetalInit || getenv("KYNEDIT_RED_CPU")) return false;
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) return false;
        gGpu = [REDGPU new]; gGpu.device = dev; gGpu.queue = [dev newCommandQueue];
        gApi = new EXT_METAL_API();
        gMetal = new REDMetal(*gApi);
        int err = 0;
        if (gMetal->checkCompatibility(gGpu.queue, err) != REDMetal::Status_Ok) return false;
        gAsync = new AsyncDecoder();
        gAsync->Open(0);
    }
    gGpuOK = true;
    return true;
}

/// Décode une image sur le GPU (16 bits RVB entrelacé) puis la convertit en BGRA 8 bits. Retourne 0 si réussi.
int gpuDecode(Clip* clip, size_t frame, int scale, uint8_t* out, size_t width, size_t height) {
    std::lock_guard<std::mutex> g(gGpuLock);
    if (!gpuReady()) return -1;
    @autoreleasepool {
        VideoDecodeMode mode = scale == 0 ? DECODE_FULL_RES_PREMIUM : DECODE_HALF_RES_PREMIUM;
        AsyncDecompressJob job;
        job.Clip = clip; job.Mode = mode; job.VideoTrackNo = 0; job.VideoFrameNo = frame;
        size_t rawSize = AsyncDecoder::GetSizeBufferNeeded(job);
        if (rawSize == 0) return -2;
        void* raw = nullptr;
        if (posix_memalign(&raw, 16384, (rawSize + 16383) & ~(size_t)16383) != 0) return -3;
        DecompressWait wait{dispatch_semaphore_create(0), DSOutputBufferInvalid};
        job.OutputBuffer = raw; job.OutputBufferSize = rawSize; job.PrivateData = &wait; job.Callback = onDecompressed;
        job.OutputFrameMetadata = nullptr; job.AbortDecode = false;
        int result = -4;
        if (gAsync->DecodeForGpuSdk(job) == DSDecodeOK) {
            dispatch_semaphore_wait(wait.sem, DISPATCH_TIME_FOREVER);
            if (wait.status == DSDecodeOK) {
                ImageProcessingSettings ips;
                clip->GetDefaultImageProcessingSettings(ips);
                DebayerMetalJob* dj = gMetal->createDebayerJob();
                dj->imageProcessingSettings = &ips;
                dj->mode = mode;
                dj->pixelType = PixelType_16Bit_RGB_Interleaved;
                dj->raw_host_mem = raw;
                dj->raw_device_mem = [gGpu.device newBufferWithBytes:raw length:rawSize options:MTLResourceStorageModeShared];
                size_t outSize = DebayerMetalJob::ResultFrameSize(*dj);
                dj->output_device_mem_size = outSize;
                dj->output_device_mem = [gGpu.device newBufferWithLength:outSize options:MTLResourceStorageModeShared];
                int err = 0;
                if (dj->raw_device_mem && dj->output_device_mem && outSize >= width * height * 6 &&
                    gMetal->processAsync(gGpu.queue, dj, err) == REDMetal::Status_Ok) {
                    dj->completeAsync();
                    const uint16_t* src = (const uint16_t*)[dj->output_device_mem contents];
                    size_t n = width * height;
                    for (size_t i = 0; i < n; i++) {   // 16 bits RVB -> BGRA 8 bits (on garde les 8 bits de poids fort)
                        out[i * 4 + 0] = (uint8_t)(src[i * 3 + 2] >> 8);
                        out[i * 4 + 1] = (uint8_t)(src[i * 3 + 1] >> 8);
                        out[i * 4 + 2] = (uint8_t)(src[i * 3 + 0] >> 8);
                        out[i * 4 + 3] = 255;
                    }
                    result = 0;
                }
                dj->raw_device_mem = nil; dj->output_device_mem = nil; dj->imageProcessingSettings = nullptr;
                gMetal->releaseDebayerJob(dj);
            }
        }
        free(raw);
        return result;
    }
}
}  // namespace

int red_gpu_available(void) { std::lock_guard<std::mutex> g(gGpuLock); return gpuReady() ? 1 : 0; }

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
    if (scale <= 1 && gpuDecode(c->clip, (size_t)frame, scale, out, width, height) == 0) { *w = (uint32_t)width; *h = (uint32_t)height; return 0; }   // GPU d'abord, CPU en repli
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
int red_gpu_available(void) { return 0; }
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
