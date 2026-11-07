import SwiftUI

@main
struct BudgetBookApp: App {
    @StateObject private var store = BudgetStore()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store).tint(.teal)
                .environment(\.locale, Locale(identifier: "ja_JP"))
        }
    }
}
