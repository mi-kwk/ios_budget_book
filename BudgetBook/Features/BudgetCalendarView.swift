import SwiftUI

struct BudgetCalendarView: View {
    @EnvironmentObject private var store: BudgetStore
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)
    var body: some View {
        let cells = BudgetCalendar.cells(month: store.displayMonth, start: store.weekStart)
        let summaries = BudgetCalendar.summaries(store.entries(in: store.displayMonth))
        VStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(BudgetCalendar.weekdays(start: store.weekStart), id: \.self) { name in
                    Text(name).font(.caption.bold()).frame(maxWidth: .infinity)
                        .foregroundStyle(name == "日" ? .red : name == "土" ? .blue : .secondary)
                }
            }.accessibilityElement(children: .combine)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                    if let date { dayCell(date, summary: summaries[date] ?? CalendarDaySummary()) }
                    else { Color.clear.frame(minHeight: 72).accessibilityHidden(true) }
                }
            }
            Text("収：収入　支：返金差引後の支出　⇄：振替あり")
                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func dayCell(_ date: Date, summary: CalendarDaySummary) -> some View {
        let selected = Calendar.current.isDate(date, inSameDayAs: store.selectedDay)
        return Button { store.selectCalendarDay(date) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Text(String(Calendar.current.component(.day, from: date))).font(.caption.bold())
                    Spacer(minLength: 0)
                    if summary.hasTransfer { Image(systemName: "arrow.left.arrow.right").font(.system(size: 8)) }
                }
                if summary.hasIncome { amount("収", summary.totals.income, color: .teal) }
                if summary.hasExpense { amount("支", summary.totals.expense, color: .orange) }
                Spacer(minLength: 0)
            }.padding(4).frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                .background(selected ? Color.teal.opacity(0.14) : Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.teal : Calendar.current.isDateInToday(date) ? Color.secondary : .clear, lineWidth: selected ? 2 : 1))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(date.formatted(date: .complete, time: .omitted))、収入\(yen(summary.totals.income))、支出\(yen(summary.totals.expense))、\(summary.hasTransfer ? "振替あり、" : "")取引\(summary.count)件")
            .accessibilityValue(selected ? "選択中" : "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { store.selectCalendarDay(date) }
    }
    private func amount(_ prefix: String, _ value: Int64, color: Color) -> some View {
        Text("\(prefix) \(value.formatted(.number))").font(.system(size: 10)).foregroundStyle(color)
            .lineLimit(1).minimumScaleFactor(0.45).monospacedDigit()
    }
}
