#include "CBRAW.h"
#include "BlackmagicRawAPI.h"
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <string>

namespace {

struct DecodeCtx {
    std::mutex m;
    std::condition_variable cv;
    bool done = false;
    HRESULT result = E_FAIL;
    uint8_t* out = nullptr;
    uint32_t capacity = 0;
    uint32_t width = 0, height = 0;
    BlackmagicRawResolutionScale scale = blackmagicRawResolutionScaleFull;

    void finish(HRESULT r) {
        std::lock_guard<std::mutex> g(m);
        result = r; done = true;
        cv.notify_all();
    }
};

bool sameIID(REFIID a, REFIID b) { return memcmp(&a, &b, sizeof(CFUUIDBytes)) == 0; }

class Callback : public IBlackmagicRawCallback {
public:
    void ReadComplete(IBlackmagicRawJob* job, HRESULT result, IBlackmagicRawFrame* frame) override {
        DecodeCtx* ctx = nullptr;
        job->GetUserData((void**)&ctx);
        if (!ctx) return;
        IBlackmagicRawJob* decode = nullptr;
        if (SUCCEEDED(result)) result = frame->SetResourceFormat(blackmagicRawResourceFormatBGRAU8);
        if (SUCCEEDED(result)) result = frame->SetResolutionScale(ctx->scale);
        if (SUCCEEDED(result)) result = frame->CreateJobDecodeAndProcessFrame(nullptr, nullptr, &decode);
        if (SUCCEEDED(result)) { decode->SetUserData(ctx); result = decode->Submit(); }
        if (decode) decode->Release();
        if (FAILED(result)) ctx->finish(result);
    }
    void ProcessComplete(IBlackmagicRawJob* job, HRESULT result, IBlackmagicRawProcessedImage* image) override {
        DecodeCtx* ctx = nullptr;
        job->GetUserData((void**)&ctx);
        if (!ctx) return;
        uint32_t w = 0, h = 0, size = 0; void* data = nullptr;
        if (SUCCEEDED(result)) result = image->GetWidth(&w);
        if (SUCCEEDED(result)) result = image->GetHeight(&h);
        if (SUCCEEDED(result)) result = image->GetResourceSizeBytes(&size);
        if (SUCCEEDED(result)) result = image->GetResource(&data);
        if (SUCCEEDED(result)) {
            if (size > ctx->capacity) result = E_OUTOFMEMORY;
            else { memcpy(ctx->out, data, size); ctx->width = w; ctx->height = h; }
        }
        ctx->finish(result);
    }
    void ReadAudioComplete(IBlackmagicRawJob*, HRESULT, IBlackmagicRawAudioBuffer*) override {}
    void DecodeComplete(IBlackmagicRawJob*, HRESULT) override {}
    void TrimProgress(IBlackmagicRawJob*, float) override {}
    void TrimComplete(IBlackmagicRawJob*, HRESULT) override {}
    void SidecarMetadataParseWarning(IBlackmagicRawClip*, CFStringRef, uint32_t, CFStringRef) override {}
    void SidecarMetadataParseError(IBlackmagicRawClip*, CFStringRef, uint32_t, CFStringRef) override {}
    void PreparePipelineComplete(void*, HRESULT) override {}
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, LPVOID* out) override {
        if (!out) return E_POINTER;
        if (sameIID(iid, IID_IBlackmagicRawCallback) || sameIID(iid, CFUUIDGetUUIDBytes(IUnknownUUID))) { *out = static_cast<IBlackmagicRawCallback*>(this); AddRef(); return S_OK; }
        *out = nullptr; return E_NOINTERFACE;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
    ULONG STDMETHODCALLTYPE Release() override { ULONG n = --refs; if (n == 0) delete this; return n; }
private:
    std::atomic<ULONG> refs{1};
};

std::string cfToUTF8(CFStringRef s) {
    if (!s) return {};
    char buf[512];
    if (CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8)) return buf;
    return {};
}

}  // namespace

struct BRAWClip {
    IBlackmagicRawFactory* factory = nullptr;
    IBlackmagicRaw* codec = nullptr;
    IBlackmagicRawClip* clip = nullptr;
    IBlackmagicRawClipAudio* audio = nullptr;
    Callback* callback = nullptr;
    std::mutex lock;   // un décodage à la fois par clip (le SDK parallélise lui-même)
};

BRAWClip* braw_open(const char* path, const char* frameworkDirs) {
    IBlackmagicRawFactory* factory = nullptr;
    std::string dirs = frameworkDirs ? frameworkDirs : "";
    size_t pos = 0;
    while (!factory && pos <= dirs.size()) {
        size_t next = dirs.find(':', pos);
        std::string dir = dirs.substr(pos, next == std::string::npos ? std::string::npos : next - pos);
        if (!dir.empty()) {
            CFStringRef cf = CFStringCreateWithCString(kCFAllocatorDefault, dir.c_str(), kCFStringEncodingUTF8);
            factory = CreateBlackmagicRawFactoryInstanceFromPath(cf);
            CFRelease(cf);
        }
        if (next == std::string::npos) break;
        pos = next + 1;
    }
    if (!factory) return nullptr;
    auto* c = new BRAWClip();
    c->factory = factory;
    CFStringRef file = CFStringCreateWithCString(kCFAllocatorDefault, path, kCFStringEncodingUTF8);
    bool ok = SUCCEEDED(factory->CreateCodec(&c->codec)) && SUCCEEDED(c->codec->OpenClip(file, &c->clip));
    CFRelease(file);
    if (ok) { c->callback = new Callback(); ok = SUCCEEDED(c->codec->SetCallback(c->callback)); }
    if (!ok) { braw_close(c); return nullptr; }
    c->clip->QueryInterface(IID_IBlackmagicRawClipAudio, (void**)&c->audio);   // absent : pas de piste audio
    return c;
}

void braw_close(BRAWClip* c) {
    if (!c) return;
    if (c->codec) c->codec->FlushJobs();
    if (c->audio) c->audio->Release();
    if (c->clip) c->clip->Release();
    if (c->codec) c->codec->Release();
    if (c->callback) c->callback->Release();
    if (c->factory) c->factory->Release();
    delete c;
}

int braw_info(BRAWClip* c, uint32_t* w, uint32_t* h, float* fps, uint64_t* frames) {
    if (!c) return -1;
    if (FAILED(c->clip->GetWidth(w)) || FAILED(c->clip->GetHeight(h)) || FAILED(c->clip->GetFrameRate(fps)) || FAILED(c->clip->GetFrameCount(frames))) return -2;
    return 0;
}

int braw_timecode(BRAWClip* c, uint64_t frame, char* out, uint32_t cap) {
    CFStringRef s = nullptr;
    if (!c || FAILED(c->clip->GetTimecodeForFrame(frame, &s))) return -1;
    std::string t = cfToUTF8(s);
    strncpy(out, t.c_str(), cap - 1); out[cap - 1] = 0;
    return 0;
}

int braw_camera(BRAWClip* c, char* out, uint32_t cap) {
    CFStringRef s = nullptr;
    if (!c || FAILED(c->clip->GetCameraType(&s))) return -1;
    std::string t = cfToUTF8(s);
    strncpy(out, t.c_str(), cap - 1); out[cap - 1] = 0;
    return 0;
}

int braw_decode(BRAWClip* c, uint64_t frame, int scale, uint8_t* out, uint32_t cap, uint32_t* w, uint32_t* h) {
    if (!c) return -1;
    std::lock_guard<std::mutex> guard(c->lock);
    auto* ctx = new DecodeCtx();
    ctx->out = out; ctx->capacity = cap;
    ctx->scale = scale == 1 ? blackmagicRawResolutionScaleHalf : scale == 2 ? blackmagicRawResolutionScaleQuarter : scale == 3 ? blackmagicRawResolutionScaleEighth : blackmagicRawResolutionScaleFull;
    IBlackmagicRawJob* job = nullptr;
    HRESULT r = c->clip->CreateJobReadFrame(frame, &job);
    if (SUCCEEDED(r)) { job->SetUserData(ctx); r = job->Submit(); job->Release(); }
    if (FAILED(r)) { delete ctx; return -2; }
    std::unique_lock<std::mutex> lk(ctx->m);
    if (!ctx->cv.wait_for(lk, std::chrono::seconds(60), [&] { return ctx->done; })) return -3;   // délai dépassé : ctx abandonné (rare)
    HRESULT result = ctx->result;
    *w = ctx->width; *h = ctx->height;
    lk.unlock();
    delete ctx;
    return SUCCEEDED(result) ? 0 : -4;
}

int braw_audio_info(BRAWClip* c, uint32_t* ch, uint32_t* rate, uint32_t* bits, uint64_t* samples) {
    if (!c || !c->audio) return -1;
    if (FAILED(c->audio->GetAudioChannelCount(ch)) || FAILED(c->audio->GetAudioSampleRate(rate)) || FAILED(c->audio->GetAudioBitDepth(bits)) || FAILED(c->audio->GetAudioSampleCount(samples))) return -2;
    return 0;
}

int64_t braw_audio_read(BRAWClip* c, int64_t start, uint8_t* out, uint32_t cap, uint32_t maxSamples) {
    if (!c || !c->audio) return -1;
    uint32_t read = 0, bytes = 0;
    if (FAILED(c->audio->GetAudioSamples(start, out, cap, maxSamples, &read, &bytes))) return -2;
    return read;
}
