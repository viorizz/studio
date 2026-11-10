# Studio

Un enregistreur audio et vidéo pour macOS, volontairement simple : on ouvre l'app, on clique sur le gros bouton rouge, on parle.

Interface entièrement en français, proche des apps Apple (Dictaphone, Photo Booth).

## Ce que fait l'app

- **Enregistrer** : un gros bouton au centre, audio (`.m4a`, AAC) ou vidéo (`.mov`) avec la caméra.
- **Alerte micro** : au lancement, l'app prévient si aucun micro externe n'est branché ou si c'est le micro du Mac qui est utilisé.
- **Configuration du micro** en 4 étapes : brancher → choisir l'entrée → régler en s'écoutant (niveau vert/orange/rouge, volume, réduction du bruit, retour casque, essai de 5 secondes) → animation « prêt ».
- **Sauvegarde** : sur le Mac (`~/Music/Studio`), sur le NAS, ou les deux, avec un emplacement favori.
- **NAS via Tailscale** : si le NAS est hors ligne, l'enregistrement reste sur le Mac et est copié automatiquement dès que le NAS revient. Un écran guide la reconnexion (Tailscale installé → connecté → partage monté → dossier trouvé).
- **Historique** : chaque enregistrement a un nom lisible, distinct du nom de fichier, avec l'indication Mac / NAS. Clic droit : écouter, renommer, afficher dans le Finder, partager, copier, supprimer.

## Construire l'app

Il faut Xcode 15 ou plus récent et [XcodeGen](https://github.com/yonaskolb/XcodeGen) (le projet Xcode est généré, il n'est pas dans le dépôt).

```sh
brew install xcodegen
xcodegen generate
open Studio.xcodeproj
```

Puis ⌘R dans Xcode. macOS 13 (Ventura) minimum.

Pour installer l'app sur un autre Mac : **Product › Archive**, puis **Distribute App › Custom › Copy App**. L'app est signée « pour exécution locale » : au premier lancement sur l'autre Mac, faire clic droit › Ouvrir.

Tests de la logique (nommage, niveaux, réduction de bruit, historique) :

```sh
swift test --package-path StudioCore
```

## Choix techniques

Natif : **Swift, SwiftUI, AVFoundation et CoreAudio**, sans dépendance externe. C'est ce qui donne la capture audio/vidéo la plus légère sur Mac, et l'accès direct au volume d'entrée du micro.

| Dossier | Rôle |
| --- | --- |
| `StudioCore/` | Logique pure, testée : modèle `Recording`, noms de fichiers, échelle de niveau, réduction de bruit, regroupement de l'historique. |
| `Studio/Services/` | `AudioEngineController` (capture, niveau, retour casque, écriture AAC), `AudioDevices` (CoreAudio), `CameraController`, `RecorderCoordinator`, `Library`, `NASManager`. |
| `Studio/Views/` | Les écrans SwiftUI. |
| `Config/` | `Info.plist` et droits (micro, caméra). |

Points de performance :

- L'encodage et l'écriture des fichiers se font sur la file audio d'AVFoundation, jamais sur le fil principal.
- Le niveau du micro vit dans son propre objet observable : seule la jauge se redessine (environ dix fois par seconde), pas tout l'écran.
- Le volume du micro agit sur le volume d'entrée du périphérique (CoreAudio) quand il existe, sinon sur un gain logiciel.
- Le micro et la caméra sont relâchés quand l'app passe en arrière-plan sans enregistrement en cours.
- Les copies vers le NAS se font en arrière-plan, via un nom temporaire, pour ne jamais laisser de fichier tronqué.

## Limites connues

- En **vidéo**, le son vient directement du micro : la réduction du bruit ne s'applique pas (le volume du micro, oui).
- Le **retour casque** fait entendre le volume réglé, pas la réduction du bruit ; celle-ci s'entend dans l'essai de 5 secondes. Si le casque est branché sur le micro lui-même (prise du Blue Yeti), c'est le micro qui fait le retour, sans délai.
- Supprimer un enregistrement alors que le NAS est hors ligne ne supprime pas sa copie sur le NAS.
- L'app n'est pas « sandboxée » (elle doit accéder au volume du NAS) : elle est prévue pour un usage personnel, pas pour le Mac App Store.
