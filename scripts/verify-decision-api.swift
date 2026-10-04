// Compile: swiftc -parse-as-library -swift-version 6 scripts/verify-decision-api.swift -o /tmp/CodexMaestroCompatibilityProbe
// Run with an evidence directory. --request-access allows a normal macOS Keychain prompt.
// This probe sends synthetic data only. It does not change Keychain permissions or app profiles.
import Foundation
import LocalAuthentication
import Security

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor @main struct CompatibilityProbe {
    static func main() async {
        guard CommandLine.arguments.count >= 2 else { print("Usage: probe EVIDENCE_DIRECTORY [--request-access] [--only=name,...]"); exit(2) }
        let requestAccess = CommandLine.arguments.contains("--request-access")
        let context = LAContext()
        context.interactionNotAllowed = !requestAccess
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "com.oozoofrog.CodexMaestro.typesafe",
                                   kSecAttrAccount as String: "api-key", kSecReturnData as String: true,
                                   kSecMatchLimit as String: kSecMatchLimitOne, kSecUseAuthenticationContext as String: context]
        if !requestAccess {
            // LAContext alone does not suppress generic-password ACL approval dialogs.
            // The deprecated Security flag still enforces a noninteractive Keychain lookup.
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var item: CFTypeRef?
        let keychainStatus = SecItemCopyMatching(query as CFDictionary, &item)
        guard keychainStatus == errSecSuccess, let bytes = item as? Data,
              let key = String(data: bytes, encoding: .utf8), !key.isEmpty else {
            print("KEYCHAIN_RESULT status=\(keychainStatus) credentialAvailable=false"); exit(2)
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 90
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            func write(_ data: Data, _ filename: String) throws {
                let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: key, with: "[REDACTED]")
                let url = directory.appendingPathComponent(filename)
                try Data(text.utf8).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            func json(_ value: Any) throws -> Data {
                try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
            }
            func call(_ path: String, body: [String: Any]? = nil) async throws -> (Int, Data) {
                var request = URLRequest(url: URL(string: "https://api.typesafe.ai/\(path)")!)
                request.httpMethod = body == nil ? "GET" : "POST"
                if path.hasPrefix("v1/") { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                if let body { request.httpBody = try json(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                return (http.statusCode, data)
            }
            let (schemaStatus, schema) = try await call("openapi.json")
            guard schemaStatus == 200 else { throw URLError(.badServerResponse) }
            try write(schema, "openapi.json")
            let (catalogStatus, catalog) = try await call("v1/models")
            guard catalogStatus == 200 else { throw URLError(.userAuthenticationRequired) }
            try write(catalog, "models.json")
            let state = "Synthetic verification record. The record is marked synthetic and permits reading only."
            let null = NSNull()
            let boundary: [String: Any] = ["true": "The record is explicitly marked synthetic.", "false": "No synthetic marker is present."]
            func noul(_ instructions: Any? = nil, criteria: Any? = nil) -> [String: Any] {
                var question: [String: Any] = ["type": "noul"]
                if let instructions { question["instructions"] = instructions }
                if let criteria { question["criteria"] = criteria }
                return question
            }
            func score(_ count: Int) -> [String: Any] {
                ["type": "score", "instructions": "Evaluate the explicit synthetic marker using the ordered descriptions.",
                 "criteria": (0..<count).map { "Synthetic marker clarity level \($0) of \(max(count - 1, 1))." }]
            }
            func choice(_ count: Int) -> [String: Any] {
                ["type": "choice", "instructions": "Choose item_0, the explicitly synthetic record.",
                 "criteria": Dictionary(uniqueKeysWithValues: (0..<count).map { ("item_\($0)", $0 == 0 ? "Synthetic record" : "Other record \($0)") })]
            }
            var probes: [(String, [String: Any])] = [
                ("noul-omitted-instructions-valid-criteria", noul(criteria: boundary)),
                ("noul-null-instructions-valid-criteria", noul(null, criteria: boundary)),
                ("noul-no-definition", noul()),
                ("noul-null-definition", noul(null, criteria: null)),
                ("noul-empty-instructions", noul("")),
                ("noul-empty-object-instructions", noul([String: Any]())),
                ("noul-empty-array-instructions", noul([Any]())),
                ("noul-null-instructions-empty-criteria", noul(null, criteria: [String: Any]())),
                ("noul-null-instructions-null-outcomes", noul(null, criteria: ["true": null, "false": null])),
                ("noul-instructions-null-criteria", noul("Is the record explicitly marked synthetic?", criteria: null)),
                ("noul-instructions-empty-criteria", noul("Is the record explicitly marked synthetic?", criteria: [String: Any]())),
                ("noul-whitespace-instructions", noul("   ")),
                ("noul-empty-outcome-descriptions", noul(null, criteria: ["true": "", "false": null])),
                ("noul-empty-structured-outcomes", noul(null, criteria: ["true": [Any](), "false": [String: Any]()])),
                ("noul-outcome-nested-null-object", noul(null, criteria: ["true": ["marker": null], "false": null])),
                ("noul-outcome-nested-null-array", noul(null, criteria: ["true": [null], "false": null])),
                ("noul-false-description-only", noul(null, criteria: ["false": "No synthetic marker is present."])),
                ("noul-whitespace-outcome", noul(null, criteria: ["true": "   "])),
                ("choice-omitted-instructions", ["type": "choice", "criteria": ["synthetic": "Synthetic record", "actual": "Actual record"]]),
                ("score-omitted-instructions", ["type": "score", "criteria": ["No synthetic marker", "Explicit synthetic marker"]]),
                ("score-null-level", ["type": "score", "instructions": "How explicit is the synthetic marker?", "criteria": [null, "Explicit marker"]]),
                ("score-nested-null", ["type": "score", "instructions": "How explicit is the synthetic marker?", "criteria": [["level": "No marker", "example": null], ["level": "Explicit marker", "examples": [null, "synthetic"]]]]),
                ("score-scalar-level", ["type": "score", "instructions": "How explicit is the synthetic marker?", "criteria": [0, "Explicit marker"]])
            ]
            for count in [0, 1, 2, 10, 11] { probes.append(("score-level-count-\(count)", score(count))) }
            for count in [0, 1, 255, 256] { probes.append(("choice-option-count-\(count)", choice(count))) }
            if let filter = CommandLine.arguments.first(where: { $0.hasPrefix("--only=") }) {
                let names = Set(filter.dropFirst("--only=".count).split(separator: ",").map(String.init))
                probes = probes.filter { names.contains($0.0) }
                guard probes.count == names.count else { print("Unknown probe name in --only"); exit(2) }
            }
            var observations: [[String: Any]] = []
            var inputTokens = 0, outputTokens = 0, successes = 0
            for (name, question) in probes {
                let request: [String: Any] = ["state": state, "model": "jev-latest", "questions": ["q": question]]
                try write(try json(request), name + "-request.json")
                let start = Date()
                let (status, data) = try await call("v1/systemone", body: request)
                try write(data, name + "-response.json")
                var observation: [String: Any] = ["name": name, "status": status, "elapsedMs": Int(Date().timeIntervalSince(start) * 1000)]
                if let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    observation["model"] = response["model"]
                    observation["detail"] = response["detail"]
                    if let usage = response["usage"] as? [String: Int] {
                        inputTokens += usage["input_tokens"] ?? 0; outputTokens += usage["output_tokens"] ?? 0
                    }
                    if let answers = response["answers"] as? [String: Any], let answer = answers["q"] as? [String: Any] {
                        observation["answer"] = answer
                    }
                }
                if status == 200 { successes += 1 }
                observations.append(observation)
                print("OBSERVED name=\(name) status=\(status) elapsedMs=\(observation["elapsedMs"]!)")
                fflush(stdout)
                if status == 401 || status == 403 || status == 429 || status >= 500 {
                    try write(try json(observations), "observations.json")
                    throw URLError(.badServerResponse)
                }
            }
            try write(try json(["observedAt": ISO8601DateFormatter().string(from: Date()), "observations": observations,
                                "successes": successes, "rejections": probes.count - successes,
                                "inputTokens": inputTokens, "outputTokens": outputTokens,
                                "syntheticInputOnly": true, "credentialInEvidence": false]), "observations.json")
            print("COMPATIBILITY_COMPLETED observations=\(probes.count) successes=\(successes) rejections=\(probes.count - successes) inputTokens=\(inputTokens) outputTokens=\(outputTokens)")
        } catch {
            print("COMPATIBILITY_STOPPED \(error.localizedDescription.replacingOccurrences(of: key, with: "[REDACTED]"))")
            exit(1)
        }
    }
}
