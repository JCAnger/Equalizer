import Foundation
import os

/// Morceau déjà ouvert, mémorisé pour pouvoir le rechoisir dans le menu.
nonisolated struct RecentTrack: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    /// Bookmark de sécurité des fichiers choisis dans Fichiers : l'URL seule ne suffit pas,
    /// car l'autorisation d'accès est perdue au lancement suivant.
    let bookmark: Data?
    /// URL directe des morceaux de la bibliothèque Musique (`ipod-library://`), qui ne
    /// donnent pas de bookmark mais restent valides tant que le morceau est sur l'appareil.
    let libraryURL: URL?

    /// Sert à éviter les doublons : deux bookmarks d'un même fichier ne sont pas identiques
    /// octet pour octet, on compare donc le nom pour les fichiers et l'URL pour la bibliothèque.
    var identity: String {
        libraryURL?.absoluteString ?? name
    }
}

/// Liste des morceaux récents, du plus récent au plus ancien, conservée entre les lancements.
///
/// Stockée dans `UserDefaults` : quelques entrées légères, sans relation entre elles,
/// ne justifient pas une base SwiftData.
struct RecentTracksStore {
    /// Au-delà, le menu deviendrait trop long pour rester pratique.
    static let maximumCount = 5

    private static let storageKey = "recentTracks"
    private static let logger = Logger(subsystem: "Equalizer", category: "RecentTracks")

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [RecentTrack] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        do {
            return try JSONDecoder().decode([RecentTrack].self, from: data)
        } catch {
            // Une liste illisible n'est pas bloquante : on repart d'une liste vide.
            Self.logger.error("Lecture des morceaux récents impossible : \(error.localizedDescription)")
            return []
        }
    }

    /// Crée l'entrée correspondant à une URL. À appeler pendant que l'accès sécurisé au
    /// fichier est ouvert, sinon le bookmark ne peut pas être créé.
    /// - Returns: `nil` si l'URL ne peut être ni mise en bookmark ni rouverte telle quelle.
    /// - Parameter title: nom à afficher ; à défaut, le nom du fichier sans extension.
    func makeTrack(for url: URL, title: String? = nil) -> RecentTrack? {
        let name = title ?? url.deletingPathExtension().lastPathComponent
        if url.isFileURL {
            do {
                return RecentTrack(id: UUID(), name: name, bookmark: try url.bookmarkData(), libraryURL: nil)
            } catch {
                Self.logger.error("Bookmark impossible pour \(name) : \(error.localizedDescription)")
                return nil
            }
        }
        return RecentTrack(id: UUID(), name: name, bookmark: nil, libraryURL: url)
    }

    /// Place le morceau en tête de liste, sans doublon, et limite la taille de la liste.
    /// - Returns: la nouvelle liste, déjà enregistrée.
    func adding(_ track: RecentTrack, to tracks: [RecentTrack]) -> [RecentTrack] {
        let updated = ([track] + tracks.filter { $0.identity != track.identity }).prefix(Self.maximumCount)
        save(Array(updated))
        return Array(updated)
    }

    /// - Returns: la nouvelle liste, déjà enregistrée.
    func removing(_ track: RecentTrack, from tracks: [RecentTrack]) -> [RecentTrack] {
        let updated = tracks.filter { $0.id != track.id }
        save(updated)
        return updated
    }

    /// Retrouve l'URL d'un morceau mémorisé.
    /// - Returns: `nil` si le fichier a été supprimé ou déplacé hors de portée.
    func resolveURL(of track: RecentTrack) -> URL? {
        if let libraryURL = track.libraryURL { return libraryURL }
        guard let bookmark = track.bookmark else { return nil }
        var isStale = false
        do {
            return try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
        } catch {
            Self.logger.error("Bookmark invalide pour \(track.name) : \(error.localizedDescription)")
            return nil
        }
    }

    private func save(_ tracks: [RecentTrack]) {
        do {
            defaults.set(try JSONEncoder().encode(tracks), forKey: Self.storageKey)
        } catch {
            Self.logger.error("Enregistrement des morceaux récents impossible : \(error.localizedDescription)")
        }
    }
}
