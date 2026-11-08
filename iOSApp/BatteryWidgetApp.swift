import SwiftUI
import UIKit

@main
struct BatteryWidgetApp: App {
    @StateObject private var vm: BatteryViewModel

    init() {
        let model = BatteryViewModel()
        _vm = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
        }
    }
}
