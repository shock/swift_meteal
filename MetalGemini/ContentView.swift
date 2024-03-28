//
//  ContentView.swift
//  MetalGemini
//
//  Created by Gemini on 3/27/24.
//

import SwiftUI
import MetalKit

struct AppMenuKey: EnvironmentKey {
    static let defaultValue: NSMenu? = nil // Default value of nil
}

// Add an extension for your environment key:
extension EnvironmentValues {
    var appMenu: NSMenu? {
        get { self[AppMenuKey.self] }
        set { self[AppMenuKey.self] = newValue }
    }
}

class SharedDataModel: ObservableObject {
    @Published var frameCount: UInt32 = 0
    @Published var lastFrame: UInt32 = 0
    @Published var fps: Double = 0
    @Published var lastTime: TimeInterval = Date().timeIntervalSince1970
}

struct ContentView: View {
    @Environment(\.appMenu) var appMenu // Property for holding menu reference
    @StateObject var model = SharedDataModel()
    
    var date = Date()
    
    var body: some View {
        VStack{
            MetalView(model: model)
                .environment(\.appMenu, appDelegate.mainMenu) // Add menu to the environment
            Text("FPS: \(model.fps)").padding([.bottom],6)
        }
        .onChange(of: model.frameCount) {
            doFrame()
        }
    }
    
    func doFrame() {
        let now = Date().timeIntervalSince1970
        let delta = now - model.lastTime
        if( delta ) > 1 {
            model.lastTime = now
            let frames = model.frameCount - model.lastFrame
            model.lastFrame = model.frameCount
            model.fps = Double(frames) / delta
        }
     }

}

#Preview {
    ContentView()
}
