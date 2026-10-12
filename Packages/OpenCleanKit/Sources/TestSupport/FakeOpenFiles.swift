import Quarantine

public struct FakeOpenFiles: OpenFilesProvider {
    struct Unavailable: Error {}
    let paths: Set<String>?

    public init(_ paths: Set<String>? = []) {
        self.paths = paths
    }

    public func openPaths() throws -> Set<String> {
        guard let paths else { throw Unavailable() }
        return paths
    }
}
