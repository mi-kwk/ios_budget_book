import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section("家計簿") {
                NavigationLink("家計簿の管理", destination: BooksView())
                Text("共有用も、現在はこの端末の利用者のみが操作します。").font(.caption).foregroundStyle(.secondary)
            }
            Section("選択中：\(store.currentBook?.name ?? "なし")") {
                NavigationLink("カテゴリ", destination: MasterListView(type: .category))
                NavigationLink("タグ", destination: MasterListView(type: .tag))
                NavigationLink("入出金元", destination: MasterListView(type: .account))
                NavigationLink("タグ集計の表示", destination: TagDisplayView())
            }
            Section("バックアップ") {
                NavigationLink("バックアップ・復元", destination: BackupStatusView())
            }
            Section("開発中の枠組み") {
                Text("端末内に保存します。iCloudバックアップ・暗号化ファイル出力はまだ利用できません。").font(.footnote)
                Text("レシート撮影・CSV取り込み・残高管理・複数人共有は今後対応します。").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("設定").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
    }
}
struct BooksView: View {
    @EnvironmentObject private var store: BudgetStore
    @State private var name = ""
    @State private var shared = false
    var body: some View {
        Form {
            Section("家計簿一覧") { ForEach(store.state.books) { book in Button { store.selectBook(book.id) } label: { HStack { Text(book.name); Spacer(); if store.bookID == book.id { Image(systemName: "checkmark") } } } } }
            Section("家計簿を追加") {
                TextField("名称", text: $name)
                Toggle("共有用（初期版は本人のみ操作）", isOn: $shared)
                Button("追加") { store.addBook(name: name, shared: shared); if store.errorMessage == nil { name = "" } }.disabled(!store.canWrite)
            }
        }.navigationTitle("家計簿の管理")
    }
}
struct MasterListView: View {
    @EnvironmentObject private var store: BudgetStore
    let type: MasterType
    @State private var adding = false
    var body: some View {
        List {
            Section {
                Text("項目は削除せずアーカイブします。過去の取引は残ります。").font(.caption).foregroundStyle(.secondary)
                switch type {
                case .category:
                    ForEach(store.categories) { item in
                        row("\(item.kind.title)・\(store.categoryTitle(item))", id: item.id, archived: item.isArchived, protected: item.isUncategorized)
                    }
                case .tag:
                    ForEach(store.tags) { item in row(item.name, id: item.id, archived: item.isArchived) }
                case .account:
                    ForEach(store.accounts) { item in row(item.name, id: item.id, archived: item.isArchived, protected: item.isWallet) }
                }
            }
            Section { Text("名称変更・階層移動・並べ替えは後続実装です。").font(.caption).foregroundStyle(.secondary) }
        }.navigationTitle(type.rawValue)
            .toolbar { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("追加").disabled(!store.canWrite) }
            .sheet(isPresented: $adding) { NavigationStack { MasterAddView(type: type) } }
    }
    private func row(_ name: String, id: UUID, archived: Bool, protected: Bool = false) -> some View {
        HStack {
            VStack(alignment: .leading) { Text(name); if archived { Text("アーカイブ済み").font(.caption).foregroundStyle(.secondary) } }
            Spacer()
            if protected { Image(systemName: "lock").foregroundStyle(.secondary).accessibilityLabel("標準項目") }
            else { Button(archived ? "復元" : "アーカイブ") { store.toggleArchive(id, type: type) }.font(.caption).buttonStyle(.borderless) }
        }
    }
}
struct MasterAddView: View {
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let type: MasterType
    @State private var name = ""
    @State private var kind: EntryKind
    @State private var parentID: UUID?
    @State private var error: String?
    init(type: MasterType, initialKind: EntryKind = .expense) { self.type = type; _kind = State(initialValue: initialKind) }
    var body: some View {
        Form {
            TextField("名前", text: $name)
            if type == .category {
                Picker("収支種別", selection: $kind) { Text("支出").tag(EntryKind.expense); Text("収入").tag(EntryKind.income) }
                    .onChange(of: kind) { _, _ in parentID = nil }
                Picker("所属", selection: $parentID) {
                    Text("大カテゴリとして追加").tag(nil as UUID?)
                    ForEach(store.categories.filter { $0.kind == kind && $0.parentID == nil && !$0.isArchived && !$0.isUncategorized }) { item in Text(item.name).tag(Optional(item.id)) }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("\(type.rawValue)を追加")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加") {
                        store.addMaster(name: name, type: type, kind: kind, parentID: parentID)
                        if let message = store.errorMessage { error = message; store.errorMessage = nil } else { dismiss() }
                    }
                }
            }
    }
}
struct TagDisplayView: View {
    @EnvironmentObject private var store: BudgetStore
    var body: some View {
        Form {
            Toggle("タグ別集計を表示", isOn: Binding(get: { store.currentBook?.showsTagSummary ?? false }, set: { value in
                store.update { snapshot in if let index = snapshot.books.firstIndex(where: { $0.id == store.bookID }) { snapshot.books[index].showsTagSummary = value } }
            }))
            ForEach(store.tags) { tag in
                Toggle(tag.name, isOn: Binding(get: { !(store.currentBook?.hiddenTagIDs.contains(tag.id) ?? false) }, set: { value in
                    store.update { snapshot in
                        if let index = snapshot.books.firstIndex(where: { $0.id == store.bookID }) {
                            if value { snapshot.books[index].hiddenTagIDs.remove(tag.id) } else { snapshot.books[index].hiddenTagIDs.insert(tag.id) }
                        }
                    }
                }))
            }
            Text("非表示にしても、取引への付与・検索には使えます。").font(.caption).foregroundStyle(.secondary)
        }.navigationTitle("タグ集計の表示")
    }
}
struct BackupStatusView: View {
    var body: some View {
        List {
            Section { Label("バックアップは未実装です", systemImage: "icloud.slash"); Text("現在のデータはこの端末内のみです。大切な記録の本番運用は、バックアップ機能の完成後を想定しています。") }
            Section("今後の実装予定") {
                Text("iCloudへの手動・自動保存、成功した最新3回分の保持")
                Text("パスワード付き暗号化ファイルの出力・読み込み")
                Text("復元前確認・全置換・失敗時のデータ維持")
                Text("復元前データの退避・7日間保持・戻す操作")
            }
        }.navigationTitle("バックアップ・復元")
    }
}
