import Foundation

/// Rough kind of a large file, by extension. Used only for grouping in the UI.
public enum FileKind: String, Sendable, CaseIterable, Equatable {
    case video, archive, diskImage, installer, other

    public var displayName: String {
        switch self {
        case .video: "Videos"
        case .archive: "Archives"
        case .diskImage: "Disk images"
        case .installer: "Installers"
        case .other: "Other files"
        }
    }

    static let byExtension: [String: FileKind] = {
        var map: [String: FileKind] = [:]
        let table: [(FileKind, [String])] = [
            (.video, ["mp4", "mov", "m4v", "mkv", "avi", "wmv", "flv", "webm", "mpg", "mpeg", "mts", "m2ts", "3gp"]),
            (.archive, ["zip", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "7z", "rar", "zst", "lz4", "cpio"]),
            (
                .diskImage,
                [
                    "iso", "img", "sparseimage", "sparsebundle", "vmdk", "vdi", "vhd", "vhdx", "qcow2", "toast", "pvm",
                    "utm", "vmwarevm",
                ]
            ),
            (.installer, ["dmg", "pkg", "mpkg", "xip"]),
        ]
        for (kind, extensions) in table {
            for ext in extensions { map[ext] = kind }
        }
        return map
    }()

    /// The kind for a file name, by its last extension (case-insensitive).
    public init(fileName: String) {
        let ext = (fileName as NSString).pathExtension.lowercased()
        self = Self.byExtension[ext] ?? .other
    }
}
