# kYNEDIT — plan de développement

Fusion allégée de **Kyno** (explorateur de médias, tri, métadonnées, sous-clips) et d'**EditReady** (transcodage rapide des formats caméra). Un seul outil : on parcourt, on marque, on exporte, sans jamais copier un fichier à la main.

## 1. Langage : Swift (natif macOS)

| Critère | Swift | Rust |
|---|---|---|
| Moteurs médias Apple (ProRes/HEVC matériels) | accès direct : VideoToolbox, AVFoundation, Metal | via FFI, plus fragile |
| Interface | SwiftUI + AppKit, aspect natif, Socle déjà prévu en SwiftUI | pas d'UI native mature |
| Cœur de calcul | égal (compilé, sans GC) | égal |
| Signature, notarisation, mise à jour auto | chaîne déjà en place (`_tools`) | à recréer |

**Choix : Swift 6**, avec un seul module C/C++ isolé (démuxeurs BRAW / R3D / ARRIRAW via leurs SDK) et un composant Rust facultatif plus tard si un traitement pur (hachage, indexation) le justifie. Le goulot est la puce média, pas le langage.

## 2. Périmètre simplifié (v1)

**Gardé de Kyno** : navigation dans les volumes, vignettes et planche (skimming), métadonnées (tags, notes, étoiles, couleurs), marqueurs et sous-clips, recherche, aperçu fluide, envoi vers **DaVinci Resolve, Final Cut Pro et Adobe Premiere Pro** (FCPXML, XML Premiere, EDL, AAF en option).
**Gardé d'EditReady** : lecture des formats caméra (Sony XAVC, Canon XF, ARRI, RED, BRAW, iPhone Log, DJI), export ProRes / H.264 / HEVC / DNxHR, LUT, renommage par modèles, files d'export, dossier surveillé, audio (mono, canaux) et incrustation de timecode.
**Écarté** : copie vérifiée de cartes (v2), gestion de catalogue sur serveur, transcription vocale, collaboration, étalonnage.

## 3. Architecture

```
KyNEDIT.app
├─ App/            SwiftUI : fenêtres, commandes, réglages, À propos, 4 langues (fr/en/es/it)
├─ Catalog/        base SQLite (GRDB) : fichiers, métadonnées, marqueurs ; index FTS5 pour la recherche
├─ Scan/           FSEvents + énumération parallèle, hachage rapide (xxh3) pour détecter doublons et déplacements
├─ Probe/          lecture des en-têtes (AVFoundation + démuxeurs caméra), sans décoder
├─ Thumbs/         vignettes et planches : décodage matériel, cache disque, mémoire plafonnée
├─ Player/         AVSampleBufferDisplayLayer + Metal (LUT, fausses couleurs, forme d'onde)
├─ Engine/         moteur d'export : graphe de tâches, planificateur matériel, reprise après arrêt
├─ Exchange/       Resolve (API de script + XML), Final Cut (FCPXML 1.11), Premiere Pro (XML xmeml v4, projet .prproj non modifié ; sous-clips et marqueurs en séquence importable)
└─ Updater/        mise à jour auto (modèle mBACKUP)
```

Un **Pipeline** décodage → traitement (LUT, mise à l'échelle, couleur) → encodage, avec tampons `CVPixelBuffer` adossés à IOSurface : aucune copie CPU entre les étapes.

## 4. Optimisation selon la machine

Au premier lancement, `HardwareProfile` interroge le système (sysctl, IOKit, Metal, VideoToolbox) et **mesure** une courte séquence de référence (5 s, une seule fois, mémorisée avec l'empreinte de la machine). Le planificateur répartit ensuite le travail.

| Machine | Détection | Stratégie |
|---|---|---|
| **Apple Silicon Pro/Max/Ultra** | nombre de moteurs média (`VTCopyVideoEncoderList`, modèle) | 1 tâche par moteur ProRes et par moteur HEVC/H.264 ; Ultra = 2 fois plus de tâches simultanées ; UI et vignettes sur les cœurs efficaces |
| **Apple Silicon de base (M-series)** | 1 moteur média | 1 export matériel + vignettes en tâche de fond ; plafond thermique plus bas |
| **Mac Intel + AMD/Intel GPU** | `MTLDevice.isLowPower`, Quick Sync | HEVC/H.264 via VideoToolbox, ProRes logiciel limité aux cœurs physiques − 1 |
| **Mac Intel sans GPU dédié** | idem | files séquentielles, vignettes basse résolution |
| **Mémoire unifiée** | `hw.memsize` | cache de vignettes = 5 % de la RAM (plafond 2 Go), tampons de trames dimensionnés à la résolution des sources |
| **Stockage** | type de volume (NVMe, SSD USB, disque, réseau) | lectures concurrentes : NVMe 8, USB SSD 4, disque dur 1 (séquentiel), réseau 2 ; écriture sur un autre volume que la lecture si possible |
| **Batterie / thermique** | `ProcessInfo.thermalState`, `isLowPowerModeEnabled` | débit réduit en « serious », pause en « critical », jamais d'export lourd sur batterie sans accord |

Règles transversales :
- **Débit avant tout** : les formats RAW (BRAW, R3D) se décodent par Metal sur le GPU ; le reste par le moteur média ; le CPU ne sert qu'aux cas sans matériel.
- **Rien ne décode pour naviguer** : en-têtes + vignettes en cache ; l'aperçu lit le proxy intégré (iPhone, Sony, Canon) quand il existe.
- **Export sans réencodage** quand le format cible = format source (réemballage MOV/MP4, sous-clips au plus proche de l'image clé, puis recodage seulement des bords).
- **File à priorités** : l'aperçu passe toujours avant l'export, l'export avant l'indexation.
- **Banc d'essai intégré** (réglage « Performances ») : affiche images/s par moteur, utilisation de chaque unité, temps estimé d'un lot ; sert aussi à valider les réglages automatiques.

## 5. Plan par étapes

| # | Étape | Livrable | Modèle |
|---|---|---|---|
| 0 | Socle du projet : paquet Swift, signature, build_all, 4 langues, À propos | appli vide qui se lance | Sonnet |
| 1 | Catalogue + scan : volumes, SQLite, FSEvents, FTS5 | arborescence et liste rapide (100 000 fichiers fluides) | Opus (architecture) puis Sonnet |
| 2 | Sonde + vignettes : en-têtes, planche, cache | grille et skimming | Sonnet |
| 3 | Lecteur : lecture, J/K/L, marqueurs, sous-clips, LUT | aperçu complet | Sonnet |
| 4 | Métadonnées : tags, étoiles, couleurs, notes, recherche | inspecteur fonctionnel | Sonnet |
| 5 | `HardwareProfile` + planificateur + banc d'essai | tableau « Performances » | Opus |
| 6 | Moteur d'export : ProRes / H.264 / HEVC, modèles de nom, file, reprise | exports parallèles | Opus puis Sonnet |
| 7 | Formats caméra : RAW (BRAW/R3D/ARRI) via SDK | lecture et export RAW | Opus |
| 8 | Échanges NLE + dossier surveillé | Resolve, Final Cut (FCPXML), Premiere Pro (xmeml) ; test d'import réel dans les trois | Sonnet |
| 9 | Finitions : mise à jour auto, notarisation, GitHub, release.sh | v1.0 | Sonnet |

Critères d'acceptation v1 : ouverture d'un dossier de 10 000 clips < 2 s (index chaud), skimming ≥ 60 i/s, export ProRes 4K H.264 → ≥ 2× la vitesse de lecture sur M-series Pro, aucune image perdue (vérifiée par comparaison de timecode), fonctionnement hors ligne.

## 6. Risques

- SDK RAW (licences RED / Blackmagic / ARRI) : à valider avant l'étape 7 ; sinon export via leurs outils en ligne de commande.
- Encodeur ProRes matériel absent sur Mac de base : repli logiciel signalé clairement dans l'interface.
- Droits d'accès disque (volumes externes, réseau) : demander l'accès complet au disque une seule fois, expliqué à l'écran.

## 7. Repli ffmpeg (décision du 2026-11-08)

AVFoundation ne lit pas certains codecs fréquents en motion design (MOV PNG, Animation/RLE) ni MXF/MKV/AVI. `FFmpegTool` prend le relais pour la sonde (ffprobe) et la vignette (ffmpeg), seulement quand AVFoundation échoue. Il cherche d'abord un exécutable embarqué (`Resources/bin`), puis Homebrew.
**À faire avant toute diffusion :** le ffmpeg Homebrew est GPL (x264/x265) et ne doit pas être embarqué tel quel ; compiler un ffmpeg LGPL minimal (décodeurs seuls, sans x264/x265), le signer et le placer dans `Resources/bin`.

## 8. Formats RAW (état au 2026-11-08)

**BRAW : pris en charge** (SDK Blackmagic RAW 6.0, fourni par l'utilisateur).
- Pont C++ `Sources/CBRAW` (en-tête et chargeur du SDK, licence permissive de Blackmagic en tête de fichier) ; le framework `BlackmagicRawAPI.framework` se charge à l'exécution, cherché d'abord dans `Contents/Frameworks` de l'appli, puis dans l'installation officielle.
- Le framework (15 Mo) est placé dans `vendor/` (hors dépôt) et copié dans l'appli par `build.sh`. **À vérifier avant toute diffusion** : le contrat de licence du SDK pour la redistribution de la bibliothèque.
- Sonde, vignette, lecteur (images décodées à 1/4, lecture suivant l'horloge) et export ProRes / H.264 / HEVC avec audio. Décodage en BGRA 8 bits : un export BRAW garde 8 bits (le décodage 16 bits est la suite logique).
- Testé avec `sample.braw` du SDK (4608×2592, 1 image, audio stéréo 48 kHz). Lecture continue et export de longs clips non testés (aucun clip long disponible).

**Chargement depuis `/Applications/Blackmagic RAW`** : bloqué pendant plusieurs minutes par la vérification de signature de macOS, avec une fenêtre « endommagé » ; la copie du framework extraite du SDK se charge en 0,3 s.

**R3D : SDK RED 9.2.1 intégré, décodage CPU, testé** sur « KOMODO-X 6K dancer-2 » (5760×3240, 3,6 s) : sonde, vignette, lecteur et export H.264 / ProRes de 48 images corrects. Le décodage CPU plein format est lent (environ 1,3 s par image à 6K) : le décodage GPU Metal du SDK est la priorité suivante. Pont `Sources/CRED` ; le SDK reste dans `vendor/R3DSDK` (hors dépôt) car la licence RED interdit de redistribuer les en-têtes, les exemples et la documentation (seules les dylibs `Redistributable/mac`, en l'état, peuvent accompagner l'appli, sous un contrat d'utilisation final). Sans `vendor/`, l'appli compile sans R3D. Suite : décodage GPU Metal, profondeur 16 bits.

**ARRIRAW, Canon CRM : en attente de leurs SDK** (RED sur demande, ARRI sur inscription, Canon). Exemples publics repérés : [RED](https://www.reddigitalcinema.com/sample-r3d-files) (ZIP de 347 Mo à 18 Go), [ARRI](https://www.arri.com/en/learn/camera-systems/camera-sample-footage-reference-image) (liens Frame.io). Prévoir un protocole `RawDecoder` pour brancher chaque format.

**Canon CRM** : le « Canon RAW Plugin for Final Cut Pro » (RPFM 3.0.11) s'installe dans `/Library/Application Support/ProApps/PlugIns/VendorSpecific` : c'est un module des applications Apple Pro (Final Cut, Motion), pas une extension système ; AVFoundation, donc kYNEDIT, ne verrait pas les `.crm` après son installation. Il embarque le CrmSdk privé de Canon, dont l'usage hors module n'est pas autorisé. Voie à suivre : demander le CRMSDK (compte Canon Developer Community, « SDK | API | Downloads »), sans audio.
