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
                NavigationLink("カテゴリ", destination: CategoryManagementView())
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

struct MasterEditTarget: Identifiable {
    let id: UUID
    let name: String
    let archived: Bool
}

struct MasterListView: View {
    @EnvironmentObject private var store: BudgetStore
    let type: MasterType
    @State private var adding = false
    @State private var editing: MasterEditTarget?
    var body: some View {
        List {
            Section {
                Text("項目を開くと名前を変更できます。アーカイブしても過去の取引は残ります。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(type.rawValue) {
                if type == .account {
                    ForEach(store.accounts) { account in
                        if account.isWallet {
                            HStack { Text(account.name); Spacer(); Label("標準", systemImage: "lock").font(.caption).foregroundStyle(.secondary) }
                        } else {
                            masterRow(id: account.id, name: account.name, archived: account.isArchived)
                        }
                    }.onMove { from, to in
                        if let bookID = store.bookID { store.moveAccounts(bookID: bookID, from: from, to: to) }
                    }
                } else {
                    ForEach(store.tags) { tag in masterRow(id: tag.id, name: tag.name, archived: tag.isArchived) }
                    if store.tags.isEmpty { Text("右上の＋からタグを追加できます。").foregroundStyle(.secondary) }
                }
            }
            if type == .account {
                Section { Text("「編集」で入出金元の表示順を変更できます。標準のお財布は名称変更・削除・アーカイブできません。残高は計算しません。").font(.caption).foregroundStyle(.secondary) }
            }
        }.navigationTitle(type.rawValue)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { if type == .account { EditButton().disabled(!store.canWrite) } }
                ToolbarItem(placement: .topBarTrailing) { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("追加").disabled(!store.canWrite) }
            }
            .sheet(isPresented: $adding) {
                if let bookID = store.bookID { NavigationStack { MasterEditorView(type: type, bookID: bookID) } }
            }
            .sheet(item: $editing) { target in
                if let bookID = store.bookID { NavigationStack { MasterEditorView(type: type, bookID: bookID, existing: target) } }
            }
    }
    private func masterRow(id: UUID, name: String, archived: Bool) -> some View {
        Button { editing = MasterEditTarget(id: id, name: name, archived: archived) } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                    if archived { Text("アーカイブ済み").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
        }.tint(.primary).disabled(!store.canWrite)
    }
}

struct MasterEditorView: View {
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let type: MasterType
    let bookID: UUID
    let existing: MasterEditTarget?
    @State private var name: String
    @State private var error: String?
    @State private var confirmingArchive = false
    init(type: MasterType, bookID: UUID, existing: MasterEditTarget? = nil) {
        self.type = type; self.bookID = bookID; self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
    }
    private var archivedMatch: BudgetTag? {
        guard type == .tag, existing == nil else { return nil }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.state.tags.first { $0.bookID == bookID && $0.name == cleaned && $0.isArchived }
    }
    var body: some View {
        Form {
            Section("名前") { TextField("名前", text: $name) }
            if type == .tag {
                Section { Text("同じ家計簿では、アーカイブ済みも含めて同じ名前は使えません。名称を変更しても過去の取引との関連や表示設定は保持されます。").font(.caption).foregroundStyle(.secondary) }
            } else {
                Section { Text("名称を変更すると過去の取引にも反映します。金額は変更されません。").font(.caption).foregroundStyle(.secondary) }
            }
            if let match = archivedMatch {
                Section("同名のアーカイブ済みタグがあります") {
                    Button("既存タグを復元して使用する") {
                        perform { try $0.setTagArchived(id: match.id, bookID: bookID, archived: false) }
                    }
                }
            }
            if let existing {
                Section {
                    Button(existing.archived ? "復元" : "アーカイブ") { confirmingArchive = true }.disabled(!store.canWrite)
                    Text("この操作では編集中の名前は保存しません。アーカイブ済みの項目は新しい取引では選択できません。").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }.navigationTitle("\(type.rawValue)を\(existing == nil ? "追加" : "編集")")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if store.saveMaster(id: existing?.id, bookID: bookID, name: name, type: type) != nil { dismiss() }
                        else { captureError() }
                    }.disabled(!store.canWrite || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || archivedMatch != nil)
                }
            }
            .confirmationDialog(existing?.archived == true ? "この項目を復元しますか？" : "新しい取引の選択候補から外します。過去の取引は残ります。", isPresented: $confirmingArchive, titleVisibility: .visible) {
                if let existing {
                    Button(existing.archived ? "復元" : "アーカイブ") {
                        perform { snapshot in
                            if type == .tag { try snapshot.setTagArchived(id: existing.id, bookID: bookID, archived: !existing.archived) }
                            else { try snapshot.setAccountArchived(id: existing.id, bookID: bookID, archived: !existing.archived) }
                        }
                    }
                }
            }
    }
    private func perform(_ change: (inout BudgetSnapshot) throws -> Void) {
        if store.update(change) { dismiss() } else { captureError() }
    }
    private func captureError() { error = store.errorMessage ?? "保存できませんでした。"; store.errorMessage = nil }
}

struct AccountSelectionView: View {
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    let title: String
    let currentID: UUID?
    let previousID: UUID?
    let allowsUnspecified: Bool
    let onSelect: (UUID?) -> Void
    @State private var adding = false
    var body: some View {
        List {
            if allowsUnspecified { Section { option(name: "未指定", id: nil) } }
            Section("入出金元を選択") {
                ForEach(store.state.orderedAccounts(bookID: bookID).filter { !$0.isArchived }) { account in
                    option(name: account.name, id: account.id)
                }
            }
            if let previous = store.state.accounts.first(where: { $0.bookID == bookID && $0.id == previousID && $0.isArchived }) {
                Section("元の取引の入出金元") {
                    option(name: previous.name + "（アーカイブ済み）", id: previous.id)
                    Text("元の取引で使用していた項目は保持できます。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Text(allowsUnspecified ? "振替元・振替先の少なくとも片方を指定してください。同じ項目同士には振替できません。" : "収入・支出では入出金元が必須です。")
                Text("右上の＋から追加できます。追加後、一覧から選択してください。")
            }.font(.caption).foregroundStyle(.secondary)
        }.navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("入出金元を追加").disabled(!store.canWrite) }
            }
            .sheet(isPresented: $adding) { NavigationStack { MasterEditorView(type: .account, bookID: bookID) } }
    }
    private func option(name: String, id: UUID?) -> some View {
        Button { onSelect(id) } label: {
            HStack { Text(name); Spacer(); if currentID == id { Image(systemName: "checkmark") } }
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

struct CategoryManagementView: View {
    @EnvironmentObject private var store: BudgetStore
    @State private var kind = EntryKind.expense
    @State private var adding = false
    @State private var showingBasicSet = false
    var body: some View {
        List {
            Picker("収支種別", selection: $kind) {
                Text("支出").tag(EntryKind.expense); Text("収入").tag(EntryKind.income)
            }.pickerStyle(.segmented)
            Section {
                Text("大カテゴリを開くと、名称の変更や小カテゴリの管理ができます。「編集」で表示順を変更できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let bookID = store.bookID {
                Section("大カテゴリ") {
                    ForEach(store.state.orderedCategories(bookID: bookID, kind: kind, parentID: nil)) { category in
                        NavigationLink { CategoryChildrenView(categoryID: category.id) } label: {
                            CategoryNameView(category: category)
                        }
                    }.onMove { from, to in store.moveCategories(bookID: bookID, kind: kind, parentID: nil, from: from, to: to) }
                }
                Section {
                    Button("基本セットを確認・追加") { showingBasicSet = true }.disabled(!store.canWrite)
                    Text("基本カテゴリは設定時のひな形です。名称や分類は自由に変更できます。標準の未分類は保護されます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle("カテゴリ")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { EditButton().disabled(!store.canWrite) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("大カテゴリを追加").disabled(!store.canWrite)
                }
            }
            .sheet(isPresented: $adding) {
                if let bookID = store.bookID { NavigationStack { CategoryEditorView(bookID: bookID, kind: kind) } }
            }
            .sheet(isPresented: $showingBasicSet) {
                if let bookID = store.bookID { NavigationStack { BasicCategorySetView(bookID: bookID) } }
            }
    }
}

struct CategoryNameView: View {
    @EnvironmentObject private var store: BudgetStore
    let category: BudgetCategory
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(category.name)
                if category.isArchived { Text("アーカイブ済み").font(.caption).foregroundStyle(.secondary) }
                else if !store.state.isCategoryAvailable(category) { Text("親カテゴリのアーカイブ中は選択できません").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if category.isUncategorized { Image(systemName: "lock").foregroundStyle(.secondary).accessibilityLabel("標準項目") }
        }
    }
}

struct CategoryChildrenView: View {
    @EnvironmentObject private var store: BudgetStore
    let categoryID: UUID
    @State private var editing: BudgetCategory?
    @State private var adding = false
    @State private var confirmsArchive = false
    private var parent: BudgetCategory? { store.state.categories.first { $0.id == categoryID } }
    var body: some View {
        Group {
            if let parent {
                List {
                    Section("大カテゴリ") {
                        CategoryNameView(category: parent)
                        if !parent.isUncategorized {
                            Button("名称を変更") { editing = parent }.disabled(!store.canWrite)
                            Button(parent.isArchived ? "復元" : "アーカイブ") { confirmsArchive = true }.disabled(!store.canWrite)
                        }
                    }
                    if !parent.isUncategorized {
                        Section("小カテゴリ") {
                            ForEach(store.state.orderedCategories(bookID: parent.bookID, kind: parent.kind, parentID: parent.id)) { child in
                                Button { editing = child } label: { CategoryNameView(category: child) }.tint(.primary)
                            }.onMove { from, to in store.moveCategories(bookID: parent.bookID, kind: parent.kind, parentID: parent.id, from: from, to: to) }
                            if !store.state.categories.contains(where: { $0.parentID == parent.id }) {
                                Text("小カテゴリはまだありません。").foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section {
                        Text("名称・所属先の変更は過去の取引にも反映します。取引の金額は変更しません。")
                        Text("大カテゴリをアーカイブすると配下も新規選択できません。復元しても、個別にアーカイブした小カテゴリはそのまま残ります。")
                    }.font(.caption).foregroundStyle(.secondary)
                }.navigationTitle(parent.name)
                    .toolbar {
                        if !parent.isUncategorized {
                            ToolbarItem(placement: .topBarTrailing) { EditButton().disabled(!store.canWrite) }
                            ToolbarItem(placement: .topBarTrailing) {
                                Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("小カテゴリを追加")
                                    .disabled(parent.isArchived || !store.canWrite)
                            }
                        }
                    }
                    .sheet(isPresented: $adding) {
                        NavigationStack { CategoryEditorView(bookID: parent.bookID, kind: parent.kind, initialParentID: parent.id) }
                    }
                    .confirmationDialog(parent.isArchived ? "大カテゴリを復元しますか？" : "配下の小カテゴリも新規選択できなくなります。過去の取引は残ります。", isPresented: $confirmsArchive, titleVisibility: .visible) {
                        Button(parent.isArchived ? "復元" : "アーカイブ") { store.toggleArchive(parent.id, type: .category) }
                    }
            } else { ContentUnavailableView("カテゴリが見つかりません", systemImage: "folder") }
        }
        .sheet(item: $editing) { category in
            NavigationStack { CategoryEditorView(bookID: category.bookID, kind: category.kind, existing: category) }
        }
    }
}

struct CategoryEditorView: View {
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    let kind: EntryKind
    let existing: BudgetCategory?
    var onSaved: ((UUID) -> Void)?
    @State private var name: String
    @State private var parentID: UUID?
    @State private var error: String?
    private var allowsParentSelection: Bool { existing == nil || existing?.parentID != nil }

    init(bookID: UUID, kind: EntryKind, existing: BudgetCategory? = nil, initialParentID: UUID? = nil, onSaved: ((UUID) -> Void)? = nil) {
        self.bookID = bookID; self.kind = kind; self.existing = existing; self.onSaved = onSaved
        _name = State(initialValue: existing?.name ?? "")
        _parentID = State(initialValue: existing?.parentID ?? initialParentID)
    }
    var body: some View {
        Form {
            Section("\(kind.title)カテゴリ") { TextField("名前", text: $name) }
            if allowsParentSelection {
                Section("所属先") {
                    Picker("大カテゴリ", selection: $parentID) {
                        if existing == nil { Text("大カテゴリとして追加").tag(nil as UUID?) }
                        ForEach(store.state.orderedCategories(bookID: bookID, kind: kind, parentID: nil).filter {
                            !$0.isUncategorized && (!$0.isArchived || $0.id == existing?.parentID)
                        }) { parent in Text(parent.name + (parent.isArchived ? "（アーカイブ済み）" : "")).tag(Optional(parent.id)) }
                    }
                }
            }
            if existing != nil {
                Section { Text("過去の取引も現在の名称・分類で表示・集計されます。金額は変更されません。").font(.caption).foregroundStyle(.secondary) }
            }
            if let existing, !existing.isUncategorized {
                Section {
                    Button(existing.isArchived ? "復元して閉じる" : "アーカイブして閉じる") {
                        store.toggleArchive(existing.id, type: .category)
                        if let message = store.errorMessage { error = message; store.errorMessage = nil } else { dismiss() }
                    }.disabled(!store.canWrite)
                    Text("アーカイブ操作では、編集中の名前・所属先は保存しません。").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle(existing == nil ? "カテゴリを追加" : "カテゴリを編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let id = store.saveCategory(id: existing?.id, bookID: bookID, kind: kind, name: name, parentID: parentID) {
                            dismiss(); onSaved?(id)
                        } else { error = store.errorMessage; store.errorMessage = nil }
                    }.disabled(!store.canWrite || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
    }
}

struct CategorySelectionView: View {
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    let kind: EntryKind
    let currentID: UUID?
    let onSelect: (UUID) -> Void
    @State private var adding = false
    var body: some View {
        List {
            if let current = store.state.categories.first(where: { $0.id == currentID && $0.bookID == bookID && $0.kind == kind }), !store.state.isCategoryAvailable(current) {
                Section("現在のカテゴリ") {
                    Button { onSelect(current.id) } label: {
                        VStack(alignment: .leading) { Text(store.categoryTitle(current)); Text("アーカイブ済みの選択をそのまま保持").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            Section("大カテゴリを選択") {
                ForEach(store.state.orderedCategories(bookID: bookID, kind: kind, parentID: nil).filter { store.state.isCategoryAvailable($0) }) { parent in
                    if parent.isUncategorized {
                        selectionButton(parent)
                    } else {
                        NavigationLink { CategoryChildSelectionView(parent: parent, currentID: currentID, onSelect: onSelect) } label: {
                            HStack { Text(parent.name); Spacer(); if isSelected(parent) { Image(systemName: "checkmark").foregroundStyle(.teal) } }
                        }
                    }
                }
            }
        }.navigationTitle("\(kind.title)カテゴリ")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("カテゴリを追加").disabled(!store.canWrite)
                }
            }
            .sheet(isPresented: $adding) { NavigationStack { CategoryEditorView(bookID: bookID, kind: kind) } }
    }
    private func isSelected(_ parent: BudgetCategory) -> Bool {
        currentID == parent.id || store.state.categories.contains { $0.id == currentID && $0.parentID == parent.id }
    }
    private func selectionButton(_ category: BudgetCategory) -> some View {
        Button { onSelect(category.id) } label: {
            HStack { Text(category.name); Spacer(); if currentID == category.id || currentID == nil { Image(systemName: "checkmark") } }
        }
    }
}

struct CategoryChildSelectionView: View {
    @EnvironmentObject private var store: BudgetStore
    let parent: BudgetCategory
    let currentID: UUID?
    let onSelect: (UUID) -> Void
    @State private var adding = false
    var body: some View {
        List {
            Section {
                Button { onSelect(parent.id) } label: {
                    HStack { Text("\(parent.name)（大カテゴリで登録）"); Spacer(); if currentID == parent.id { Image(systemName: "checkmark") } }
                }
            }
            Section("小カテゴリを選択") {
                ForEach(store.state.orderedCategories(bookID: parent.bookID, kind: parent.kind, parentID: parent.id).filter { store.state.isCategoryAvailable($0) }) { child in
                    Button { onSelect(child.id) } label: {
                        HStack { Text(child.name); Spacer(); if currentID == child.id { Image(systemName: "checkmark") } }
                    }
                }
                if !store.state.categories.contains(where: { $0.parentID == parent.id && store.state.isCategoryAvailable($0) }) {
                    Text("小カテゴリは右上の＋から追加できます。").foregroundStyle(.secondary)
                }
            }
        }.navigationTitle(parent.name)
            .toolbar { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("小カテゴリを追加").disabled(!store.canWrite) }
            .sheet(isPresented: $adding) {
                NavigationStack { CategoryEditorView(bookID: parent.bookID, kind: parent.kind, initialParentID: parent.id) }
            }
    }
}


struct BasicCategorySetView: View {
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    var body: some View {
        List {
            Section {
                Text("食費など一般的な項目のひな形です。追加後も自由に名称や所属先を変更できます。")
                Text("同じ場所にある同名カテゴリは再利用し、既存の取引・名前・順番は変更しません。アーカイブ済みの大カテゴリは配下ごと追加をスキップします。")
            }.font(.footnote)
            ForEach([EntryKind.expense, .income]) { kind in
                Section(kind.title) {
                    ForEach(BasicCategoryGroup.groups(for: kind)) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.name).font(.headline)
                            if !group.children.isEmpty { Text(group.children.joined(separator: "・")).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }.navigationTitle("基本カテゴリセット")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加する") { if store.update({ try $0.addBasicCategories(bookID: bookID) }) { dismiss() } }.disabled(!store.canWrite)
                }
            }
    }
}
