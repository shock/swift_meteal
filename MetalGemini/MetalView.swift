//
//  MetalView.swift
//  MetalGemini
//
//  Created by Gemini on 3/27/24.
//

import SwiftUI
import MetalKit

struct ViewportSize {
    var width: Float
    var height: Float
}


public let MAX_RENDER_BUFFERS = 4


// we need this to get access to the inner class of MetalView
typealias MetalViewCoordinator = MetalView.Coordinator
// we need this because makeCoordinator gets called every time MetalView
// is hidden (eg. shader error), and if we don't reuse an existing coordinator, a new one gets created
// which can allocate resources faster than they can be released during off-line rendering.  yuck.
var existingCoordinator: MetalViewCoordinator?


struct MetalView: NSViewRepresentable {
    @ObservedObject var renderMgr: RenderManager // Reference the ObservableObject
    let retinaEnabled = false

    func makeCoordinator() -> Coordinator {
        if let coordinator = existingCoordinator {
            return coordinator
        }
        existingCoordinator = Coordinator(self, renderMgr: renderMgr)
        return existingCoordinator!
    }

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.delegate = context.coordinator
        mtkView.preferredFramesPerSecond = 60

        if let metalDevice = MTLCreateSystemDefaultDevice() {
            mtkView.device = metalDevice
        }
        mtkView.framebufferOnly = false
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtkView.drawableSize = mtkView.frame.size
        mtkView.autoResizeDrawable = true  // setting this to false requires updateNSView to update the view's drawableSize
        return mtkView
    }

    func updateNSView(_ mtkView: MTKView, context: Context) {
        if( !retinaEnabled ) {
            // with mtkView.autoResizeDrawable = false, we have to do this
            // also, this is also how we avoid retina x2 texture sizes, which we may not always want to do
            if( mtkView.frame.size != mtkView.drawableSize ) {
                mtkView.drawableSize = mtkView.frame.size
                print("updateNSView: mtkView.drawableSize resized: \(mtkView.frame.size)")
            }
        }
    }

    func sizeThatFits( _ proposal: ProposedViewSize,
                       nsView: Self.NSViewType,
                       context: Self.Context ) -> CGSize? {
        return nil
    }


    struct SysUniforms {
        var vpSize: ViewportSize
        var frameCount: UInt32
        var timeInterval: Float
        var passNum: UInt32
    }

    class Coordinator: NSObject, MTKViewDelegate {

        private var renderMgr: RenderManager
        private var parent: MetalView
        public private(set) var metalDevice: MTLDevice!
        private var metalCommandQueue: MTLCommandQueue!
        private var sysUniformBuffer: MTLBuffer?
        private var frameCounter: UInt32
        private var renderTimer: Timer?
        private var renderingActive = false
//        public private(set) var metallibURL: URL?
        private var reloadShaders = false
        public private(set) var renderSync = MutexRunner()
        var resourceMgr: MetalResourceManager!
        var samplerState: MTLSamplerState?
        private var saveWorkItem: DispatchWorkItem? // Work item for saving uniforms
        private var resizeQueue = DispatchQueue(label: "net.wdoughty.metaltoy.resizeView")

        init(_ parent: MetalView, renderMgr: RenderManager ) {
            self.parent = parent
            self.frameCounter = 0
            self.renderMgr = renderMgr
            self.renderSync = renderMgr.renderSync
            super.init()

            if let metalDevice = MTLCreateSystemDefaultDevice() {
                self.metalDevice = metalDevice
            }
            self.metalCommandQueue = metalDevice.makeCommandQueue()!
            self.resourceMgr = renderMgr.resourceMgr
            renderMgr.setViewCoordinator(self)

            // must initialize render buffers
            createUniformBuffers()
            updateViewportSize(CGSize(width:2,height:2))

        }

//        func setupShaders() async throws {
//            print("MetalView: setupShaders()")
//            try await resourceMgr.setupPipelines(metallibURL: metallibURL)
//        }

        func setupRenderBuffers(_ size: CGSize) {
            print("MetalView: setupRenderBuffers(\(size) on thread \(Thread.current)")
            resourceMgr.createBuffers(numBuffers: MAX_RENDER_BUFFERS, size: size)
        }

        func createUniformBuffers() {
            // 32 bytes is more than enough to hold SysUniforms, packed
            sysUniformBuffer = metalDevice.makeBuffer(length: 32, options: .storageModeShared)
        }

        // Schedule a task to save the uniforms to a file, cancelling any previous scheduled task
        private func requestBufferResize(_ size: CGSize) {
            saveWorkItem?.cancel() // Cancel the previous task if it exists
            saveWorkItem = DispatchWorkItem { [weak self] in
                self?.setupRenderBuffers(size)
            }

            // Schedule the resize after a delay
            if let saveWorkItem = saveWorkItem {
                resizeQueue.asyncAfter(deadline: .now() + 0.01, execute: saveWorkItem)
            }
        }

        func updateViewportSize(_ size: CGSize) {
            var viewportSize = ViewportSize(width: Float(size.width), height: Float(size.height))
            let bufferPointer = sysUniformBuffer!.contents()
            memcpy(bufferPointer, &viewportSize, MemoryLayout<ViewportSize>.size)
            renderMgr.setViewSize(size)
            renderMgr.resetFrame()
            requestBufferResize(size)
        }

//        func loadShader(metallibURL: URL?) async throws {
//            print("MetalView: loadShader(\(String(describing: metallibURL?.lastPathComponent))")
//            self.metallibURL = metallibURL
//            try await reinitShaders()
//        }
//
//        func reinitShaders() async throws {
//            print("MetalView: reinitShaders()")
//            frameCounter = 0
//            try await setupShaders()
//        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            Task {
                await renderSync.run {
                    print("MetalView: mtkView(\(size))")
                    self.updateViewportSize(size)
                    self.frameCounter = 0
                }
            }
        }

        // Enable offscreen rendering
        func startRendering() {
            print("MetalView: startRendering()")
            renderingActive = true
            renderOffscreen()
        }

        // Disable offscreen rendering
        func stopRendering() {
            print("MetalView: stopRendering()")
            renderingActive = false
        }

        func updateVSyncState(_ enabled: Bool) {
            // Update your rendering logic here based on the VSync state
            if enabled {
                stopRendering()
            } else {
                startRendering()
            }
        }

        func updateUniforms() {
            var offset = MemoryLayout<ViewportSize>.size // for viewport
            let bufferPointer = sysUniformBuffer!.contents()

            // Ensure the offset is aligned
            var memAlign = MemoryLayout<UInt32>.alignment
            var memSize = MemoryLayout<UInt32>.size
            offset = (offset + memAlign - 1) / memAlign * memAlign
            // Copy the data
            memcpy(bufferPointer.advanced(by: offset), &frameCounter, memSize)
            // Update the offset
            offset += memSize

            var elapsedTime = Float(-renderMgr.startDate.timeIntervalSinceNow)
            memAlign = MemoryLayout<Float>.alignment
            memSize = MemoryLayout<Float>.size
            offset = (offset + memAlign - 1) / memAlign * memAlign
            memcpy(bufferPointer.advanced(by: offset), &elapsedTime, memSize)
            offset += memSize


//            var pNum = numBuffers
            var pNum = 0 // remove this d
            memAlign = MemoryLayout<UInt32>.alignment
            memSize = MemoryLayout<UInt32>.size
            offset = (offset + memAlign - 1) / memAlign * memAlign
            memcpy(bufferPointer.advanced(by: offset), &pNum, memSize)
            offset += memSize
        }


        func setupRenderEncoder( _ encoder: MTLRenderCommandEncoder, renderResources: RenderResources ) {
            let currentBuffers = renderResources.renderBuffers
            let numBuffers = renderResources.numBuffers
            let mtlTextures = renderResources.mtlTextures
            
            if currentBuffers.count < MAX_RENDER_BUFFERS {
                print("currentBuffers.count < MAX_RENDER_BUFFERS")
                return
            }

            var textureIndex = 0
            for i in 0..<MAX_RENDER_BUFFERS {
                if( i > currentBuffers.count - 1 ) {
                    print("i: \(i) - renderBuffers.count:\(currentBuffers.count)")
                }
                encoder.setFragmentTexture(currentBuffers[i], index: textureIndex)
                textureIndex += 1
            }

            // pass a dynamic reference to the last buffer rendered, if there is one
            if numBuffers > 0 {
                encoder.setFragmentTexture(currentBuffers[numBuffers-1], index: textureIndex)
                textureIndex += 1
            }
            
            // now the first MAX_RENDER_BUFFERS+1 buffers are passed
            // it's up to the shaders how to use them

//            print("MetalView: setupRenderEncoder() - setting encoder with \(mtlTextures.count) user textures")
            for texture in mtlTextures {
//                print("#### Adding texture \(index)")
                encoder.setFragmentTexture(texture, index: textureIndex)
                textureIndex += 1
            }
//            encoder.setFragmentSamplerState(samplerState, index: 0)

            updateUniforms()
            encoder.setFragmentBuffer(sysUniformBuffer, offset: 0, index: 0)
            let uniformBuffer = renderResources.uniformBuffer
            encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        private func renderOffscreen() {
            let renderResources = resourceMgr.getCurrentResources()
            let currentBuffers = renderResources.renderBuffers
            let numBuffers = renderResources.numBuffers
            let pipelineStates = renderResources.pipelineStates

            if !self.renderingActive && !renderMgr.vsyncOn { return }
            if currentBuffers.count < MAX_RENDER_BUFFERS {
                if( !renderMgr.vsyncOn ) {
                    print("currentBuffers.count < MAX_RENDER_BUFFERS - Retrying in 10ms")
                    DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 0.01) {
                        self.renderOffscreen()
                    }
                }
                return
            }

            let renderMgr = self.renderMgr
            if numBuffers <= 0 {
                if( !renderMgr.vsyncOn ) {
                    print("$$$ numBufers <= 0 - Retrying in 10ms.")
                    DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 0.01) {
                        self.renderOffscreen()
                    }
                }
                return
            }

            guard let commandBuffer = self.metalCommandQueue.makeCommandBuffer() else { return }

            var i=0

            // iterate through the shaders, giving them each access to all of the buffers
            // (see the pipeline setup)
            while i < (numBuffers) {
                let renderPassDescriptor = MTLRenderPassDescriptor()
                renderPassDescriptor.colorAttachments[0].texture = currentBuffers[i]
                renderPassDescriptor.colorAttachments[0].loadAction = .load
                renderPassDescriptor.colorAttachments[0].storeAction = .store

                guard let commandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }

                commandEncoder.setRenderPipelineState(pipelineStates[i])
                self.setupRenderEncoder(commandEncoder, renderResources: renderResources)
                commandEncoder.endEncoding()

                i += 1
            }

            // This is the most optimal way I found to do offline rendering
            // as quickly as possible.  The drawback is that slower renderings
            // like circle_and_lines don't display smoothly even though
            // framerates are faster than 60Hz.
            if( !renderMgr.vsyncOn ) {
                commandBuffer.addScheduledHandler { commandBuffer in
                    self.renderOffscreen()
                }
            }
            commandBuffer.commit()
            self.frameCounter += 1
        }

        func draw(in view: MTKView) {
            let renderMgr = self.renderMgr
            let renderResources = resourceMgr.getCurrentResources()
            let numBuffers = renderResources.numBuffers
            let pipelineStates = renderResources.pipelineStates

            guard !self.renderMgr.renderingPaused else { return }
            guard numBuffers >= 0 else { return }
            guard pipelineStates.count - 1 == numBuffers else { return }

            if( renderMgr.vsyncOn && numBuffers > 0 ) { self.renderOffscreen() } else { self.frameCounter += 1 }
            guard let drawable = view.currentDrawable,
                  let commandBuffer = self.metalCommandQueue.makeCommandBuffer() else { return }

            let renderPassDescriptor = view.currentRenderPassDescriptor!

            // renderPassDescriptor.colorAttachments[0].texture = renderBuffers[numBuffers-1]
            renderPassDescriptor.colorAttachments[0].loadAction = .load
            renderPassDescriptor.colorAttachments[0].storeAction = .store

            guard let commandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }

            commandEncoder.setRenderPipelineState(pipelineStates[numBuffers])

            self.setupRenderEncoder(commandEncoder,renderResources: renderResources)
            commandEncoder.endEncoding()

            commandBuffer.present(drawable)
            commandBuffer.commit()

            // renderMgr.frameCount is observed by ContentView forcing redraw at the next display sync
            self.renderMgr.frameCount = self.frameCounter
        }

    }
}
