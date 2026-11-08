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
