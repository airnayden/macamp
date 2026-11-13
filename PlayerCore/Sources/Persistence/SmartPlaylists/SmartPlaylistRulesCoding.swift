import Foundation

/// Every way the smart-playlist engine can refuse to act.
///
/// One typed surface for the whole slice so a caller writes a single `catch`. Each
/// case is raised **before** any write: a rule set that cannot be read leaves the
/// previous materialisation exactly as it was.
public enum SmartPlaylistError: Error, Sendable, Equatable {
    /// No `smartPlaylist` row exists for the playlist.
    case rulesNotFound(playlistId: Int64)
    /// The stored rules declare a schema version this build does not implement —
    /// typically a database written by a newer app.
    case unsupportedRulesVersion(found: Int, supported: Int)
    /// The stored rules are not decodable at the declared version.
    case malformedRules(reason: String)
}

// MARK: - JSON codec

public extension SmartPlaylistRules {
    /// Decodes rules from a `smartPlaylist.rulesJson` payload.
    ///
    /// The version is probed **first**, from a payload that decodes nothing else, so
    /// a future schema is rejected as
    /// ``SmartPlaylistError/unsupportedRulesVersion(found:supported:)`` instead of
    /// being force-fitted into this build's shape and silently mis-parsed. Only once
    /// the version matches is the rest of the payload decoded.
    static func decode(json: String) throws -> SmartPlaylistRules {
        guard let data = json.data(using: .utf8) else {
            throw SmartPlaylistError.malformedRules(reason: "rulesJson is not valid UTF-8")
        }
        return try decode(jsonData: data)
    }

    /// Decodes rules from raw JSON bytes. See ``decode(json:)``.
    static func decode(jsonData: Data) throws -> SmartPlaylistRules {
        let probe: SchemaVersionProbe
        do {
            probe = try JSONDecoder().decode(SchemaVersionProbe.self, from: jsonData)
        } catch {
            throw SmartPlaylistError.malformedRules(reason: String(describing: error))
        }
        let declared = probe.schemaVersion ?? legacySchemaVersion
        guard declared == currentSchemaVersion else {
            throw SmartPlaylistError.unsupportedRulesVersion(
                found: declared,
                supported: currentSchemaVersion
            )
        }
        do {
            return try JSONDecoder().decode(SmartPlaylistRules.self, from: jsonData)
        } catch {
            throw SmartPlaylistError.malformedRules(reason: String(describing: error))
        }
    }

    /// Decodes rules, cross-checking the `smartPlaylist.rulesVersion` column first.
    ///
    /// The column is the cheap gate (no JSON parse at all for a future row); the
    /// payload's own `schemaVersion` remains the authority. They are written
    /// together by ``SmartPlaylistRepository``, so a disagreement means the row was
    /// edited by something else — and either half declaring an unknown version is
    /// enough to refuse.
    static func decode(json: String, declaredVersion: Int) throws -> SmartPlaylistRules {
        guard declaredVersion == currentSchemaVersion else {
            throw SmartPlaylistError.unsupportedRulesVersion(
                found: declaredVersion,
                supported: currentSchemaVersion
            )
        }
        return try decode(json: json)
    }

    /// Encodes the rules for `smartPlaylist.rulesJson`.
    ///
    /// `.sortedKeys` makes the payload byte-stable: the same rule set stored against
    /// two profiles produces two byte-identical strings, which is what lets the
    /// multi-tenancy test prove that identical *rules* still yield disjoint *results*.
    func encodedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(self)
            guard let json = String(data: data, encoding: .utf8) else {
                throw SmartPlaylistError.malformedRules(reason: "encoded rules are not valid UTF-8")
            }
            return json
        } catch let error as SmartPlaylistError {
            throw error
        } catch {
            throw SmartPlaylistError.malformedRules(reason: String(describing: error))
        }
    }
}

/// Reads only the schema version, so an unknown payload shape never reaches the real
/// decoder.
private struct SchemaVersionProbe: Decodable {
    let schemaVersion: Int?
}
