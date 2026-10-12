import OpenCleanAppModel
import SwiftUI

struct SpaceLensView: View {
    @Environment(SpaceLensModel.self) private var model

    var body: some View {
        ComingSoonView()
    }
}
