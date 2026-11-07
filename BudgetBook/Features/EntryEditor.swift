import SwiftUI

struct EntryEditor: View {
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    let existing: BudgetEntry?
    @State private var kind: EntryKind
    @State private var amount: String
    @State private var date: Date
    @State private var categoryID: UUID?
    @State private var sourceID: UUID?
    @State private var destinationID: UUID?
    @State private var tags: Set<UUID>
    @State private var included: Bool
    @State private var memo: String
    @State private var error: String?
    @State private var master: MasterType?
    init(bookID: UUID, existing: BudgetEntry? = nil) {
        self.bookID = bookID; self.existing = existing
        _kind = State(initialValue: existing?.kind ?? .expense)
        _amount = State(initialValue: existing.map { String($0.amount) } ?? "")
        _date = State(initialValue: existing?.date ?? Date())
        _categoryID = State(initialValue: existing?.categoryID)
        _sourceID = State(initialValue: existing?.sourceID)
        _destinationID = State(initialValue: existing?.destinationID)
        _tags = State(initialValue: existing?.tagIDs ?? [])
        _included = State(initialValue: existing?.includedInTotals ?? true)
        _memo = State(initialValue: existing?.memo ?? "")
    }
    var body: some View {
        Form {
            Section { Text(store.state.books.first { $0.id == bookID }?.name ?? "家計簿").font(.headline) }
            Picker("種類", selection: $kind) { ForEach(EntryKind.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            Section("金額・日付") {
                TextField("金額（円）", text: $amount).keyboardType(.numberPad)
                DatePicker("日付", selection: $date, displayedComponents: .date)
            }
            if kind != .transfer {
                Section("カテゴリ") {
                    Picker("カテゴリ", selection: $categoryID) {
                        Text("未分類").tag(nil as UUID?)
                        ForEach(store.categories.filter { $0.kind == kind && !$0.isUncategorized && (store.state.isCategoryAvailable($0) || existing?.categoryID == $0.id) }) { item in
                            Text(store.categoryTitle(item)).tag(Optional(item.id))
                        }
                    }
                    Button("カテゴリを追加", systemImage: "plus") { master = .category }
                }
            }
            Section("入出金元") {
                if kind != .income { accountPicker("出金元", selection: $sourceID) }
                if kind != .expense { accountPicker("入金先", selection: $destinationID) }
                if kind == .transfer { Text("片方のみの指定も可能です。残高は計算しません。").font(.caption).foregroundStyle(.secondary) }
                Button("入出金元を追加", systemImage: "plus") { master = .account }
            }
            Section("タグ（任意）") {
                ForEach(store.tags.filter { !$0.isArchived || tags.contains($0.id) }) { tag in
                    Toggle(tag.name, isOn: Binding(get: { tags.contains(tag.id) }, set: { if $0 { tags.insert(tag.id) } else { tags.remove(tag.id) } }))
                }
                Button("タグを追加", systemImage: "plus") { master = .tag }
            }
            Section {
                if kind != .transfer { Toggle("収支計算の対象", isOn: $included) }
                TextField("メモ", text: $memo, axis: .vertical)
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle(existing == nil ? "取引を登録" : "取引を編集")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
        }
        .onAppear { if existing == nil { resetAccounts() } }
        .onChange(of: kind) { _, _ in categoryID = nil; resetAccounts(); included = true }
        .sheet(item: $master) { item in NavigationStack { MasterAddView(type: item, initialKind: kind == .income ? .income : .expense) } }
    }
    private func accountPicker(_ title: String, selection: Binding<UUID?>) -> some View {
        Picker(title, selection: selection) {
            Text("未指定").tag(nil as UUID?)
            ForEach(store.accounts.filter { !$0.isArchived || $0.id == existing?.sourceID || $0.id == existing?.destinationID }) { account in Text(account.name).tag(Optional(account.id)) }
        }
    }
    private func resetAccounts() {
        let wallet = store.accounts.first { $0.isWallet }?.id
        sourceID = kind == .expense ? wallet : nil
        destinationID = kind == .income ? wallet : nil
    }
    private func save() {
        guard let value = Int64(amount), value > 0 else { error = BudgetError.invalidAmount.localizedDescription; return }
        let entry = BudgetEntry(id: existing?.id ?? UUID(), bookID: bookID, kind: kind, amount: value, date: date, categoryID: categoryID, sourceID: sourceID, destinationID: destinationID, tagIDs: tags, includedInTotals: included, memo: memo)
        do { _ = try store.state.validated(entry, previous: existing) } catch { self.error = error.localizedDescription; return }
        if store.saveEntry(entry) { dismiss() } else { error = store.errorMessage }
    }
}
