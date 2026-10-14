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
