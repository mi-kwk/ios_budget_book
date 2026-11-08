import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section("家計簿") {
                NavigationLink("家計簿の管理", destination: BooksView(onView: { dismiss() }))
                Text("共有用も、現在はこの端末の利用者のみが操作します。").font(.caption).foregroundStyle(.secondary)
            }
            Section("選択中：\(store.currentBook?.name ?? "なし")") {
                NavigationLink("カテゴリ", destination: CategoryManagementView())
                NavigationLink("タグ", destination: MasterListView(type: .tag))
                NavigationLink("入出金元", destination: MasterListView(type: .account))
                NavigationLink("タグ集計の表示", destination: TagDisplayView())
            }
            Section("カレンダー") {
                Picker("週の始まり", selection: Binding(get: { store.weekStart }, set: { store.setWeekStart($0) })) {
                    Text("月曜日").tag(CalendarWeekStart.monday)
                    Text("日曜日").tag(CalendarWeekStart.sunday)
                }.disabled(!store.canWrite)
                Text("全家計簿に共通です。表示月は3タブで連動し、アプリ起動時は今月から表示します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("バックアップ") {
                NavigationLink("バックアップ・復元", destination: BackupStatusView())
            }
            Section("開発中の枠組み") {
                Text("端末内に保存します。暗号化ファイルの書き出し・復元が利用できます。iCloudバックアップの利用には開発用の接続設定が必要です。").font(.footnote)
                Text("レシート撮影・CSV取り込み・残高管理・複数人共有は今後対応します。").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("設定").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
    }
}
struct BooksView: View {
    @EnvironmentObject private var store: BudgetStore
    var onView: () -> Void = {}
    @State private var name = ""
    @State private var shared = false
    var body: some View {
        List {
            Section("利用可能な家計簿") {
                ForEach(store.state.orderedBooks(includeArchived: false)) { book in
                    NavigationLink { BookManagementDetail(book: book, onView: onView) } label: {
                        HStack {
                            Text(book.name); Spacer()
                            if store.state.selectedBookID == book.id { Image(systemName: "checkmark").foregroundStyle(.teal) }
                        }
                    }
                }.onMove { store.moveBooks(from: $0, to: $1) }
                Text("項目を開くと名称変更・アーカイブができます。「編集」で表示順を変更できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            let archived = store.state.orderedBooks().filter { $0.archived }
            if !archived.isEmpty {
                Section("アーカイブ済み") {
                    ForEach(archived) { book in
                        NavigationLink { BookManagementDetail(book: book, onView: onView) } label: {
                            Label(book.name, systemImage: "archivebox")
                        }
                    }
                }
            }
            Section("家計簿を追加") {
                TextField("名称", text: $name)
                Toggle("共有用（初期版は本人のみ操作）", isOn: $shared)
                Button("追加") { store.addBook(name: name, shared: shared); if store.errorMessage == nil { name = "" } }
                    .disabled(!store.canWrite || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.navigationTitle("家計簿の管理")
            .toolbar { EditButton().disabled(!store.canWrite) }
    }
}

struct BookManagementDetail: View {
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    var onView: () -> Void
    @State private var name: String
    @State private var confirmingArchive = false
    init(book: HouseholdBook, onView: @escaping () -> Void) {
        bookID = book.id; self.onView = onView
        _name = State(initialValue: book.name)
    }
    var body: some View {
        Group {
            if let book = store.state.books.first(where: { $0.id == bookID }) {
                Form {
                    Section("名称") {
                        TextField("家計簿名", text: $name).disabled(book.archived || !store.canWrite)
                        if !book.archived {
                            Button("名称を保存") { if store.renameBook(id: bookID, name: name) { dismiss() } }
                                .disabled(!store.canWrite || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    Section {
                        if book.archived {
                            Text("アーカイブ済みです。取引・設定の変更には復元が必要です。")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("閲覧専用で開く") { store.viewArchivedBook(bookID); onView() }
                            Button("この家計簿を復元") { _ = store.setBookArchived(id: bookID, archived: false) }.disabled(!store.canWrite)
                        } else {
                            Button("この家計簿を開く") { store.selectBook(bookID); onView() }.disabled(!store.canWrite)
                            Button("アーカイブ", role: .destructive) { confirmingArchive = true }
                                .disabled(!store.canWrite || store.state.orderedBooks(includeArchived: false).count <= 1)
                            if store.state.orderedBooks(includeArchived: false).count <= 1 {
                                Text("利用可能な最後の1冊はアーカイブできません。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text("アーカイブしても取引やカテゴリは残ります。利用可能な家計簿とアーカイブ済みを通して、同じ名前は使えません。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.navigationTitle(book.name)
                    .confirmationDialog("この家計簿をアーカイブしますか？", isPresented: $confirmingArchive, titleVisibility: .visible) {
                        Button("アーカイブ", role: .destructive) { _ = store.setBookArchived(id: bookID, archived: true) }
                    } message: { Text("通常の切替候補から外し、閲覧専用にします。取引は削除しません。編集中の名称は保存しません。") }
            } else { ContentUnavailableView("家計簿が見つかりません", systemImage: "books.vertical") }
        }
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
                        .onMove { from, to in if let bookID = store.bookID { store.moveTags(bookID: bookID, from: from, to: to) } }
                    if store.tags.isEmpty { Text("右上の＋からタグを追加できます。").foregroundStyle(.secondary) }
                }
            }
            if type == .account {
                Section { Text("「編集」で入出金元の表示順を変更できます。標準のお財布は名称変更・削除・アーカイブできません。残高は計算しません。").font(.caption).foregroundStyle(.secondary) }
            }
        }.navigationTitle(type.rawValue)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { EditButton().disabled(!store.canEditCurrentBook) }
                ToolbarItem(placement: .topBarTrailing) { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("追加").disabled(!store.canEditCurrentBook) }
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
        }.tint(.primary).disabled(!store.canEditCurrentBook)
    }
}

struct MasterEditorView: View {
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let type: MasterType
    let bookID: UUID
    let existing: MasterEditTarget?
    let onSaved: ((UUID) -> Void)?
    @State private var name: String
    @State private var error: String?
    @State private var confirmingArchive = false
    init(type: MasterType, bookID: UUID, existing: MasterEditTarget? = nil, onSaved: ((UUID) -> Void)? = nil) {
        self.type = type; self.bookID = bookID; self.existing = existing; self.onSaved = onSaved
        _name = State(initialValue: existing?.name ?? "")
    }
    private var archivedMatch: BudgetTag? {
        guard type == .tag, existing == nil else { return nil }
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.state.tags.first { $0.bookID == bookID && BudgetSnapshot.categoryNameKey($0.name) == BudgetSnapshot.categoryNameKey(cleaned) && $0.isArchived }
    }
    var body: some View {
        Form {
            Section("名前") { TextField("名前", text: $name) }
            if onSaved != nil && existing == nil {
                Text("追加した項目は、この取引を取消しても一覧に残ります。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if type == .tag {
                Section { Text("同じ家計簿では、アーカイブ済みも含めて同じ名前は使えません。名称を変更しても過去の取引との関連や表示設定は保持されます。").font(.caption).foregroundStyle(.secondary) }
            } else {
                Section { Text("名称を変更すると過去の取引にも反映します。金額は変更されません。").font(.caption).foregroundStyle(.secondary) }
            }
            if let match = archivedMatch {
                Section("同名のアーカイブ済みタグがあります") {
                    Button("既存タグを復元して使用する") {
                        perform(selecting: match.id) { try $0.setTagArchived(id: match.id, bookID: bookID, archived: false) }
                    }
                }
            }
            if let existing {
                Section {
                    Button(existing.archived ? "復元" : "アーカイブ") { confirmingArchive = true }.disabled(!store.canEditCurrentBook)
                    Text("この操作では編集中の名前は保存しません。アーカイブ済みの項目は新しい取引では選択できません。").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }.navigationTitle("\(type.rawValue)を\(existing == nil ? "追加" : "編集")")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let id = store.saveMaster(id: existing?.id, bookID: bookID, name: name, type: type) { onSaved?(id); dismiss() }
                        else { captureError() }
                    }.disabled(!store.canEditCurrentBook || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || archivedMatch != nil)
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
    private func perform(selecting id: UUID? = nil, _ change: (inout BudgetSnapshot) throws -> Void) {
        if store.update(change) {
            if let id { onSaved?(id) }
            dismiss()
        } else { captureError() }
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
    @State private var savedAccountID: UUID?
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
                Text("右上の＋から追加できます。保存すると自動で選択し、取引入力へ戻ります。")
            }.font(.caption).foregroundStyle(.secondary)
        }.navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("入出金元を追加").disabled(!store.canEditCurrentBook) }
            }
            .sheet(isPresented: $adding, onDismiss: {
                guard let id = savedAccountID else { return }
                savedAccountID = nil
                guard store.state.accounts.contains(where: { $0.id == id && $0.bookID == bookID && !$0.isArchived }), store.canEditBook(bookID) else { return }
                onSelect(id)
            }) {
                NavigationStack { MasterEditorView(type: .account, bookID: bookID, onSaved: { savedAccountID = $0 }) }
            }
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
                if let id = store.bookID { store.update { try $0.setTagSummary(bookID: id, enabled: value) } }
            }))
            ForEach(store.tags) { tag in
                Toggle(tag.name, isOn: Binding(get: { !(store.currentBook?.hiddenTagIDs.contains(tag.id) ?? false) }, set: { value in
                    if let bookID = store.bookID { store.update { try $0.setTagVisible(bookID: bookID, tagID: tag.id, visible: value) } }
                }))
            }
            Text("全体と新しいタグの表示は初期OFFです。非表示でも、取引への付与・検索には使えます。タグの順序はタグ一覧の「編集」から変更できます。").font(.caption).foregroundStyle(.secondary)
        }.disabled(!store.canEditCurrentBook).navigationTitle("タグ集計の表示")
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
                    Button("基本セットを確認・追加") { showingBasicSet = true }.disabled(!store.canEditCurrentBook)
                    Text("基本カテゴリは設定時のひな形です。名称や分類は自由に変更できます。標準の未分類は保護されます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle("カテゴリ")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { EditButton().disabled(!store.canEditCurrentBook) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("大カテゴリを追加").disabled(!store.canEditCurrentBook)
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

struct CategoryIconView: View {
    @EnvironmentObject private var store: BudgetStore
    let categoryID: UUID?
    var body: some View {
        let income = store.state.categories.first { $0.id == categoryID }?.kind == .income
        Image(systemName: store.state.categorySymbol(categoryID))
            .font(.body).foregroundStyle(income ? Color.green : Color.teal)
            .frame(width: 34, height: 34)
            .background((income ? Color.green : Color.teal).opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)
    }
}

struct CategoryNameView: View {
    @EnvironmentObject private var store: BudgetStore
    let category: BudgetCategory
    var body: some View {
        HStack {
            CategoryIconView(categoryID: category.id)
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
                            Button("名称・アイコンを変更") { editing = parent }.disabled(!store.canEditCurrentBook)
                            Button(parent.isArchived ? "復元" : "アーカイブ") { confirmsArchive = true }.disabled(!store.canEditCurrentBook)
                        }
                    }
                    Group {
                        Section("小カテゴリ") {
                            ForEach(store.state.orderedCategories(bookID: parent.bookID, kind: parent.kind, parentID: parent.id)) { child in
                                if child.isUncategorized { CategoryNameView(category: child) }
                                else { Button { editing = child } label: { CategoryNameView(category: child) }.tint(.primary) }
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
                            ToolbarItem(placement: .topBarTrailing) { EditButton().disabled(!store.canEditCurrentBook) }
                            ToolbarItem(placement: .topBarTrailing) {
                                Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("小カテゴリを追加")
                                    .disabled(parent.isArchived || !store.canEditCurrentBook)
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
    @State private var iconName: String?
    @State private var error: String?
    private var allowsParentSelection: Bool { existing == nil || existing?.parentID != nil }

    init(bookID: UUID, kind: EntryKind, existing: BudgetCategory? = nil, initialParentID: UUID? = nil, onSaved: ((UUID) -> Void)? = nil) {
        self.bookID = bookID; self.kind = kind; self.existing = existing; self.onSaved = onSaved
        _name = State(initialValue: existing?.name ?? "")
        _parentID = State(initialValue: existing?.parentID ?? initialParentID)
        _iconName = State(initialValue: existing?.iconName)
    }
    var body: some View {
        Form {
            Section("\(kind.title)カテゴリ") { TextField("名前", text: $name) }
            if onSaved != nil && existing == nil {
                Text("追加したカテゴリは、この取引を取消しても一覧に残ります。")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
            if parentID == nil {
                Section("アイコン") {
                    NavigationLink {
                        List {
                            Button { iconName = CategorySymbol.defaultSymbol(name: name, kind: kind) } label: {
                                Label("名前に合わせた標準アイコン", systemImage: CategorySymbol.defaultSymbol(name: name, kind: kind))
                            }
                            ForEach(CategorySymbol.choices, id: \.symbol) { choice in
                                Button { iconName = choice.symbol } label: {
                                    HStack {
                                        Label(choice.title, systemImage: choice.symbol)
                                        Spacer()
                                        if iconName == choice.symbol { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        }.navigationTitle("アイコンを選択")
                    } label: {
                        Label("アイコンを選択", systemImage: iconName ?? existing.map { store.state.categorySymbol($0.id) } ?? CategorySymbol.defaultSymbol(name: name, kind: kind))
                    }
                    Text("配下の小カテゴリと過去の取引にも同じアイコンを表示します。保存すると反映します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("アイコン") {
                    Label("大カテゴリのアイコンを使用", systemImage: store.state.categorySymbol(parentID))
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
                    }.disabled(!store.canEditCurrentBook)
                    Text("アーカイブ操作では、編集中の名前・所属先は保存しません。").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle(existing == nil ? "カテゴリを追加" : "カテゴリを編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let id = store.saveCategory(id: existing?.id, bookID: bookID, kind: kind, name: name, parentID: parentID, iconName: iconName) {
                            onSaved?(id); dismiss()
                        } else { error = store.errorMessage; store.errorMessage = nil }
                    }.disabled(!store.canEditCurrentBook || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                    NavigationLink { CategoryChildSelectionView(parent: parent, currentID: currentID, onSelect: onSelect) } label: {
                        HStack { CategoryIconView(categoryID: parent.id); Text(parent.name); Spacer(); if isSelected(parent) { Image(systemName: "checkmark").foregroundStyle(.teal) } }
                    }
                }
            }
        }.navigationTitle("\(kind.title)カテゴリ")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("カテゴリを追加").disabled(!store.canEditCurrentBook)
                }
            }
            .modifier(CategoryCreationFlow(adding: $adding, bookID: bookID, kind: kind, initialParentID: nil, currentID: currentID, onSelect: onSelect))
    }
    private func isSelected(_ parent: BudgetCategory) -> Bool {
        (currentID == nil && parent.isUncategorized) || store.state.categories.contains { $0.id == currentID && $0.parentID == parent.id }
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
                Text("小カテゴリを選んでください。大カテゴリだけでは登録できません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("小カテゴリを選択") {
                ForEach(store.state.orderedCategories(bookID: parent.bookID, kind: parent.kind, parentID: parent.id).filter { store.state.isCategoryAvailable($0) }) { child in
                    Button { onSelect(child.id) } label: {
                        HStack { CategoryIconView(categoryID: child.id); Text(child.name); Spacer(); if currentID == child.id || (currentID == nil && child.isUncategorized) { Image(systemName: "checkmark") } }
                    }
                }
                if !store.state.categories.contains(where: { $0.parentID == parent.id && store.state.isCategoryAvailable($0) }) {
                    Text("小カテゴリは右上の＋から追加できます。").foregroundStyle(.secondary)
                }
            }
        }.navigationTitle(parent.name)
            .toolbar {
                if !parent.isUncategorized {
                    Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("小カテゴリを追加").disabled(!store.canEditCurrentBook)
                }
            }
            .modifier(CategoryCreationFlow(adding: $adding, bookID: parent.bookID, kind: parent.kind, initialParentID: parent.id, currentID: currentID, onSelect: onSelect))
    }
}

/// Wait for the creation sheet to close before closing its parent selection sheet or pushing a child list.
private struct CategoryCreationFlow: ViewModifier {
    @EnvironmentObject private var store: BudgetStore
    @Binding var adding: Bool
    let bookID: UUID
    let kind: EntryKind
    let initialParentID: UUID?
    let currentID: UUID?
    let onSelect: (UUID) -> Void
    @State private var savedCategoryID: UUID?
    @State private var createdParentID: UUID?
    @State private var showingCreatedParent = false
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $adding, onDismiss: finishCreation) {
                NavigationStack {
                    CategoryEditorView(bookID: bookID, kind: kind, initialParentID: initialParentID, onSaved: { savedCategoryID = $0 })
                }
            }
            .navigationDestination(isPresented: $showingCreatedParent) {
                if let parent = store.state.categories.first(where: { $0.id == createdParentID && $0.bookID == bookID && $0.kind == kind }) {
                    CategoryChildSelectionView(parent: parent, currentID: currentID, onSelect: onSelect)
                }
            }
    }
    private func finishCreation() {
        guard let id = savedCategoryID else { return }
        savedCategoryID = nil
        guard store.canEditBook(bookID), let category = store.state.categories.first(where: { $0.id == id && $0.bookID == bookID && $0.kind == kind }), store.state.isCategoryAvailable(category) else { return }
        if category.parentID == nil {
            createdParentID = id
            showingCreatedParent = true
        } else { onSelect(id) }
    }
}


struct BasicCategorySetView: View {
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let bookID: UUID
    var body: some View {
        List {
            Section {
                Text("確定した初期カテゴリセットです。追加後も標準未分類以外は名称や所属先を変更できます。")
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
                    Button("追加する") { if store.update({ try $0.addBasicCategories(bookID: bookID) }) { dismiss() } }.disabled(!store.canEditCurrentBook)
                }
            }
    }
}
