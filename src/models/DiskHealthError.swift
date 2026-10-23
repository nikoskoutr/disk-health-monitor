// ============================================================================
// File: DiskHealthError.swift
// Module: Layer 2 (Infrastructure & Models)
// Purpose: Strongly-typed domain error enumeration covering hardware queries,
//          filesystem states, canary failures, keychain security, and alerts.
// Concurrency: Sendable value type.
// ============================================================================

import Foundation

/// Strongly typed errors produced across storage telemetry, configuration, and alerting.
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
    case keychainAccessDenied(status: Int32)
    case keychainOperationFailed(status: Int32)
    case fileWriteFailed(path: String, underlying: String)
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
        case .keychainAccessDenied(let status):
            return "macOS Keychain access was denied or cancelled by the user (OSStatus \(status)). Using local restricted storage (.secrets.json 0600)."
        case .keychainOperationFailed(let status):
            return "macOS Keychain operation failed (OSStatus \(status))."
        case .fileWriteFailed(let path, let underlying):
            return "Failed to write file at '\(path)': \(underlying)"
        case .alertDeliveryFailed(let channel, let reason):
            return "Alert delivery failed on \(channel): \(reason)"
        case .scriptNotExecutable(let path):
            return "Alert script is not executable: \(path)"
        case .scriptExecutionFailed(let code, let output):
            return "Alert script failed with exit code \(code): \(output)"
        }
    }
}
