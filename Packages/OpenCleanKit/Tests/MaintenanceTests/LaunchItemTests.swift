import Foundation
import Testing

@testable import Maintenance

func plistData(_ object: [String: Any], format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: object, format: format, options: 0)
}

struct LaunchItemParserTests {
    @Test func programArgumentsFirstElementIsTheProgram() throws {
        let definition = try LaunchItemParser.parse(
            plistData([
                "Label": "com.example.agent", "ProgramArguments": ["/usr/local/bin/tool", "--serve"],
                "RunAtLoad": true, "KeepAlive": true,
            ]))
        #expect(definition.label == "com.example.agent")
        #expect(definition.program == "/usr/local/bin/tool")
        #expect(definition.arguments == ["/usr/local/bin/tool", "--serve"])
        #expect(definition.runAtLoad)
        #expect(definition.keepAlive == .always)
        #expect(!definition.disabledInPlist)
    }

    @Test func programKeyWinsOverProgramArguments() throws {
        let definition = try LaunchItemParser.parse(
            plistData(["Label": "x", "Program": "/opt/x/run", "ProgramArguments": ["ignored-argv0", "-v"]]))
        #expect(definition.program == "/opt/x/run")
        #expect(definition.arguments == ["ignored-argv0", "-v"])
    }

    @Test func missingOptionalKeysTakeLaunchdDefaults() throws {
        let definition = try LaunchItemParser.parse(plistData(["Label": "only.label"]))
        #expect(definition.program == nil)
        #expect(definition.arguments.isEmpty)
        #expect(!definition.runAtLoad)
        #expect(definition.keepAlive == .no)
        #expect(!definition.disabledInPlist)
    }

    @Test func keepAliveDictionaryIsConditionalAndDisabledKeyIsRead() throws {
        let definition = try LaunchItemParser.parse(
            plistData(
                ["Label": "x", "KeepAlive": ["SuccessfulExit": false], "Disabled": true, "RunAtLoad": "yes"],
                format: .binary))
        #expect(definition.keepAlive == .conditional)
        #expect(definition.disabledInPlist)
        #expect(!definition.runAtLoad, "a non-bool RunAtLoad is ignored")
    }

    @Test func malformedAndIncompletePlistsAreRejected() throws {
        #expect(throws: LaunchItemParseError.unreadable) { try LaunchItemParser.parse(Data("not a plist <".utf8)) }
        #expect(throws: LaunchItemParseError.notADictionary) {
            try LaunchItemParser.parse(
                PropertyListSerialization.data(fromPropertyList: ["a"], format: .xml, options: 0))
        }
        #expect(throws: LaunchItemParseError.missingLabel) { try LaunchItemParser.parse(plistData(["Program": "/x"])) }
        #expect(throws: LaunchItemParseError.missingLabel) { try LaunchItemParser.parse(plistData(["Label": ""])) }
        #expect(throws: LaunchItemParseError.missingLabel) { try LaunchItemParser.parse(plistData(["Label": 42])) }
    }
}

struct OwnerResolverTests {
    let apps = [
        InstalledApp(name: "Google Chrome", bundleID: "com.google.Chrome", path: "/Applications/Google Chrome.app"),
        InstalledApp(name: "Zoom", bundleID: "us.zoom.xos", path: "/Applications/zoom.us.app"),
        InstalledApp(name: "Tool", bundleID: "com.vendor.tool", path: "/Applications/Tool.app"),
        InstalledApp(name: "Tool Pro", bundleID: "com.vendor.tool.pro", path: "/Applications/Tool Pro.app"),
        InstalledApp(name: "Other", bundleID: "com.vendor.other", path: "/Applications/Other.app"),
    ]

    func resolver() -> OwnerResolver {
        OwnerResolver(apps: apps) { path in
            path == "/Applications/Helper Host.app" ? (name: "Helper Host", bundleID: "org.host.app") : nil
        }
    }

    @Test func programInsideAnAppBundleOwnsIt() throws {
        let owner = try #require(
            resolver().owner(
                of: LaunchItemDefinition(
                    label: "anything",
                    program: "/Applications/Helper Host.app/Contents/Library/LaunchServices/helper")))
        #expect(
            owner
                == LaunchItemOwner(
                    appName: "Helper Host", bundleID: "org.host.app", bundlePath: "/Applications/Helper Host.app",
                    confidence: .exact))

        let unknownBundle = try #require(
            resolver().owner(
                of: LaunchItemDefinition(label: "x", program: "/Users/u/Apps/Gone.app/Contents/MacOS/gone")))
        #expect(unknownBundle.appName == "Gone")
        #expect(unknownBundle.bundleID == nil)
    }

    @Test func labelMatchingBundleIDPrefersTheLongestMatch() throws {
        let owner = try #require(
            resolver().owner(of: LaunchItemDefinition(label: "com.vendor.tool.pro.agent", program: nil)))
        #expect(owner.appName == "Tool Pro")
        #expect(owner.confidence == .exact)
        let exact = try #require(resolver().owner(of: LaunchItemDefinition(label: "COM.GOOGLE.CHROME", program: nil)))
        #expect(exact.appName == "Google Chrome")
        #expect(
            resolver().owner(of: LaunchItemDefinition(label: "com.vendor.toolbox", program: nil)) == nil,
            "prefix must end at a dot boundary, and com.vendor has several apps")
    }

    @Test func vendorPrefixIsOnlyALikelyMatchWhenUnambiguous() throws {
        let owner = try #require(
            resolver().owner(of: LaunchItemDefinition(label: "com.google.keystone.agent", program: "/x")))
        #expect(owner.appName == "Google Chrome")
        #expect(owner.confidence == .likely)
        #expect(resolver().owner(of: LaunchItemDefinition(label: "com.apple.something.agent", program: nil)) == nil)
        #expect(resolver().owner(of: LaunchItemDefinition(label: "BrowserStackLocal", program: nil)) == nil)
    }
}

struct LaunchctlTests {
    @Test func parsesLaunchctlListDefensively() {
        let output = """
            PID\tStatus\tLabel
            94101\t-9\tcom.example.running
            -\t0\tcom.example.idle
            garbage line without tabs
            abc\t0\tcom.example.badpid
            -\t0\tlabel\twith\ttabs

            """
        let entries = LaunchctlParser.parseList(output)
        #expect(entries["com.example.running"] == .init(pid: 94101, lastExitStatus: -9))
        #expect(entries["com.example.idle"] == .init(pid: nil, lastExitStatus: 0))
        #expect(entries["com.example.badpid"] == nil)
        #expect(entries["label\twith\ttabs"] != nil)
        #expect(entries["Label"] == nil)
        #expect(entries.count == 3)
    }

    @Test func parsesPrintDisabledInBothForms() {
        let output = """
            \tdisabled services = {
            \t\t"com.apple.FolderActionsDispatcher" => disabled
            \t\t"sh.brew.redis" => enabled
            \t\t"old.style.on" => false
            \t\t"old.style.off" => true
            \t\t"weird" => maybe
            \t}
            nonsense
            """
        let disabled = LaunchctlParser.parseDisabled(output)
        #expect(
            disabled == [
                "com.apple.FolderActionsDispatcher": true, "sh.brew.redis": false, "old.style.on": false,
                "old.style.off": true,
            ])
    }

    @Test func buildsExactArgv() throws {
        #expect(try LaunchctlCommand.bootout(uid: 501, label: "com.x.agent") == ["bootout", "gui/501/com.x.agent"])
        #expect(try LaunchctlCommand.disable(uid: 501, label: "com.x.agent") == ["disable", "gui/501/com.x.agent"])
        #expect(try LaunchctlCommand.enable(uid: 501, label: "com.x.agent") == ["enable", "gui/501/com.x.agent"])
        #expect(
            try LaunchctlCommand.bootstrap(uid: 501, plistPath: "/Users/u/Library/LaunchAgents/a b.plist")
                == ["bootstrap", "gui/501", "/Users/u/Library/LaunchAgents/a b.plist"])
        #expect(LaunchctlCommand.printDisabled(uid: 501) == ["print-disabled", "gui/501"])
        #expect(
            try LaunchctlCommand.printSystem(label: "us.zoom.ZoomDaemon") == ["print", "system/us.zoom.ZoomDaemon"])
    }

    @Test func rejectsLabelsThatCouldAddressAnotherService() {
        for bad in ["", "../x", "a/b", "com.x\nother", "tab\there", String(repeating: "a", count: 256)] {
            #expect(throws: LoginItemsError.invalidLabel(bad)) { try LaunchctlCommand.disable(uid: 501, label: bad) }
        }
        #expect(throws: LoginItemsError.self) { try LaunchctlCommand.bootstrap(uid: 501, plistPath: "relative.plist") }
        #expect(LaunchctlCommand.isValidLabel("com.Apple.lppglyivgmdqhyvs"))
        #expect(LaunchctlCommand.isValidLabel("label with spaces"))
    }
}
