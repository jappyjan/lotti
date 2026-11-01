import Foundation
import FoundationModels

/// Spike S3: logs what the on-device and cloud Apple models report on this phone.
enum BrainProbe {
    static func logAvailability() async {
        guard #available(iOS 27.0, *) else {
            print("[Eval] probe: needs iOS 27")
            return
        }
        let system = SystemLanguageModel.default
        print("[Eval] probe: apple availability=\(system.availability)")
        print("[Eval] probe: apple contextSize=\(system.contextSize) variant=\(system.variant.displayName)")
        let languages = system.supportedLanguages.map { $0.minimalIdentifier }.sorted()
        print("[Eval] probe: apple languages=\(languages.joined(separator: ","))")
        let pcc = PrivateCloudComputeLanguageModel()
        print("[Eval] probe: pcc availability=\(pcc.availability) quota=\(pcc.quotaUsage)")
        do {
            print("[Eval] probe: pcc contextSize=\(try await pcc.contextSize)")
        } catch {
            print("[Eval] probe: pcc contextSize error=\(error)")
        }
    }
}
