import OpenCleanAppModel
import SwiftUI

struct UninstallerView: View {
    @Environment(UninstallerModel.self) private var model

    var body: some View {
        ComingSoonView()
    }
}
