import CallKit
import Foundation

/// Call Shield for iPhone. iOS doesn't let apps see incoming calls, so this extension gives the system
/// a list ahead of time:
/// - numbers the user reported are blocked and labelled; trusted ones are labelled;
/// - numbers many Second Look users reported (the downloaded community list) are labelled, and blocked
///   when at least 10 people reported them as a scam.
/// Nothing about incoming calls is ever sent anywhere.
final class CallDirectoryHandler: CXCallDirectoryProvider {
    private static let group = "group.com.secondlook.shared"
    private static let blockAt = 10

    override func beginRequest(with context: CXCallDirectoryExtensionContext) {
        context.delegate = self
        let shared = UserDefaults(suiteName: Self.group)
        if context.isIncremental { context.removeAllBlockingEntries(); context.removeAllIdentificationEntries() }
        guard shared?.bool(forKey: "call_on") == true else {
            context.completeRequest()
            return
        }

        // number -> (block?, label). The user's own choices win over the community list.
        var entries: [CXCallDirectoryPhoneNumber: (Bool, String)] = [:]

        if shared?.string(forKey: "pref_community_off") != "1",
           let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.group)?.appendingPathComponent("community.json"),
           let data = try? Data(contentsOf: url),
           let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let nums = o["numbers"] as? [String: Any] {
            for (k, v) in nums {
                guard let m = v as? [String: Any], let num = CXCallDirectoryPhoneNumber(k.filter { $0.isNumber }) else { continue }
                let scam = (m["s"] as? Int) ?? 0, spam = (m["p"] as? Int) ?? 0
                if scam > 0 {
                    entries[num] = (scam >= Self.blockAt, "Second Look: reported scam (\(scam))")
                } else if spam > 0 {
                    entries[num] = (false, "Second Look: reported spam (\(spam))")
                }
            }
        }

        if let s = shared?.string(forKey: "reports"), let data = s.data(using: .utf8),
           let reports = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for r in reports {
                guard let n = r["number"] as? String, let num = CXCallDirectoryPhoneNumber(n.filter { $0.isNumber }) else { continue }
                let kind = r["kind"] as? String ?? "scam"
                let text = r["label"] as? String ?? "Reported"
                if kind == "safe" {
                    entries[num] = (false, "Trusted · \(text)")
                } else {
                    entries[num] = (kind == "scam", "Second Look: \(text)")
                }
            }
        }

        // CallKit needs numbers in ascending order, each added once.
        let sorted = entries.keys.sorted()
        for n in sorted where entries[n]!.0 { context.addBlockingEntry(withNextSequentialPhoneNumber: n) }
        for n in sorted { context.addIdentificationEntry(withNextSequentialPhoneNumber: n, label: entries[n]!.1) }
        context.completeRequest()
    }
}

extension CallDirectoryHandler: CXCallDirectoryExtensionContextDelegate {
    func requestFailed(for extensionContext: CXCallDirectoryExtensionContext, withError error: Error) {
        NSLog("Second Look call directory failed: \(error)")
    }
}
