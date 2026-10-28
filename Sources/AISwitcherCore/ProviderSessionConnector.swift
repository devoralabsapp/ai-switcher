import Foundation

/// Interactive authentication is entered only by an explicit Connect action, never by a refresh.
@MainActor
public enum ProviderSessionConnector {
    public static func connect(
        read: () async throws -> CodexConnection,
        signIn: () async throws -> Void,
        maxAttempts: Int = 100,
        pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 3_000_000_000) }
    ) async throws -> CodexConnection {
        try Task.checkCancellation()
        do { return try await read() }
        catch ProviderQuotaError.signedOut { }
        try Task.checkCancellation()
        try await signIn()
        for _ in 0..<max(0, maxAttempts) {
            try Task.checkCancellation()
            try await pause()
            do { return try await read() }
            catch ProviderQuotaError.signedOut { }
        }
        throw ProviderQuotaError.signedOut
    }
}
