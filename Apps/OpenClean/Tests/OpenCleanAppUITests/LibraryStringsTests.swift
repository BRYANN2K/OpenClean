import AppInventory
import Maintenance
import RuleKit
import SpaceKit
import Testing

@testable import OpenCleanApp

/// The app translates the shared libraries' names (`LibraryStrings.swift`); the libraries stay English for the
/// CLI. In English both must say the same thing, so a change in a library shows up here.
@Suite struct LibraryStringsTests {
    @Test func translatedNamesMatchTheLibrariesInEnglish() {
        for category in RuleCategory.allCases {
            #expect(category.localizedName == category.displayName)
        }
        for kind in FileKind.allCases {
            #expect(kind.localizedName == kind.displayName)
        }
        for task in MaintenanceTask.allCases {
            #expect(task.localizedTitle == task.title)
            #expect(task.localizedExplanation == task.explanation)
        }
        let statuses: [AppStatus] = [.removable, .appleApp, .openClean, .needsAdministrator, .listOnly, .noBundleID]
        for status in statuses {
            #expect(status.localizedExplanation == status.explanation)
        }
    }
}
