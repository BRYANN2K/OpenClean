import Foundation
import RuleKit
import ScanEngine

/// Reports Docker Desktop's virtual disk size. Never removable: Docker data is managed by Docker.
public struct DockerDiskImageProbe: Probe {
    public static let id = "docker.disk-image"

    public init() {}

    public func scan(_ context: ScanContext) async throws -> [ProbeFinding] {
        let candidates = [
            "/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
            "/Library/Containers/com.docker.docker/Data/vms/0/Docker.raw",
        ].map { context.home + $0 }
        return candidates.filter { FileStat.of($0) != nil }.map {
            ProbeFinding(
                path: $0, reportOnly: true,
                hint: "Docker Desktop's virtual disk. Reclaim space with `docker system prune` or Docker Desktop → Settings → Resources.")
        }
    }
}
