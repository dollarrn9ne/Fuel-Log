import SwiftUI
import SwiftData
import FuelLogShared

@main
struct FuelLogAppClipApp: App {
    var modelContainerResult: Result<ModelContainer, Error> = FuelLogContainer.makeContainer()

    var body: some Scene {
        WindowGroup {
            switch modelContainerResult {
            case .success(let container):
                AppClipRootView()
                    .modelContainer(container)
            case .failure(let error):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.red)
                    Text("Unable to Load")
                        .font(.title3.bold())
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding()
            }
        }
    }
}
