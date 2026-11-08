import Foundation

@MainActor
func runCategoryChecks() throws {
    var fresh = BudgetSnapshot.initial()
    let book = fresh.books[0].id, wallet = fresh.accounts.first!.id
    expect(fresh.books.count == 1 && fresh.books[0].name == "個人用", "初回は個人用1冊だけ作成")
    expect(fresh.schemaVersion == 2, "親子必須構造は新しいスキーマ版で保存")
    let expenseNames = ["食費", "日用品", "住居費", "水道・光熱費", "通信費", "交通費", "自動車費", "衣服・美容", "健康・医療", "趣味・娯楽", "交際費", "教育・子育て", "保険", "税金・社会保険", "その他", "未分類"]
    let incomeNames = ["給与", "事業・副業", "年金・給付金", "運用収入", "臨時収入", "その他", "未分類"]
    expect(fresh.orderedCategories(bookID: book, kind: .expense, parentID: nil).map(\.name) == expenseNames, "確定した支出の初期表示順・末尾のその他と未分類")
    expect(fresh.orderedCategories(bookID: book, kind: .income, parentID: nil).map(\.name) == incomeNames, "確定した収入の初期表示順")
    let supplies = fresh.categories.first { $0.bookID == book && $0.kind == .expense && $0.name == "日用品" && $0.parentID == nil }!
    expect(fresh.orderedCategories(bookID: book, kind: .expense, parentID: supplies.id).map(\.name) == ["生活消耗品", "掃除・洗濯用品", "生活雑貨", "タバコ", "その他"], "日用品の確定した小カテゴリと順序")
    let salary = fresh.categories.first { $0.kind == .income && $0.name == "給与" && $0.parentID == nil }!
    expect(fresh.orderedCategories(bookID: book, kind: .income, parentID: salary.id).map(\.name) == ["給与", "賞与", "各種手当", "その他"], "給与の確定した小カテゴリと順序")
    expect(fresh.categories.filter { $0.parentID == nil }.allSatisfy { root in fresh.categories.contains { $0.parentID == root.id } }, "初期カテゴリの全大カテゴリに小カテゴリを用意")
    for kind in [EntryKind.expense, .income] {
        let defaults = fresh.categories.filter { $0.bookID == book && $0.kind == kind && $0.isUncategorized }
        let root = defaults.first { $0.parentID == nil }!, child = defaults.first { $0.parentID != nil }!
        expect(defaults.count == 2 && child.parentID == root.id && root.name == "未分類" && child.name == "未分類", "収支別に標準未分類の親子を作成")
        for category in defaults {
            rejects("標準未分類の親・子を改名できない") { try fresh.saveCategory(id: category.id, bookID: book, kind: kind, name: "変更", parentID: category.parentID) }
            rejects("標準未分類の親・子をアーカイブできない") { try fresh.setCategoryArchived(id: category.id, bookID: book, archived: true) }
        }
        let input = BudgetEntry(bookID: book, kind: kind, amount: 100, date: Date(), sourceID: kind == .expense ? wallet : nil, destinationID: kind == .income ? wallet : nil)
        expectBackup(try fresh.validated(input).categoryID == child.id, "未選択保存は未分類の小カテゴリを補完")
        var invalid = input; invalid.categoryID = root.id
        rejects("未分類の大カテゴリも直接指定できない") { _ = try fresh.validated(invalid) }
    }
    var input = BudgetEntry(bookID: book, kind: .expense, amount: 100, date: Date(), categoryID: supplies.id, sourceID: wallet)
    rejects("通常の大カテゴリに直接登録できない") { try fresh.saveTransaction(input) }
    let child = fresh.categories.first { $0.parentID == supplies.id }!
    input.categoryID = child.id
    try fresh.saveTransaction(input)
    try fresh.setCategoryArchived(id: supplies.id, bookID: book, archived: true)
    var archived = fresh.entries[0]; archived.memo = "保持"
    try fresh.saveTransaction(archived)
    expect(fresh.entries[0].categoryID == child.id, "親アーカイブ中も既存の小カテゴリを保持して再保存")
    input.id = UUID()
    rejects("新規取引では親アーカイブ中の子を選べない") { try fresh.saveTransaction(input) }
    let second = try fresh.createBook(name: "共有用", shared: true)
    expect(fresh.categories.filter { $0.bookID == second }.count == BudgetSnapshot.initial().categories.count, "追加家計簿にも同一の初期セット")
    let secondFood = fresh.categories.first { $0.bookID == second && $0.name == "食費" && $0.parentID == nil }!
    try fresh.saveCategory(id: secondFood.id, bookID: second, kind: .expense, name: "共有の食費", parentID: nil)
    expect(fresh.categories.contains { $0.bookID == book && $0.name == "食費" && $0.parentID == nil }, "家計簿間でカテゴリを独立編集")
    let asciiRoot = try fresh.saveCategory(bookID: book, kind: .expense, name: "ABC", parentID: nil)
    try fresh.setCategoryArchived(id: asciiRoot, bookID: book, archived: true)
    rejects("アーカイブ済みも含め英字大小文字・前後空白の同名を禁止") { try fresh.saveCategory(bookID: book, kind: .expense, name: " abc ", parentID: nil) }
    _ = try fresh.saveCategory(bookID: book, kind: .expense, name: "ＡＢＣ", parentID: nil)
    _ = try fresh.saveCategory(bookID: book, kind: .expense, name: "A BC", parentID: nil)
    expect(true, "全半角・途中空白の違いは維持")
    rejects("全角英字同士でも大小文字差を無視する") { try fresh.saveCategory(bookID: book, kind: .expense, name: "ａｂｃ", parentID: nil) }

    // A real v1-shaped fixture: two books, protected roots only, an archived root used by an expense and its refund.
    var legacy = BudgetSnapshot(); legacy.schemaVersion = 1
    legacy.books = [HouseholdBook(name: "旧個人"), HouseholdBook(name: "旧共有", isShared: true)]
    for legacyBook in legacy.books {
        legacy.accounts.append(MoneyAccount(bookID: legacyBook.id, name: "お財布", isWallet: true))
        for kind in [EntryKind.expense, .income] {
            legacy.categories.append(BudgetCategory(bookID: legacyBook.id, name: "未分類", kind: kind, isUncategorized: true, order: 6))
        }
    }
    legacy.selectedBookID = legacy.books[1].id
    let oldBook = legacy.books[0].id, oldWallet = legacy.accounts[0].id
    let oldRoot = BudgetCategory(bookID: oldBook, name: "旧分類", kind: .expense, isArchived: true, order: 3)
    let oldChild = BudgetCategory(bookID: oldBook, name: "直接登録（移行分）", kind: .expense, parentID: oldRoot.id, isArchived: true, order: 8)
    legacy.categories += [oldRoot, oldChild]
    let now = Calendar.current.startOfDay(for: Date())
    let oldExpense = BudgetEntry(bookID: oldBook, kind: .expense, amount: 1000, date: now, categoryID: oldRoot.id, sourceID: oldWallet, memo: "維持", merchant: "旧店舗", createdAt: now)
    let oldRefund = BudgetEntry(bookID: oldBook, kind: .refund, amount: 200, date: now, categoryID: oldRoot.id, destinationID: oldWallet, refundOfID: oldExpense.id)
    let oldUncategorized = legacy.categories.first { $0.bookID == oldBook && $0.kind == .income && $0.isUncategorized }!
    let oldIncome = BudgetEntry(bookID: oldBook, kind: .income, amount: 300, date: now, categoryID: oldUncategorized.id, destinationID: oldWallet)
    legacy.entries = [oldExpense, oldRefund, oldIncome]
    try legacy.validateBackup()
    let migrated = try legacy.migratedCategoryHierarchy()
    expect(migrated.schemaVersion == 2 && migrated.books == legacy.books && migrated.selectedBookID == legacy.selectedBookID, "移行は旧2冊と選択・表示設定を維持")
    expect(migrated.categories.filter { $0.isUncategorized }.count == 8, "旧2冊へ収支別の未分類の子を追加")
    expect(legacy.categories.allSatisfy { old in migrated.categories.first { $0.id == old.id } == old }, "既存カテゴリのID・名称・順序・アーカイブを変更しない")
    let replacement = migrated.categories.first { $0.id == migrated.entries[0].categoryID }!
    expect(replacement.parentID == oldRoot.id && replacement.name == "直接登録（移行分） 2", "既存名と衝突しない移行先の子を追加")
    expect(migrated.entries.map(\.id) == legacy.entries.map(\.id) && migrated.entries.map(\.amount) == legacy.entries.map(\.amount), "移行で取引ID・金額・順序を維持")
    expect(migrated.entries[1].categoryID == replacement.id && migrated.entries[1].refundOfID == oldExpense.id, "元支出と返金を同じ子へ移し関連を維持")
    expect(migrated.entries[0].memo == oldExpense.memo && migrated.entries[0].merchant == oldExpense.merchant && migrated.entries[0].createdAt == oldExpense.createdAt, "メモ・相手先・登録日時を維持")
    expect(migrated.categories.first { $0.id == migrated.entries[2].categoryID }?.parentID == oldUncategorized.id, "旧未分類取引は同じ親の保護された子へ移行")
    expect(migrated.categoryAmounts(bookID: oldBook, kind: .expense, entries: migrated.entries)[oldRoot.id] == 800, "移行前後で元の大カテゴリ集計額を維持")
    expect(!migrated.isCategoryAvailable(replacement), "移行先も元の親のアーカイブ状態に従う")
    expectBackup(try migrated.migratedCategoryHierarchy() == migrated, "移行を繰り返してもIDや件数を変更しない")
    try migrated.validateBackup()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let repository = JSONBudgetRepository(url: folder.appendingPathComponent("legacy.json"))
    let rollback = try RollbackRecord.make(snapshot: legacy, now: now, key: TestRollbackKeys().key(createIfMissing: true))
    try JSONEncoder().encode(BudgetStorage(snapshot: legacy, rollback: rollback)).write(to: repository.url)
    let loaded = try repository.load()!
    expect(loaded.schemaVersion == 2, "通常保存ファイルの読込時に移行")
    let written = try Data(contentsOf: repository.url)
    let disk = try JSONDecoder().decode(BudgetStorage.self, from: written)
    expect(disk.snapshot == loaded && disk.rollback?.sealed == rollback.sealed, "移行結果と既存暗号化退避を原子的に保持")
    expectBackup(try repository.load() == loaded && Data(contentsOf: repository.url) == written, "再読込では移行済みファイルを書き換えない")
    let oldEncrypted = try BackupCodec.encrypt(BackupPayload(snapshot: legacy, createdAt: now), password: "category-migrate")
    let decoded = try BackupCodec.decrypt(oldEncrypted, password: "category-migrate")
    expect(decoded.snapshot.schemaVersion == 2 && decoded.createdAt == now && decoded.snapshot.entries.map(\.amount) == legacy.entries.map(\.amount), "旧暗号化バックアップの復号時に構造を移行し日時・金額を保持")
    let reopened = try BackupCodec.decrypt(BackupCodec.encrypt(BackupPayload(snapshot: loaded), password: "category-migrate"), password: "category-migrate")
    expect(reopened.snapshot == loaded, "新構造の暗号化ファイルを関連ごと往復")
    let undone = try RestoreCoordinator(repository: repository, keys: TestRollbackKeys()).undo(now: now.addingTimeInterval(1))
    expect(undone.schemaVersion == 2 && undone.entries.map(\.amount) == legacy.entries.map(\.amount), "旧版の暗号化退避も新構造に移行して戻せる")
    var broken = legacy; broken.categories.removeAll { $0.id == oldUncategorized.id }
    let brokenData = try JSONEncoder().encode(broken)
    try brokenData.write(to: repository.url)
    rejects("不正な旧データは移行前に拒否") { _ = try repository.load() }
    expectBackup(try Data(contentsOf: repository.url) == brokenData, "移行検証失敗で元ファイルを維持")
    var invalid = loaded; invalid.entries[0].categoryID = oldRoot.id
    rejects("新形式のバックアップでは大カテゴリの直接参照を拒否") { try invalid.validateBackup() }
    invalid = loaded; invalid.categories.removeAll { $0.isUncategorized && $0.parentID != nil }
    rejects("新形式で保護された未分類の子の欠落を拒否") { try invalid.validateBackup() }
    invalid = loaded; invalid.schemaVersion = 99
    rejects("未来の保存版は移行しない") { _ = try invalid.migratedCategoryHierarchy() }
    let beforeSet = fresh
    try fresh.addBasicCategories(bookID: second)
    expect(fresh.categories.filter { $0.bookID == second && $0.name == "共有の食費" }.count == 1, "基本セット追加でユーザーが変更した名称を維持")
    let afterSet = fresh
    try fresh.addBasicCategories(bookID: second)
    expect(fresh == afterSet && fresh.books == beforeSet.books, "基本セットの追加は冪等で家計簿を増やさない")
}
