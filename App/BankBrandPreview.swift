#if DEBUG && UI_SMOKE
import SwiftUI
import BudgetCore

struct BankBrandPreview: View {
    @Environment(\.dismiss) private var dismiss
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 5)
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Логотипы банков · тестовый просмотр").font(.title2); Spacer(); Button("Закрыть") { dismiss() } }
            ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(BankCatalog.shared.banks.filter { $0.logoResource != nil }) { bank in
                    HStack(spacing: 10) {
                        BankMark(bankID: bank.id)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bank.aliases.min(by: { $0.count < $1.count }) ?? bank.name).font(.caption).lineLimit(2)
                            Text(bank.country).font(.caption2).foregroundStyle(BeeStyle.muted)
                        }
                        Spacer(minLength: 0)
                    }.frame(height: 48).beeCard(padding: 10)
                }
            }
            }
        }.padding(20).frame(width: 1000, height: 650).beeWindow()
    }
}
#endif
