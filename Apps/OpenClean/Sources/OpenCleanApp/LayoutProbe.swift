import SwiftUI

/// Records where tagged views were laid out, in window coordinates (top-left origin), so the layout tests can
/// check geometry without UI automation. The app never sets one, so in the app `.layoutProbe(_:)` adds nothing.
@MainActor
final class LayoutProbe {
    private(set) var frames: [String: CGRect] = [:]

    func record(_ id: String, _ frame: CGRect) { frames[id] = frame }
}

extension EnvironmentValues {
    @Entry var layoutProbe: LayoutProbe?
}

extension View {
    /// Reports this view's frame to the environment's `LayoutProbe` under `id` (tests only).
    func layoutProbe(_ id: String) -> some View { modifier(LayoutProbeModifier(id: id)) }
}

private struct LayoutProbeModifier: ViewModifier {
    @Environment(\.layoutProbe) private var probe
    let id: String

    func body(content: Content) -> some View {
        if let probe {
            content.background(
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .global)
                    Color.clear
                        .onAppear { probe.record(id, frame) }
                        .onChange(of: frame) { probe.record(id, frame) }
                })
        } else {
            content
        }
    }
}
