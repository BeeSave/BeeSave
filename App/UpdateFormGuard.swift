import SwiftUI

/// Track each window's editors without reading or retaining their contents.
struct UpdateFormGuard: ViewModifier {
    var active: Bool
    @EnvironmentObject private var model: AppModel
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content.onAppear { update() }.onChange(of: active) { update() }
            .onDisappear { model.updateForms.remove(id) }
    }
    private func update() {
        if active { model.updateForms.insert(id) } else { model.updateForms.remove(id) }
    }
}
