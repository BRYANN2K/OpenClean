import ScanEngine

extension ProbeRegistry {
    /// Every probe shipped with OpenClean v1.
    public static var standard: ProbeRegistry {
        ProbeRegistry([
            XcodeSimulatorsProbe(), HomebrewCacheProbe(), DockerDiskImageProbe(), TimeMachineSnapshotsProbe(),
        ])
    }
}
