import Foundation
import Observation
import OpenCleanKit

/// State behind the Space Lens module. Views read it and call its actions; it never touches files itself.
@MainActor
@Observable
public final class SpaceLensModel {
    @ObservationIgnored let coordinator: OpenCleanCoordinator

    public init(coordinator: OpenCleanCoordinator) {
        self.coordinator = coordinator
    }
}
