import SwiftUI
import UniformTypeIdentifiers

extension UTType { static let budgetBackup = UTType(exportedAs: "com.mikwk.budgetbook.backup", conformingTo: .data) }

struct EncryptedBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.budgetBackup] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count <= BackupCodec.maxBytes else { throw BackupError.invalidFormat }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct BackupStatusView: View {
    @EnvironmentObject private var store: BudgetStore
    @State private var password = ""
    @State private var confirmationPassword = ""
    @State private var restorePassword = ""
    @State private var document: EncryptedBackupDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var busy = false
    @State private var prepared: BackupPayload?
    @State private var message: String?
    @State private var confirmRestore = false
    @State private var confirmUndo = false
    @State private var confirmDelete = false
    @State private var lastExport: Date?
    var body: some View {
        Form {
            Section("暗号化ファイルを書き出す") {
                SecureField("パスワード（8文字以上）", text: $password).textContentType(.newPassword)
                SecureField("同じパスワードを再入力", text: $confirmationPassword).textContentType(.newPassword)
                Text("全家計簿・取引・カテゴリ・タグ・入出金元・保存済みの設定をまとめます。パスワードは保存しません。忘れると復元できません。").font(.caption).foregroundStyle(.secondary)
                Button("ファイルへ書き出す", systemImage: "square.and.arrow.up") { exportBackup() }
                    .disabled(busy || !store.canWrite)
                if let lastExport { LabeledContent("この画面での最終書き出し", value: lastExport.formatted(date: .abbreviated, time: .shortened)).font(.caption) }
            }
            Section("ファイルから復元") {
                SecureField("復元するファイルのパスワード", text: $restorePassword)
                Button("バックアップファイルを選ぶ", systemImage: "doc.badge.arrow.up") {
                    prepared = nil; importing = true
                }.disabled(busy || restorePassword.isEmpty || !store.canWrite)
                Text("パスワードを確認して内容を表示します。この時点では現在のデータを変更しません。対応ファイルの上限は32MBです。").font(.caption).foregroundStyle(.secondary)
            }
            if let prepared {
                Section("復元する内容") {
                    LabeledContent("バックアップ日時", value: prepared.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("家計簿数", value: String(prepared.snapshot.books.count))
                    LabeledContent("取引件数", value: String(prepared.snapshot.entries.count))
                    Text("すべての家計簿・設定を置き換えます。現在のデータとの統合は行いません。直前の状態を端末内に7日間退避します。以前の退避がある場合は最新1件に置き換わります。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("確認して全データを復元", role: .destructive) { confirmRestore = true }.disabled(busy)
                    Button("このファイルの選択を取り消す") { self.prepared = nil }
                }
            }
            if let rollback = store.rollbackRecord {
                Section("復元前のデータ") {
                    LabeledContent("退避日時", value: rollback.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("保持期限", value: rollback.expiresAt.formatted(date: .abbreviated, time: .shortened))
                    Text("戻すと、復元後に追加・編集した記録は失われます。必要なら上の書き出し機能で、現在のデータを先に保存してください。").font(.caption).foregroundStyle(.secondary)
                    Button("復元前に戻す", role: .destructive) { confirmUndo = true }.disabled(busy || Date() >= rollback.expiresAt)
                    Button("退避データを削除", role: .destructive) { confirmDelete = true }.disabled(busy)
                }
            }
            CloudBackupSection { payload in
                prepared = payload
                message = "iCloudから内容を確認しました。日時・件数を確認してから復元してください。"
            }
            if busy { Section { ProgressView("処理中…") } }
            if let message { Section("結果") { Text(message).accessibilityIdentifier("backup-result") } }
        }.navigationTitle("バックアップ・復元")
            .interactiveDismissDisabled(busy)
            .fileExporter(isPresented: $exporting, document: document, contentType: .budgetBackup, defaultFilename: filename) { result in
                document = nil
                switch result {
                case .success: lastExport = Date(); message = "暗号化バックアップを書き出しました。"
                case .failure(let error): message = "書き出しを完了できませんでした。\(error.localizedDescription)"
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.budgetBackup, .data]) { result in
                switch result {
                case .success(let url): loadBackup(url)
                case .failure(let error): message = "ファイルを開けませんでした。\(error.localizedDescription)"
                }
            }
            .confirmationDialog("現在の全データを置き換えます。復元しますか？", isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("全データを置き換えて復元", role: .destructive) {
                    guard let prepared else { return }
                    do {
                        try store.restoreBackup(prepared)
                        self.prepared = nil; message = "復元しました。復元前の状態は7日間保持します。"
                    } catch { message = error.localizedDescription }
                }
            }
            .confirmationDialog("復元後に追加・編集した記録が失われます。必要なら先に現在のデータを書き出してください。", isPresented: $confirmUndo, titleVisibility: .visible) {
                Button("復元前の全データに戻す", role: .destructive) {
                    do { try store.undoRestore(); prepared = nil; message = "復元前の状態に戻しました。" }
                    catch { message = error.localizedDescription }
                }
            }
            .confirmationDialog("退避データを削除すると、復元前に戻せなくなります。現在の家計簿データは残ります。", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("退避データを削除", role: .destructive) {
                    do { try store.clearRollback(); message = "退避データを削除しました。" }
                    catch { message = error.localizedDescription }
                }
            }
            .onAppear { store.refreshRollback() }
    }
    private var filename: String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "家計簿-\(formatter.string(from: Date())).budgetbackup"
    }
    private func exportBackup() {
        guard password == confirmationPassword else { message = "確認用パスワードが一致しません。"; return }
        let payload = BackupPayload(snapshot: store.state)
        let password = password
        busy = true; message = nil
        Task {
            do {
                let data = try await Task.detached(priority: .userInitiated) { try BackupCodec.encrypt(payload, password: password) }.value
                document = EncryptedBackupDocument(data: data); exporting = true
            } catch { message = error.localizedDescription }
            self.password = ""; confirmationPassword = ""; busy = false
        }
    }
    private func loadBackup(_ url: URL) {
        let password = restorePassword
        busy = true; message = nil
        Task {
            do {
                prepared = try await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: BackupCodec.maxBytes + 1) ?? Data()
                    return try BackupCodec.decrypt(data, password: password)
                }.value
                message = "内容を確認しました。下の件数・日時を確認してから復元してください。"
            } catch { prepared = nil; message = error.localizedDescription }
            restorePassword = ""; busy = false
        }
    }
}

struct CloudBackupSection: View {
    @EnvironmentObject private var store: BudgetStore
    let onPrepared: (BackupPayload) -> Void
    @State private var password = ""
    @State private var confirmation = ""
    @State private var selected: CloudBackupItem?
    @State private var localMessage: String?
    var body: some View {
        Section("iCloudバックアップ") {
            Text("暗号化したバックアップをiCloudの非公開領域に保存します。端末間の常時同期は行いません。成功した最新3回分を残します。")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("iCloud用パスワード（8文字以上）", text: $password)
            SecureField("同じパスワードを再入力", text: $confirmation)
            Text("自動保存のため、この端末のKeychainに保存します。機種変更先で同じパスワードが必要です。変更前のバックアップには以前のパスワードが必要です。")
                .font(.caption).foregroundStyle(.secondary)
            Button("パスワードを設定・変更") {
                guard password == confirmation else { localMessage = "確認用パスワードが一致しません。"; return }
                let value = password
                Task { await store.configureCloudPassword(value); password = ""; confirmation = "" }
            }.disabled(store.cloudBusy || password.count < 8)
            Toggle("利用中に自動保存（1日1回を目安）", isOn: Binding(get: { store.cloudSettings.enabled && !store.cloudSettings.pausedAfterRestore }, set: store.setCloudAutomation))
                .disabled(store.cloudBusy || store.cloudSettings.accountFingerprint == nil)
            if store.cloudSettings.pausedAfterRestore {
                Text("復元後の自動保存は停止中です。アカウント・保存内容を確認し、パスワードを設定するか自動保存を再開してください。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("今すぐiCloudへ保存", systemImage: "icloud.and.arrow.up") { Task { await store.saveToCloud() } }
                .disabled(store.cloudBusy || store.cloudSettings.accountFingerprint == nil)
            if let date = store.cloudSettings.lastSuccessfulAt {
                LabeledContent("最終保存成功", value: date.formatted(date: .abbreviated, time: .shortened))
            }
            if let error = store.cloudSettings.lastError { Text(error).foregroundStyle(.red).font(.caption) }
            if let warning = store.cloudSettings.maintenanceWarning { Text(warning).font(.caption).foregroundStyle(.secondary) }
            if let localMessage { Text(localMessage).foregroundStyle(.red).font(.caption) }
            if store.cloudBusy { ProgressView("iCloudを確認中…") }
            if let message = store.cloudMessage { Text(message).font(.caption) }
        }
        Section("iCloudから復元") {
            Button("一覧を更新", systemImage: "arrow.clockwise") { Task { await store.refreshCloudBackups() } }.disabled(store.cloudBusy)
            ForEach(store.cloudBackups) { item in
                Button { selected = item } label: { Label(item.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: "icloud.and.arrow.down") }
                    .disabled(store.cloudBusy)
            }
            if store.cloudBackups.isEmpty { Text("バックアップ一覧は「一覧を更新」で確認できます。").font(.caption).foregroundStyle(.secondary) }
            Text("パスワードで内容を確認した後、上の復元確認欄で全データ置換を実行します。復元前の状態は端末内に7日間退避します。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $selected) { item in
            NavigationStack { CloudRestorePasswordView(item: item, onPrepared: onPrepared) }
        }
    }
}

struct CloudRestorePasswordView: View {
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let item: CloudBackupItem
    let onPrepared: (BackupPayload) -> Void
    @State private var password = ""
    @State private var error: String?
    var body: some View {
        Form {
            LabeledContent("バックアップ日時", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
            SecureField("保存時のiCloud用パスワード", text: $password)
            Text("この段階では現在の家計簿を変更しません。復号後に日時・家計簿数・取引件数を表示します。")
                .font(.caption).foregroundStyle(.secondary)
            Button("内容を確認") {
                let value = password
                Task {
                    do { let payload = try await store.prepareCloudRestore(item, password: value); password = ""; dismiss(); onPrepared(payload) }
                    catch { self.error = CloudBackupMessages.describe(error); password = "" }
                }
            }.disabled(password.isEmpty || store.cloudBusy)
            if store.cloudBusy { ProgressView("読み込み中…") }
            if let error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("iCloudから確認")
            .interactiveDismissDisabled(store.cloudBusy)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(store.cloudBusy) } }
    }
}
