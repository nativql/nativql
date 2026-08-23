import SwiftUI

@main
struct NativQLApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
    }
}

struct ContentView: View {
    var body: some View {
        Text("NativQL")
            .font(.largeTitle)
    }
}
