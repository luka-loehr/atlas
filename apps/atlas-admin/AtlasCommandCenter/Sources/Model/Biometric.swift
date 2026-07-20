import LocalAuthentication

enum Biometric {
    /// Face ID / Touch ID (falls back to the device passcode). Returns true on
    /// success. Gates the terminal: metrics are free to read, a shell is not.
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
