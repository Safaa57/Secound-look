import IdentityLookup
import JavaScriptCore

/// SMS Shield for iPhone. iOS gives this extension messages from UNKNOWN senders only.
/// It runs the same on-device engine and sorts scams into the Junk folder.
/// Apple sandboxes it: no network (we don't use any), and it can't save or share message content.
final class MessageFilterExtension: ILMessageFilterExtension {
    private static var context: JSContext? = {
        guard let url = Bundle.main.url(forResource: "secondlook_engine", withExtension: "js"),
              let src = try? String(contentsOf: url, encoding: .utf8),
              let ctx = JSContext() else { return nil }
        ctx.evaluateScript(src)
        return ctx
    }()

    /// True if the user's own marks ("reports" in the shared app group, written by the app) block this sender:
    /// Block, Fraud or Spam. Phone numbers match on their last 10 digits; SMS headers match exactly.
    fileprivate static func userMarked(_ sender: String, _ shared: UserDefaults?) -> Bool {
        guard !sender.isEmpty, let s = shared?.string(forKey: "reports"), let data = s.data(using: .utf8),
              let reports = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
        let digits = sender.filter { $0.isASCII && $0.isNumber }
        let isPhone = !sender.contains(where: { $0.isLetter }) && digits.count >= 6
        let header = sender.uppercased()
        for r in reports {
            guard let n = r["number"] as? String else { continue }
            let kind = r["kind"] as? String ?? ""
            guard (r["blocked"] as? Bool ?? false) || kind == "scam" || kind == "spam" else { continue }
            if isPhone {
                let nd = n.filter { $0.isASCII && $0.isNumber }
                if nd.count >= 6 && nd.suffix(10) == digits.suffix(10) { return true }
            } else if n.uppercased() == header {
                return true
            }
        }
        return false
    }

    fileprivate func verdict(sender: String, body: String) -> [String: Any]? {
        guard let s = Self.context?.objectForKeyedSubscript("SL")?.invokeMethod("analyzeSms", withArguments: [sender, body])?.toString(),
              let data = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

extension MessageFilterExtension: ILMessageFilterQueryHandling {
    func handle(_ queryRequest: ILMessageFilterQueryRequest, context: ILMessageFilterExtensionContext,
                completion: @escaping (ILMessageFilterQueryResponse) -> Void) {
        let response = ILMessageFilterQueryResponse()
        response.action = .none

        // Respect the ON/OFF switch in the app (read-only shared setting).
        let shared = UserDefaults(suiteName: "group.com.secondlook.shared")
        if shared?.object(forKey: "sms_on") != nil && shared?.bool(forKey: "sms_on") == false {
            completion(response)
            return
        }

        let sender = queryRequest.sender ?? ""
        let body = queryRequest.messageBody ?? ""

        // Senders the user blocked or marked as fraud/spam in the app go straight to Junk.
        if Self.userMarked(sender, shared) {
            response.action = .junk
            completion(response)
            return
        }
        guard let r = verdict(sender: sender, body: body),
              let level = (r["level"] as? [String: Any])?["key"] as? String else {
            completion(response)
            return
        }

        if level == "danger" || level == "warning" {
            response.action = .junk
        } else if let s = (r["info"] as? [String: Any])?["sender"] as? [String: Any], let type = s["type"] as? String {
            // Registered business senders: sort by the TRAI suffix.
            if type == "Transactional" || type == "Service" || type == "Government" {
                response.action = .transaction
            } else if type == "Promotional" {
                response.action = .promotion
            }
        }
        completion(response)
    }
}
