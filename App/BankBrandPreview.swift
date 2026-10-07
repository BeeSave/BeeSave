#if DEBUG && UI_SMOKE
import SwiftUI
import BudgetCore
import BudgetPresentation

struct BankBrandPreview: View {
    @ObservedObject private var appearanceStore = AppearanceStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.beeAppearance) private var appearance
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 220 * appearance.scale), spacing: 12)] }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Логотипы банков · тестовый просмотр").beeFont(.title2); Spacer(); Button("Закрыть") { dismiss() } }
            ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(BankCatalog.shared.banks.filter { $0.logoResource != nil }) { bank in
                    HStack(spacing: 10) {
                        BankMark(bankID: bank.id)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bank.aliases.min(by: { $0.count < $1.count }) ?? bank.name).beeFont(.caption).fixedSize(horizontal: false, vertical: true)
                            Text(bank.country).beeFont(.caption2).foregroundStyle(BeeStyle.muted)
                        }
                        Spacer(minLength: 0)
                    }.frame(minHeight: 48 * appearance.scale).beeCard(padding: 10)
                }
            }
            }
        }.padding(20).frame(width: 1000, height: 650).beeWindow()
    }
}
#endif
