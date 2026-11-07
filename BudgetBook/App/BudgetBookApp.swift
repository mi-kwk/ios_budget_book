import SwiftUI
import CloudKit

@main
struct BudgetBookApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = BudgetStore()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).tint(.teal)
                .environment(\.locale, Locale(identifier: "ja_JP"))
                .onAppear { store.setAppActive(scenePhase == .active) }
                .onChange(of: scenePhase) { _, phase in store.setAppActive(phase == .active) }
                .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in store.cloudAccountChanged() }
        }
    }
}
