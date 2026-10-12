import OpenCleanAppModel
import SwiftUI

struct PerformanceView: View {
    @Environment(PerformanceModel.self) private var model

    var body: some View {
        ComingSoonView()
    }
}
