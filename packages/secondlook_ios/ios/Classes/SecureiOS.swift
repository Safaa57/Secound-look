import CryptoKit
import Foundation
import LocalAuthentication
import MachO
import Security
import UIKit

/// iPhone self-protection for Second Look.
enum SLSecurity {
    // MARK: Encrypted storage (AES-GCM, key kept in the Keychain on this device only)

    private static let keyTag = "com.secondlook.storage.v1"

    private static func storageKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyTag,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyTag,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return nil }
        return key
    }

    static func encrypt(_ s: String) -> String? {
        guard let key = storageKey(), let sealed = try? AES.GCM.seal(Data(s.utf8), using: key), let combined = sealed.combined else { return nil }
        return "enc1:" + combined.base64EncodedString()
    }

    static func decrypt(_ s: String?) -> String? {
        guard let s = s, s.hasPrefix("enc1:"), let data = Data(base64Encoded: String(s.dropFirst(5))),
              let key = storageKey(), let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    static func wipeKey() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keyTag] as CFDictionary)
    }

    // MARK: Device and app integrity

    static var jailbroken: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        let paths = ["/Applications/Cydia.app", "/Applications/Sileo.app", "/var/jb", "/Library/MobileSubstrate/MobileSubstrate.dylib",
                     "/bin/bash", "/usr/sbin/sshd", "/etc/apt", "/private/var/lib/apt/", "/usr/libexec/sftp-server"]
        if paths.contains(where: { FileManager.default.fileExists(atPath: $0) }) { return true }
        let probe = "/private/sl_jb_probe.txt"
        if (try? "x".write(toFile: probe, atomically: true, encoding: .utf8)) != nil {
            try? FileManager.default.removeItem(atPath: probe)
            return true
        }
        return false
        #endif
    }

    /// Frida, Substrate and similar hooking libraries loaded into our process.
    static var hooking: Bool {
        let bad = ["frida", "substrate", "substitute", "libhooker", "cycript", "sslkillswitch", "ellekit"]
        for i in 0..<_dyld_image_count() {
            guard let c = _dyld_get_image_name(i) else { continue }
            let name = String(cString: c).lowercased()
            if bad.contains(where: { name.contains($0) }) { return true }
        }
        return false
    }

    static var debuggerAttached: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return false }
        #if DEBUG
        return false
        #else
        return (info.kp_proc.p_flag & P_TRACED) != 0
        #endif
    }

    static var screenCaptured: Bool { UIScreen.main.isCaptured }

    // MARK: App lock (Face ID / Touch ID / passcode)

    static func authenticate(_ done: @escaping (Bool) -> Void) {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { done(true); return } // no passcode set
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Second Look") { ok, _ in
            DispatchQueue.main.async { done(ok) }
        }
    }

    static var deviceHasPasscode: Bool { LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) }

    // MARK: Input validation

    /// Only our own fixed destinations, matched in full (same list as Android).
    static func urlAllowed(_ s: String) -> Bool {
        let pattern = "^https://(docs\\.cloud\\.google\\.com/web-risk/docs/advisory|www\\.antiphishing\\.org/?|www\\.google\\.com/search\\?q=[A-Za-z0-9%+._-]{1,200}|cybercrime\\.gov\\.in/?|sancharsaathi\\.gov\\.in/?)$"
        return s.count < 600 && s.range(of: pattern, options: .regularExpression) != nil
    }

    static func cleanNumber(_ s: String) -> String { String(s.filter { "+0123456789".contains($0) }.prefix(20)) }
}

/// Covers the app with a blur when it goes to the background, so its contents never appear
/// in the app switcher or in system snapshots.
final class SLPrivacyCover: NSObject {
    static let shared = SLPrivacyCover()
    private var cover: UIView?

    func start() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(hide), name: UIApplication.willResignActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(show), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    private var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }.first { $0.isKeyWindow }
    }

    @objc private func hide() {
        guard cover == nil, let w = window else { return }
        let v = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        v.frame = w.bounds
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        w.addSubview(v)
        cover = v
    }

    @objc private func show() {
        cover?.removeFromSuperview()
        cover = nil
    }
}
