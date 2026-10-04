import Foundation

/// Profiles contain definitions only. Inputs, raw responses and credentials are never stored here.
public struct DecisionProfileRepository: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    private struct Document: Codable { var schemaVersion: Int; var profiles: [DecisionProfile] }
    public func load() throws -> [DecisionProfile] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.schemaVersion == 1, Set(document.profiles.map(\.id)).count == document.profiles.count else { throw DecisionFailure.invalid("Profile 저장 파일의 버전 또는 ID 오류") }
        for profile in document.profiles { try profile.validate() }
        return document.profiles
    }
    public func save(_ profiles: [DecisionProfile]) throws {
        _ = try load() // A corrupt existing file must never be overwritten by an empty fallback.
        guard Set(profiles.map(\.id)).count == profiles.count else { throw DecisionFailure.invalid("Profile ID 중복") }
        for profile in profiles { try profile.validate() }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(Document(schemaVersion: 1, profiles: profiles)).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func decodeProfile(_ data: Data) throws -> DecisionProfile {
        let profile = try JSONDecoder().decode(DecisionProfile.self, from: data); try profile.validate(); return profile
    }
    public static func encodeProfile(_ profile: DecisionProfile) throws -> Data {
        try profile.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(profile)
    }
}
