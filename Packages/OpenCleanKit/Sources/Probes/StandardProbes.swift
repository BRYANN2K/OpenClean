import ScanEngine

extension ProbeRegistry {
    /// Every probe shipped with OpenClean.
    public static var standard: ProbeRegistry {
        ProbeRegistry([
            XcodeSimulatorsProbe(), HomebrewCacheProbe(), DockerDiskImageProbe(), TimeMachineSnapshotsProbe(),
            NodeModulesProbe(), PythonVirtualEnvProbe(), RustTargetProbe(), ProjectBuildOutputProbe(),
        ])
    }
}
