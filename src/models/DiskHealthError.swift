import Foundation

enum DiskHealthError: LocalizedError, Sendable, Equatable {
    case hardwareNotFound(query: String)
    case volumeNotMounted(path: String)
    case volumeReadOnly(path: String)
    case canaryFailed(reason: String)
    case surfaceScanFailed(reason: String, readErrors: Int)
    case verificationAlreadyInProgress
    case verificationFailed(summary: String)
    case configurationInvalid(reason: String)
    case secretStoreFailure(key: String)
    case alertDeliveryFailed(channel: String, reason: String)
    case scriptNotExecutable(path: String)
    case scriptExecutionFailed(exitCode: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .hardwareNotFound(let query):
            return "Storage hardware not found for query '\(query)'."
        case .volumeNotMounted(let path):
            return "Target volume '\(path)' is not currently mounted."
        case .volumeReadOnly(let path):
            return "Target volume '\(path)' is mounted read-only."
        case .canaryFailed(let reason):
            return "Filesystem canary probe failed: \(reason)"
        case .surfaceScanFailed(let reason, let errors):
            return "Surface scan failed (\(errors) read errors): \(reason)"
        case .verificationAlreadyInProgress:
            return "Verification already in progress"
        case .verificationFailed(let summary):
            return "Volume verification failed: \(summary)"
        case .configurationInvalid(let reason):
            return "Invalid configuration: \(reason)"
        case .secretStoreFailure(let key):
            return "Failed to access or persist secret for key '\(key)'."
        case .alertDeliveryFailed(let channel, let reason):
            return "Alert delivery failed on \(channel): \(reason)"
        case .scriptNotExecutable(let path):
            return "Alert script is not executable: \(path)"
        case .scriptExecutionFailed(let code, let output):
            return "Alert script failed with exit code \(code): \(output)"
        }
    }
}
