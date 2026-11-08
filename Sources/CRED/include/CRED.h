// Pont C vers le SDK R3D de RED (décodage CPU). Le SDK (en-têtes, bibliothèque statique, dylibs) est dans vendor/R3DSDK, hors dépôt.
#ifndef CRED_H
#define CRED_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct REDClip REDClip;

/// 1 si l'appli a été compilée avec le SDK R3D, 0 sinon.
int red_compiled(void);
/// 1 si le décodage GPU (Metal) est utilisable sur cette machine.
int red_gpu_available(void);
/// Initialise le SDK (une fois). `libDir` : dossier contenant REDR3D.dylib. Retourne 0 si réussi.
int red_init(const char* libDir);
REDClip* red_open(const char* path);
void red_close(REDClip* clip);
int red_info(REDClip* clip, uint32_t* width, uint32_t* height, float* fps, uint64_t* frameCount);
int red_timecode(REDClip* clip, uint64_t frame, char* out, uint32_t capacity);
int red_camera(REDClip* clip, char* out, uint32_t capacity);
/// Décode une image en BGRA 8 bits. `scale` : 0 pleine, 1 moitié, 2 quart, 3 huitième. Retourne 0 si réussi.
int red_decode(REDClip* clip, uint64_t frame, int scale, uint8_t* out, uint32_t capacity, uint32_t* width, uint32_t* height);
/// Audio : PCM 16 bits entrelacé petit-boutiste (converti depuis le 24/32 bits gros-boutiste du SDK).
int red_audio_info(REDClip* clip, uint32_t* channels, uint32_t* sampleRate, uint32_t* bitDepth, uint64_t* sampleCount);
int64_t red_audio_read(REDClip* clip, int64_t start, uint8_t* out, uint32_t capacityBytes, uint32_t maxSamples);

#ifdef __cplusplus
}
#endif
#endif
