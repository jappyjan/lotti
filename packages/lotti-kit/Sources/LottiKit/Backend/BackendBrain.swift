import Foundation

/// The backend as a brain: asks Lotti Brain over the live socket and turns the answer into an
/// `Answer` for the glasses. Status lines come from the backend's `status` messages; cancelling
/// the calling task sends `cancel`.
@MainActor
public final class BackendBrain: RemoteBrain {
    private let client: BackendClient
    private let channel: BackendChannel

    public init(client: BackendClient, channel: BackendChannel = .glasses) {
        self.client = client
        self.channel = channel
    }

    public var isReachable: Bool { client.isReachable }

    public func answer(
        _ message: String, context: String,
        status: @escaping @MainActor (String) -> Void,
        activity: @escaping @MainActor () -> Void
    ) async throws -> Answer {
        try await client.ask(message, channel: channel, status: status, activity: activity).answer
    }
}
