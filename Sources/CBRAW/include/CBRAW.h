// Pont C vers le SDK Blackmagic RAW (C++/COM). Le SDK est chargé à l'exécution depuis BlackmagicRawAPI.framework.
#ifndef CBRAW_H
#define CBRAW_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct BRAWClip BRAWClip;

/// Ouvre un clip. `frameworkDirs` : dossiers (séparés par « : ») contenant BlackmagicRawAPI.framework, essayés dans l'ordre.
/// Retourne NULL si le framework est introuvable ou si le fichier est illisible.
BRAWClip* braw_open(const char* path, const char* frameworkDirs);
void braw_close(BRAWClip* clip);

/// Infos vidéo : taille, cadence, nombre d'images. Retourne 0 si réussi.
int braw_info(BRAWClip* clip, uint32_t* width, uint32_t* height, float* fps, uint64_t* frameCount);
/// Timecode de l'image (texte UTF-8 dans `out`). Retourne 0 si réussi.
int braw_timecode(BRAWClip* clip, uint64_t frame, char* out, uint32_t capacity);
/// Nom de la caméra (texte UTF-8). Retourne 0 si réussi.
int braw_camera(BRAWClip* clip, char* out, uint32_t capacity);

/// Décode une image en BGRA 8 bits. `scale` : 0 pleine, 1 moitié, 2 quart, 3 huitième.
/// `out` doit contenir au moins largeur × hauteur × 4 octets de l'échelle choisie. Retourne 0 si réussi.
int braw_decode(BRAWClip* clip, uint64_t frame, int scale, uint8_t* out, uint32_t capacity, uint32_t* width, uint32_t* height);

/// Audio : retourne 0 s'il y a une piste audio.
int braw_audio_info(BRAWClip* clip, uint32_t* channels, uint32_t* sampleRate, uint32_t* bitDepth, uint64_t* sampleCount);
/// Lit jusqu'à `maxSamples` échantillons (PCM entrelacé) à partir de `start`. Retourne le nombre lu, ou -1.
int64_t braw_audio_read(BRAWClip* clip, int64_t start, uint8_t* out, uint32_t capacityBytes, uint32_t maxSamples);

#ifdef __cplusplus
}
#endif
#endif
