import LocalAuthentication

enum Biometric {
    /// Face ID / Touch ID (falls back to the device passcode). Returns true on
    /// success. Used to gate the Locked Folder.
    static func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        #if os(macOS)
        // Touch ID, or the login password on a Mac without it (or with the lid closed)
        let policy = LAPolicy.deviceOwnerAuthentication
        #else
        ctx.localizedFallbackTitle = "Enter Passcode"
        var err: NSError?
        let policy: LAPolicy = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication
        #endif
        return await withCheckedContinuation { cont in
            ctx.evaluatePolicy(policy, localizedReason: reason) { ok, _ in
                cont.resume(returning: ok)
            }
        }
    }
}
