import LocalAuthentication

enum Biometric {
    /// Face ID / Touch ID (falls back to the device passcode). Returns true on
    /// success. Used to gate the Locked Folder.
    static func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Code eingeben"
        var err: NSError?
        let policy: LAPolicy = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication
        return await withCheckedContinuation { cont in
            ctx.evaluatePolicy(policy, localizedReason: reason) { ok, _ in
                cont.resume(returning: ok)
            }
        }
    }
}

/// Album titles that Google Takeout uses for hidden/deleted content.
enum SpecialAlbum {
    static func isLocked(_ title: String) -> Bool {
        ["Locked Folder", "Gesperrter Ordner"].contains(title)
    }
    static func isTrash(_ title: String) -> Bool {
        ["Trash", "Papierkorb", "Bin"].contains(title)
    }
}
