import Foundation
import OpenCleanCLI

let status = await OpenCleanCommand.execute(arguments: Array(CommandLine.arguments.dropFirst()))
exit(status)
