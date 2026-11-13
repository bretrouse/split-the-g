import SwiftUI
import RealityKit
import ARKit
import Vision

class AppState: ObservableObject {
    @Published var statusText: String = "Scanning..."
    var onReset: (() -> Void)? // The bridge to our ARViewController
}

struct ContentView: View {
    @StateObject private var appState = AppState()
    
    var body: some View {
        ZStack(alignment: .bottom) {
            ARViewContainer(appState: appState)
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 15) {
                Text(appState.statusText)
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(10)
                
                Button(action: {
                    // Trigger the reset callback when tapped
                    appState.onReset?()
                }) {
                    Text("Reset")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 12)
                        .background(Color.blue)
                        .cornerRadius(8)
                }
            }
            .padding(.bottom, 40)
        }
    }
}

struct ARViewContainer: UIViewControllerRepresentable {
    @ObservedObject var appState: AppState
    
    func makeUIViewController(context: Context) -> ARViewController {
        let vc = ARViewController()
        vc.appState = appState
        return vc
    }
    
    func updateUIViewController(_ uiViewController: ARViewController, context: Context) {}
}
