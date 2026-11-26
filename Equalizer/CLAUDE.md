# CLAUDE.md

<!--
MODÈLE RÉUTILISABLE
1. Copier ce fichier à la racine du projet, sous le nom CLAUDE.md.
2. Remplacer tous les champs [À COMPLÉTER].
3. Ajuster les sections "Choix graphiques" et "Contraintes de la machine" à vos habitudes.
4. Supprimer les lignes qui ne concernent pas l'app.
Conseil : gardez ce fichier court. Une règle inutile dilue celles qui comptent.
-->

## Projet

- **Nom de l'app :** [À COMPLÉTER]
- **Objectif, en une phrase :** [À COMPLÉTER]
- **Public visé :** [À COMPLÉTER]
- **Plateformes :** iPhone ipad
- **Version minimale d'iOS :** 18
- **Langues de l'app :** français anglais chinois
- **Services externes :** [aucun / CloudKit / API, à compléter]

## Façon de travailler

- Réponds en français. Le code, les noms de types et les noms de fonctions restent en anglais.
- Avant une modification importante, présente un plan court et attends ma validation.
- Fais de petits changements ciblés. Ne touche pas au code sans rapport avec la demande.
- Si une demande est ambiguë, pose une question au lieu de supposer.
- N'ajoute aucune dépendance externe sans mon accord. Privilégie les frameworks d'Apple.
- Ne fais pas de commit et ne pousse rien sans ma demande.
- Une tâche n'est terminée que si le projet compile et que les tests concernés passent.
- Si tu n'as pas pu compiler ou tester, dis-le clairement.

## Stack technique

- **Langage :** Swift, dernière version stable prise en charge par le projet
- **Interface :** SwiftUI. UIKit uniquement si SwiftUI ne permet pas de répondre au besoin.
- **Architecture :** MVVM simple, avec `@Observable` pour l'état des vues
- **Concurrence :** `async/await` et acteurs, avec `@MainActor` pour le code d'interface
- **Persistance :** SwiftData [ou autre, à adapter]
- **Dépendances :** Swift Package Manager uniquement

## Structure du projet

```text
[NomApp]/
├── App/            # Point d'entrée et configuration
├── Features/       # Un dossier par fonctionnalité (vues + view models)
├── Models/         # Modèles de données
├── Services/       # Réseau, persistance, accès système
├── Components/     # Vues réutilisables
├── DesignSystem/   # Couleurs, typographies, espacements
└── Resources/      # Assets, Localizable.xcstrings
[NomApp]Tests/      # Tests unitaires
[NomApp]UITests/    # Tests d'interface
```

## Bonnes pratiques de code

- Suis les Swift API Design Guidelines d'Apple pour le nommage.
- Écris des vues courtes : au-delà d'une centaine de lignes, extrais des sous-vues.
- Ne place pas de logique métier dans les vues.
- Injecte les dépendances via des protocoles pour pouvoir les tester.
- Privilégie les `struct` et `let`. Utilise `class` et `var` seulement si nécessaire.
- Évite `!` et `try!` dans le code de production. Déballe les optionnels avec `guard let` ou `if let`.
- Gère chaque erreur explicitement et affiche un message compréhensible à l'utilisateur.
- N'utilise pas `print` pour les logs : utilise `Logger` (framework `os`).
- Ne laisse aucune valeur « magique » : passe par une constante ou par le design system.
- Ne mets jamais de secret ni de clé d'API dans le code ou dans Git.
- Ne collecte que les données nécessaires et tiens à jour le manifeste de confidentialité (`PrivacyInfo.xcprivacy`).
- Remplace les API dépréciées lorsque tu travailles sur le code concerné.

## Commentaires et documentation

- Le code doit rester lisible sans commentaire : commence par de bons noms.
- Un commentaire explique le **pourquoi**, pas le **quoi**.
- Rédige les commentaires en français.
- Documente les types et méthodes non évidents avec la syntaxe `///`, y compris `- Parameters:`, `- Returns:` et `- Throws:` lorsqu'ils sont utiles.
- Organise les fichiers longs avec `// MARK: -`.
- Ne laisse pas de code commenté.
- Associe chaque `TODO` à une raison précise : `// TODO: raison`.

## Tests

- **Framework :** Swift Testing pour les tests unitaires, XCTest pour les tests d'interface.
- Teste en priorité la logique métier, les view models, les services et les cas d'erreur.
- Ajoute ou mets à jour les tests pour toute nouvelle fonctionnalité.
- Pour un bug, écris d'abord un test qui le reproduit, puis corrige-le.
- Utilise des doublures (mocks) pour le réseau et la persistance. Un test ne doit pas dépendre d'Internet.
- Nomme les tests d'après le comportement attendu.
- Couvre les parcours essentiels avec quelques tests d'interface, sans chercher à tout tester.
- Ne désactive pas et n'affaiblis pas un test pour le faire passer.

## Choix graphiques

<!-- Les codes couleur sont des points de départ, à ajuster selon l'identité de l'app. -->

- **Style général :** esprit Apple Aqua modernisé : surfaces translucides, effet verre, reflets légers et profondeur douce, tout en restant conforme aux Human Interface Guidelines
- **Palette :** tons pastel bleu et/ou vert, peu saturés et lumineux
- **Bleu pastel :** `#A9D6F5` (surfaces et fonds)
- **Vert pastel :** `#B5E8D0` (surfaces et fonds)
- **Bleu d'accent :** `#2F7FB8` (boutons, liens, éléments interactifs)
- **Vert d'accent :** `#2E8B6F` (validation, états positifs)
- **Dégradés :** subtils, du bleu pastel vers le vert pastel, réservés aux fonds et aux grandes surfaces
- **Matières :** Liquid Glass (`.glassEffect`) si la version minimale d'iOS le permet, sinon `.ultraThinMaterial` ou `.regularMaterial`
- **Ombres :** douces et diffuses, jamais dures ou très contrastées
- **Apparence :** clair et sombre obligatoires, via l'Asset Catalog, avec des versions plus profondes et moins lumineuses des teintes en mode sombre
- **Typographie :** police système avec les styles sémantiques (`.title`, `.headline`, `.body`)
- **Icônes :** SF Symbols en priorité
- **Espacements :** multiples de 8 (8, 16, 24, 32)
- **Coins arrondis :** généreux, 16 pour les cartes et 12 pour les boutons, en style `.continuous`
- **Animations :** douces et fluides, avec des ressorts sans rebond marqué (`.smooth`, `.spring(duration: 0.4, bounce: 0.15)`) et des transitions en fondu
- **Retours visuels :** légère mise à l'échelle au toucher (environ 0,97), sans effet brusque
- **Navigation :** composants natifs (`NavigationStack`, `TabView`, `.sheet`)
- **États à prévoir :** chargement, contenu vide, erreur

Règles à respecter :

- Utilise les valeurs du dossier `DesignSystem/`. N'écris pas de couleur ou de taille en dur dans une vue.
- Ajoute un `#Preview` à chaque vue, avec au moins les modes clair et sombre pour les écrans principaux.
- N'utilise jamais une teinte pastel pour du texte sur fond clair : le contraste serait insuffisant. Réserve-les aux fonds et utilise les couleurs d'accent ou les couleurs sémantiques pour le texte.
- Vérifie que le texte reste lisible sur les surfaces translucides, quel que soit le contenu situé derrière.
- Garde le verre et les reflets pour les éléments clés. Trop d'effets alourdissent l'interface et les performances.
- Centralise les animations dans `DesignSystem/` pour qu'elles restent cohérentes.
- Remplace les mouvements par un simple fondu si « Réduire les animations » est activé.

## Accessibilité et localisation

- Prends en charge Dynamic Type, sans hauteur fixe pour les textes.
- Ajoute des libellés VoiceOver aux éléments interactifs et aux icônes seules.
- Garde des zones tactiles d'au moins 44 × 44 points et un contraste suffisant.
- Respecte le réglage « Réduire les animations ».
- Place tous les textes visibles dans le String Catalog (`Localizable.xcstrings`).

## Contraintes de la machine

<!-- À adapter si vous changez de Mac. -->

Le développement se fait sur un Mac mini M1 avec 8 Go de RAM.

- N'utilise qu'un seul simulateur à la fois.
- Lance uniquement les tests concernés par la modification, puis la suite complète avant de conclure.
- Évite les compilations complètes et le nettoyage du projet lorsqu'ils ne sont pas nécessaires.

## Commandes

```bash
# Compiler
xcodebuild build -scheme [NomApp] -destination 'platform=iOS Simulator,name=[iPhone à compléter]'

# Lancer tous les tests
xcodebuild test -scheme [NomApp] -destination 'platform=iOS Simulator,name=[iPhone à compléter]'

# Lancer une seule classe ou suite de tests
xcodebuild test -scheme [NomApp] -destination 'platform=iOS Simulator,name=[iPhone à compléter]' -only-testing:[NomApp]Tests/[NomDeLaSuite]
```

## Git

- Crée une branche par fonctionnalité ou correction : `feature/...`, `fix/...`.
- Rédige des messages de commit courts et clairs, en français, à l'impératif.
- Maintiens un `.gitignore` adapté à Xcode (`xcuserdata/`, `DerivedData/`, `.DS_Store`).

## Spécificités de cette app

<!-- Décisions, pièges connus, règles propres à ce projet. -->

- [À COMPLÉTER]
