import AppInventory
import Foundation
import Maintenance
import Quarantine
import RuleKit
import SpaceKit

// Translated names for the shared libraries' enums. The libraries stay English-only (the CLI and its JSON
// use their strings), so the app maps them here. Keep these in step with the libraries' English text.

extension RuleCategory {
    /// `displayName`, translated.
    var localizedName: String {
        switch self {
        case .system: String(localized: "System Junk")
        case .user: String(localized: "User Caches & Logs")
        case .browsers: String(localized: "Browser Caches")
        case .developer: String(localized: "Developer Tools")
        case .ai: String(localized: "AI Models & Caches")
        case .mail: String(localized: "Mail Attachments")
        case .trash: String(localized: "Trash")
        case .ios: String(localized: "iOS Backups")
        }
    }
}

extension FileKind {
    /// `displayName`, translated.
    var localizedName: String {
        switch self {
        case .video: String(localized: "Videos")
        case .archive: String(localized: "Archives")
        case .diskImage: String(localized: "Disk images")
        case .installer: String(localized: "Installers")
        case .other: String(localized: "Other files")
        }
    }
}

extension MaintenanceTask {
    /// `title`, translated.
    var localizedTitle: String {
        switch self {
        case .flushDNSCache: String(localized: "Flush DNS cache")
        case .reindexSpotlight: String(localized: "Reindex Spotlight")
        case .rebuildLaunchServices: String(localized: "Rebuild Launch Services database")
        case .runPeriodicScripts: String(localized: "Run maintenance scripts")
        case .thinLocalSnapshots: String(localized: "Thin Time Machine local snapshots")
        }
    }

    /// `explanation`, translated.
    var localizedExplanation: String {
        switch self {
        case .flushDNSCache:
            String(
                localized:
                    "Forgets cached website addresses, so name lookups start fresh. Helps when a site moved or won't load after a network change."
            )
        case .reindexSpotlight:
            String(
                localized:
                    "Erases and rebuilds the Spotlight index for your startup disk. Use it when search misses files. Rebuilding runs in the background and can take an hour or more."
            )
        case .rebuildLaunchServices:
            String(
                localized:
                    "Rebuilds the list that decides which app opens which file and what appears in “Open With”. Fixes duplicate or missing entries. Default apps you chose may need choosing again."
            )
        case .runPeriodicScripts:
            String(
                localized:
                    "Runs the daily, weekly and monthly housekeeping scripts macOS ships with (log rotation, temporary file cleanup). macOS normally runs them on its own."
            )
        case .thinLocalSnapshots:
            String(
                localized:
                    "Asks macOS to remove the local Time Machine snapshots it can drop to free space. Backups on your backup disk are not touched."
            )
        }
    }
}

extension EntryOutcome {
    /// What happened to a History entry, translated.
    var localizedName: String {
        switch self {
        case .pending: String(localized: "Pending")
        case .deleted: String(localized: "Deleted")
        case .quarantined: String(localized: "Quarantined")
        case .trashed: String(localized: "Moved to Trash")
        case .skipped: String(localized: "Skipped")
        case .failed: String(localized: "Failed")
        case .restored: String(localized: "Restored")
        case .purged: String(localized: "Expired and deleted")
        }
    }
}

extension AppStatus {
    /// `explanation`, translated.
    var localizedExplanation: String {
        switch self {
        case .removable: String(localized: "Can be moved to quarantine")
        case .appleApp: String(localized: "Apple app — part of macOS, never removed")
        case .openClean: String(localized: "This is OpenClean itself")
        case .needsAdministrator: String(localized: "Needs your administrator password to uninstall")
        case .listOnly: String(localized: "In Utilities — listed for information only")
        case .noBundleID: String(localized: "Has no bundle identifier, so it can't be checked safely")
        }
    }
}
