// Link against the freshly built MaestroCore. Pass one or more captured evidence directories.
// Reads synthetic request/response files only. No network or credential access.
import Foundation
import MaestroCore

private struct Observation: Decodable { let name: String; let status: Int }
private struct Capture: Decodable { let observations: [Observation] }

@main struct DecisionAPIReplay {
    static func main() throws {
        guard CommandLine.arguments.count > 1 else {
            print("Usage: replay EVIDENCE_DIRECTORY [EVIDENCE_DIRECTORY ...]"); exit(2)
        }
        var accepted = 0, rejected = 0, failures = 0
        for path in CommandLine.arguments.dropFirst() {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            let capture = try JSONDecoder().decode(Capture.self, from: Data(contentsOf: directory.appendingPathComponent("observations.json")))
            for observation in capture.observations {
                let request = try JSONDecoder().decode(DecisionRequest.self, from: Data(contentsOf: directory.appendingPathComponent(observation.name + "-request.json")))
                let responseData = try Data(contentsOf: directory.appendingPathComponent(observation.name + "-response.json"))
                do {
                    try request.validate()
                    guard observation.status == 200 else {
                        failures += 1
                        print("PARITY_FAIL name=\(observation.name) serverStatus=\(observation.status) local=accepted")
                        continue
                    }
                    let response = try DecisionResponse.decode(responseData, for: request)
                    guard response.rawData == responseData, response.answers.count == request.questions.count else {
                        failures += 1; print("PARITY_FAIL name=\(observation.name) responsePreservation=false"); continue
                    }
                    accepted += 1
                    print("PARITY_PASS name=\(observation.name) serverStatus=200 local=accepted model=\(response.model)")
                } catch {
                    if observation.status == 400 || observation.status == 422, case DecisionFailure.invalid = error {
                        rejected += 1
                        print("PARITY_PASS name=\(observation.name) serverStatus=\(observation.status) local=rejected detail=\(error.localizedDescription)")
                    } else {
                        failures += 1
                        print("PARITY_FAIL name=\(observation.name) serverStatus=\(observation.status) detail=\(error.localizedDescription)")
                    }
                }
            }
        }
        print("PARITY_COMPLETED observations=\(accepted + rejected + failures) accepted=\(accepted) rejected=\(rejected) failures=\(failures) networkCalls=0 credentialReads=0")
        if failures > 0 { exit(1) }
    }
}
