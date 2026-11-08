import Foundation

@MainActor
func runTagChecks() throws {
    var state = BudgetSnapshot.initial()
    let book = state.books[0].id
    expect(!state.books[0].showsTagSummary, "新規家計簿のタグ集計は初期OFF")
    let tag = try state.saveTag(bookID: book, name: " Travel ")
    expect(state.tags[0].name == "Travel" && state.books[0].hiddenTagIDs.contains(tag), "新規タグは前後トリムし個別表示OFF")
    try state.setTagSummary(bookID: book, enabled: true)
    expect(state.books[0].hiddenTagIDs.contains(tag), "全体をONにしても個別OFFを維持")
    try state.setTagVisible(bookID: book, tagID: tag, visible: true)
    try state.setTagSummary(bookID: book, enabled: false)
    try state.setTagSummary(bookID: book, enabled: true)
    expect(!state.books[0].hiddenTagIDs.contains(tag), "全体OFFを挟んでも個別の表示設定を保持")
    let bank = try state.saveAccount(bookID: book, name: " Bank ")
    rejects("タグの大小文字重複を禁止") { try state.saveTag(bookID: book, name: "travel") }
    rejects("入出金元の大小文字重複を禁止") { try state.saveAccount(bookID: book, name: "bank") }
    rejects("標準お財布と同名の一般項目を禁止") { try state.saveAccount(bookID: book, name: " お財布 ") }
    let other = try state.saveAccount(bookID: book, name: "カード")
    rejects("一般項目の改名も同名禁止") { try state.saveAccount(id: other, bookID: book, name: "BANK") }
    try state.setTagArchived(id: tag, bookID: book, archived: true)
    try state.setAccountArchived(id: bank, bookID: book, archived: true)
    rejects("アーカイブ済みタグとも大小文字を無視して重複禁止") { try state.saveTag(bookID: book, name: "TRAVEL") }
    rejects("アーカイブ済み入出金元とも大小文字を無視して重複禁止") { try state.saveAccount(bookID: book, name: "BANK") }
    let freshTag = try state.saveTag(bookID: book, name: "新規")
    rejects("タグ改名でアーカイブ済みと同名禁止") { try state.saveTag(id: freshTag, bookID: book, name: "travel") }
    try state.saveTag(id: tag, bookID: book, name: "TRAVEL")
    try state.saveAccount(id: bank, bookID: book, name: "BANK")
    expect(state.tags.first { $0.id == tag }!.name == "TRAVEL" && state.accounts.first { $0.id == bank }!.name == "BANK", "自分自身だけの大文字小文字変更は許可")
    let foreign = try state.createBook(name: "別家計簿", shared: false)
    _ = try state.saveTag(bookID: foreign, name: "travel")
    _ = try state.saveAccount(bookID: foreign, name: "bank")
    expect(true, "別家計簿では同名タグ・入出金元を許可")
    _ = try state.saveTag(bookID: book, name: "ＴＲＡＶＥＬ")
    _ = try state.saveAccount(bookID: book, name: "ＢＡＮＫ")
    _ = try state.saveTag(bookID: book, name: "T RAVEL")
    expect(true, "全角半角と内部空白は区別")
    rejects("全角英字同士の大小文字重複タグは禁止") { try state.saveTag(bookID: book, name: "ｔｒａｖｅｌ") }
    let wallet = state.accounts.first { $0.bookID == book && $0.isWallet }!.id
    let expense = BudgetEntry(bookID: book, kind: .expense, amount: 1000, date: Date(), sourceID: wallet, tagIDs: [freshTag])
    try state.saveTransaction(expense)
    let beforeEntries = state.entries
    let ids = state.orderedTags(bookID: book).map(\.id).reversed().map { $0 }
    try state.reorderTags(bookID: book, ids: ids)
    expect(state.orderedTags(bookID: book).map(\.id) == ids && state.entries == beforeEntries, "タグ順変更は関連取引を変えず表示順だけ変更")
    rejects("タグ並べ替えの重複IDを禁止") { try state.reorderTags(bookID: book, ids: Array(repeating: tag, count: ids.count)) }
    rejects("タグ並べ替えで欠落を禁止") { try state.reorderTags(bookID: book, ids: [tag]) }
    let foreignTag = state.tags.first { $0.bookID == foreign }!.id
    rejects("タグ並べ替えで別家計簿を混在させない") { try state.reorderTags(bookID: book, ids: [foreignTag] + Array(ids.dropFirst())) }
    rejects("個別表示設定で家計簿越境を禁止") { try state.setTagVisible(bookID: book, tagID: foreignTag, visible: true) }
    let newLast = try state.saveTag(bookID: book, name: "最後")
    expect(state.orderedTags(bookID: book).last?.id == newLast, "並べ替え後の新規タグは末尾")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let repository = JSONBudgetRepository(url: folder.appendingPathComponent("tags.json"))
    try repository.save(state)
    expectBackup(try repository.load() == state, "タグ順と全体・個別表示設定を通常保存で保持")
    let cipher = try BackupCodec.encrypt(BackupPayload(snapshot: state), password: "tags-password")
    expectBackup(try BackupCodec.decrypt(cipher, password: "tags-password").snapshot == state, "タグ順・表示設定・関連を暗号化往復で保持")
    try state.setBookArchived(id: book, archived: true)
    rejects("閲覧専用のタグ順変更を禁止") { try state.reorderTags(bookID: book, ids: state.orderedTags(bookID: book).map(\.id)) }
    rejects("閲覧専用の全体タグ表示設定変更を禁止") { try state.setTagSummary(bookID: book, enabled: false) }
    rejects("閲覧専用の個別タグ表示設定変更を禁止") { try state.setTagVisible(bookID: book, tagID: tag, visible: false) }
    var legacy = BudgetSnapshot.initial()
    let legacyBook = legacy.books[0].id
    legacy.books[0].showsTagSummary = true
    legacy.tags = [BudgetTag(bookID: legacyBook, name: "従来表示"), BudgetTag(bookID: legacyBook, name: "従来非表示")]
    legacy.books[0].hiddenTagIDs = [legacy.tags[1].id]
    let data = try JSONEncoder().encode(legacy)
    let reopened = try JSONDecoder().decode(BudgetSnapshot.self, from: data)
    expect(reopened.books[0].showsTagSummary && reopened.books[0].hiddenTagIDs == legacy.books[0].hiddenTagIDs, "既存の全体ON・個別設定を勝手にOFFへ変更しない")
    expect(reopened.orderedTags(bookID: legacyBook).map(\.id) == legacy.tags.map(\.id), "旧JSONの順序なしタグは配列順を保持")
}
