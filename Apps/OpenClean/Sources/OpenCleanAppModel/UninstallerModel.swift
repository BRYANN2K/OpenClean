import Foundation
import Observation
import OpenCleanKit

/// State behind the Uninstaller module. Views read it and call its actions; it never touches files itself.
@MainActor
@Observable
public final class UninstallerModel {
    @ObservationIgnored let coordinator: OpenCleanCoordinator

    public init(coordinator: OpenCleanCoordinator) {
        self.coordinator = coordinator
    }
}
