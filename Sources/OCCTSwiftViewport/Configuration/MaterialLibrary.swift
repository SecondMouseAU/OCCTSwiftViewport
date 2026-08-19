// MaterialLibrary.swift
// OCCTSwiftViewport
//
// In-memory + on-disk registry of named PBRMaterials.
// Holds bundled presets and user-saved materials.

import Foundation

/// A named PBR material: a `PBRMaterial` plus a stable identifier and display name.
public struct NamedMaterial: Sendable, Codable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var material: PBRMaterial
    /// True for built-in presets that should not be deleted by the user.
    public var isBuiltin: Bool

    public init(id: UUID = UUID(), name: String, material: PBRMaterial, isBuiltin: Bool = false) {
        self.id = id
        self.name = name
        self.material = material
        self.isBuiltin = isBuiltin
    }
}

/// Manages the set of materials available to the user.
///
/// Built-in presets are loaded from `PBRMaterial.presets` on init; user-saved
/// materials are persisted as JSON in Application Support. The disk format is
/// versioned for forward-compatibility.
@MainActor
public final class MaterialLibrary: ObservableObject {

    @Published public private(set) var materials: [NamedMaterial]

    /// Storage URL for persisted user materials. nil = no persistence.
    private let storageURL: URL?

    public init(storageURL: URL? = MaterialLibrary.defaultStorageURL()) {
        self.storageURL = storageURL
        let presets = MaterialLibrary.bundledPresets()
        if let url = storageURL,
            let userMaterials = try? MaterialLibrary.loadUserMaterials(from: url)
        {
            self.materials = presets + userMaterials
        } else {
            self.materials = presets
        }
    }

    // MARK: - Presets

    /// All built-in PBR presets wrapped as `NamedMaterial`.
    public static func bundledPresets() -> [NamedMaterial] {
        let order = [
            "steel", "brushedAluminum", "brass", "copper", "chromedSteel",
            "gold", "titanium", "plasticGlossy", "plasticMatte",
            "paintedAutomotive", "rubber", "glass",
        ]
        return order.compactMap { key -> NamedMaterial? in
            guard let m = PBRMaterial.presets[key] else { return nil }
            return NamedMaterial(name: prettify(key), material: m, isBuiltin: true)
        }
    }

    private static func prettify(_ key: String) -> String {
        // "brushedAluminum" → "Brushed Aluminum"
        var out = ""
        for (i, c) in key.enumerated() {
            if i > 0 && c.isUppercase { out.append(" ") }
            out.append(i == 0 ? Character(c.uppercased()) : c)
        }
        return out
    }

    // MARK: - User actions

    /// Adds (or replaces by id) a user material and persists.
    public func saveUserMaterial(_ named: NamedMaterial) {
        if let i = materials.firstIndex(where: { $0.id == named.id }) {
            materials[i] = named
        } else {
            materials.append(named)
        }
        try? persist()
    }

    /// Removes a user-created material from the library.
    ///
    /// Silently does nothing for an unknown `id` or for a built-in preset, so the shipped
    /// presets cannot be deleted through this call.
    public func remove(id: UUID) {
        guard let i = materials.firstIndex(where: { $0.id == id }) else { return }
        if materials[i].isBuiltin { return }
        materials.remove(at: i)
        try? persist()
    }

    public func material(byID id: UUID) -> NamedMaterial? {
        materials.first(where: { $0.id == id })
    }

    // MARK: - Persistence

    private struct DiskFormat: Codable {
        var schemaVersion: Int
        var materials: [NamedMaterial]
    }

    public static func defaultStorageURL() -> URL? {
        let fm = FileManager.default
        guard
            let support = try? fm.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                create: true)
        else {
            return nil
        }
        let dir = support.appendingPathComponent("OCCTSwiftViewport", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("materials.json")
    }

    private static func loadUserMaterials(from url: URL) throws -> [NamedMaterial] {
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(DiskFormat.self, from: data)
        // Ignore disk entries marked builtin (we always source those fresh from code).
        return decoded.materials.filter { !$0.isBuiltin }
    }

    private func persist() throws {
        guard let url = storageURL else { return }
        let userOnly = materials.filter { !$0.isBuiltin }
        let payload = DiskFormat(schemaVersion: 1, materials: userOnly)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: url, options: .atomic)
    }
}
