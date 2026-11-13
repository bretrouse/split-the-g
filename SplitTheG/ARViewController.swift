import UIKit
import ARKit
import RealityKit
import Vision

class ARViewController: UIViewController, ARSessionDelegate {
    
    var arView: ARView!
    var appState: AppState?
    
    // Vision Request
    private var visionRequests = [VNRequest]()
    private let dispatchQueueML = DispatchQueue(label: "com.ar.dispatchQueueML")
    
    // Tracking state
    private var isGlassDetected = false
    private var glassAnchor: AnchorEntity?
        
    // Debugging Layer
    private var boundingBoxLayer = CAShapeLayer()
    // Smoothing State
    private var smoothedRect: CGRect?
    // 0.0 = snap instantly (no smoothing), 0.9 = very sluggish, 0.5 = good balance
    private let smoothingFactor: CGFloat = 0.5
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // 1. Setup ARView
        arView = ARView(frame: view.bounds)
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(arView)
        
        // 2. Configure AR Session
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        arView.session.delegate = self
        arView.session.run(config)
        
        // 3. Setup Vision
        setupVision()
        
        // 4. Setup Debug Bounding Box
        boundingBoxLayer.strokeColor = UIColor.red.cgColor
        boundingBoxLayer.lineWidth = 4.0
        boundingBoxLayer.fillColor = UIColor.clear.cgColor
        view.layer.addSublayer(boundingBoxLayer)
        
        // 5. Listen for the SwiftUI Reset button
        appState?.onReset = { [weak self] in
            self?.resetTracking()
        }
        
    }
    
    private func setupVision() {
        guard let modelURL = Bundle.main.url(forResource: "StoutBeerDetector", withExtension: "mlmodelc"),
              let beerModel = try? StoutBeerDetector(contentsOf: modelURL),
              let visionModel = try? VNCoreMLModel(for: beerModel.model) else {
            print("Error: Could not load the Core ML model.")
            return
        }
        
        // 1. Create the request WITHOUT the completion handler
        let request = VNCoreMLRequest(model: visionModel)
        
        // 2. Explicitly define the enum to prevent compiler confusion
        request.imageCropAndScaleOption = VNImageCropAndScaleOption.centerCrop
        
        // 3. Store the request
        visionRequests = [request]
    }
    
    // MARK: - ARSessionDelegate
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard !isGlassDetected else { return }
        
        // Grab the view size and display transform for bounding box math
        let viewportSize = arView.bounds.size
        let displayTransform = frame.displayTransform(for: .portrait, viewportSize: viewportSize)
        
        // Capture the pixel buffer locally so it safely passes to the background thread
        let pixelBuffer = frame.capturedImage
        
        dispatchQueueML.async {
            // Tell Vision the portrait camera feed is technically rotated right
            let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
            do {
                // This will block the background thread until the ML model finishes scanning
                try imageRequestHandler.perform(self.visionRequests)
                
                // Read the results directly from our stored request
                if let results = self.visionRequests.first?.results as? [VNRecognizedObjectObservation] {
                    self.processVisionResults(results, transform: displayTransform, size: viewportSize)
                }
            } catch {
                print("Vision error: \(error)")
            }
        }
    }
    
    // MARK: - Vision Processing
    
    private func processVisionResults(_ results: [VNRecognizedObjectObservation], transform: CGAffineTransform, size: CGSize) {
            
            // 1. ADD CONFIDENCE THRESHOLD (Only accept guesses that are > 60% confident)
            if let glassObservation = results.first(where: { observation in
                guard let topLabel = observation.labels.first else { return false }
                let isGlass = topLabel.identifier == "beer glass"
                return isGlass && topLabel.confidence > 0.95
            }) {
                
                DispatchQueue.main.async {
                    // Show the confidence percentage on screen for debugging!
                    let confidenceInt = Int(glassObservation.labels.first!.confidence * 100)
                    self.appState?.statusText = "Glass Detected (\(confidenceInt)%)"
                    
                    // 2. FIX COORDINATE MATH
                    let visionRect = glassObservation.boundingBox
                    
                    // Transform the normalized center to fix the camera rotation
                    let normalizedCenter = CGPoint(x: visionRect.midX, y: visionRect.midY)
                    let transformedCenter = normalizedCenter.applying(transform)
                    
                    // MULTIPLY by screen size to convert from 0.0-1.0 decimals to actual screen pixels
                    let screenCenterX = transformedCenter.x * size.width
                    let screenCenterY = transformedCenter.y * size.height
                    
                    // Calculate width and height in pixels
                    let boxWidth = visionRect.width * size.width
                    let boxHeight = visionRect.height * size.height
                    
                    // Construct the raw, jumpy rectangle from Vision
                    let rawScreenRect = CGRect(
                        x: screenCenterX - (boxWidth / 2),
                        y: screenCenterY - (boxHeight / 2),
                        width: boxWidth,
                        height: boxHeight
                    )
                    
                    // --- APPLY LOW-PASS FILTER (SMOOTHING) ---
                    if let previousRect = self.smoothedRect {
                        // Blend the old and new coordinates based on the smoothing factor
                        let smoothedX = (rawScreenRect.minX * (1 - self.smoothingFactor)) + (previousRect.minX * self.smoothingFactor)
                        let smoothedY = (rawScreenRect.minY * (1 - self.smoothingFactor)) + (previousRect.minY * self.smoothingFactor)
                        let smoothedW = (rawScreenRect.width * (1 - self.smoothingFactor)) + (previousRect.width * self.smoothingFactor)
                        let smoothedH = (rawScreenRect.height * (1 - self.smoothingFactor)) + (previousRect.height * self.smoothingFactor)
                        
                        self.smoothedRect = CGRect(x: smoothedX, y: smoothedY, width: smoothedW, height: smoothedH)
                    } else {
                        // If this is the very first frame, just snap to it
                        self.smoothedRect = rawScreenRect
                    }
                    
                    guard let finalRect = self.smoothedRect else { return }
                    // -----------------------------------------
                    
                    // Draw the SMOOTHED box
                    let path = UIBezierPath(rect: finalRect)
                    self.boundingBoxLayer.path = path.cgPath
                    
                    // Proceed with 3D placement using the SMOOTHED box
                    self.placeGOverlay(for: finalRect)
                }
            } else {
                // Clear the bounding box and reset text if no glass is found
                DispatchQueue.main.async {
                    self.boundingBoxLayer.path = nil
                    self.appState?.statusText = "Scanning..."
                }
            }
        }

    // MARK: - 3D Math & Placement Logic
    
    private func placeGOverlay(for screenRect: CGRect) {
        guard !isGlassDetected else { return }
        isGlassDetected = true
        
        // 1. Raycast the base
        let bottomCenter = CGPoint(x: screenRect.midX, y: screenRect.maxY + 10)
        guard let baseRaycast = arView.raycast(from: bottomCenter, allowing: .estimatedPlane, alignment: .horizontal).first else {
            isGlassDetected = false
            return
        }
        
        let basePosition = SIMD3<Float>(baseRaycast.worldTransform.columns.3.x, baseRaycast.worldTransform.columns.3.y, baseRaycast.worldTransform.columns.3.z)
        
        // 2. Unproject Top Center for Height
        let topCenter = CGPoint(x: screenRect.midX, y: screenRect.minY)
        guard let topRay = arView.ray(through: topCenter) else { return }
        let distanceToBase = distance(arView.cameraTransform.translation, basePosition)
        let topPosition3D = topRay.origin + (topRay.direction * distanceToBase)
        let heightH = topPosition3D.y - basePosition.y
        
        // 3. Unproject Left Edge for Width
        let leftCenter = CGPoint(x: screenRect.minX, y: screenRect.midY)
        guard let leftRay = arView.ray(through: leftCenter) else { return }
        let leftPosition3D = leftRay.origin + (leftRay.direction * distanceToBase)
        
        // The width is double the distance from the center to the left edge
        let physicalWidth = abs(basePosition.x - leftPosition3D.x) * 2
        
        // 4. Calculate 3/4 Height
        let targetY = basePosition.y + (0.75 * heightH)
        
        // 5. Build the AR environment!
        createAndAnchor3DEnvironment(
            basePosition: basePosition,
            targetY: targetY,
            height: heightH,
            width: physicalWidth
        )
    }
    
    // MARK: - Reset Logic
        
    private func resetTracking() {
        // 1. Remove the 3D "G" from the AR world if it exists
        if let anchor = glassAnchor {
            arView.scene.removeAnchor(anchor)
            glassAnchor = nil
        }
        
        // 2. Erase the red bounding box
        boundingBoxLayer.path = nil
        
        // 3. Reset the smoothed rect (heh)
        smoothedRect = nil
        
        // 4. Reset the tracking flag so Vision resumes scanning
        isGlassDetected = false
        
        // 5. Update the UI
        appState?.statusText = "Scanning..."
    }
    
    private func createAndAnchor3DEnvironment(basePosition: SIMD3<Float>, targetY: Float, height: Float, width: Float) {
        // 1. Create the main anchor at the bottom center of the glass
        glassAnchor = AnchorEntity(world: basePosition)
        guard let glassAnchor = glassAnchor else { return }
        
        // --- CREATE THE 3D BOUNDING BOX ---
        // We use a slightly transparent red material so you can still see the beer
        let boxMesh = MeshResource.generateBox(width: width, height: height, depth: width)
        let boxMaterial = SimpleMaterial(color: UIColor.red.withAlphaComponent(0.3), isMetallic: false)
        let boundingBoxEntity = ModelEntity(mesh: boxMesh, materials: [boxMaterial])
        
        // RealityKit anchors boxes by their dead center.
        // We need to shift it up by half its height so it sits perfectly on the table.
        boundingBoxEntity.position = SIMD3<Float>(0, height / 2, 0)
        glassAnchor.addChild(boundingBoxEntity)
        // ----------------------------------
        
        // --- CREATE THE "G" OVERLAY ---
        let textMesh = MeshResource.generateText("G", extrusionDepth: 0.01, font: .systemFont(ofSize: CGFloat(width * 0.8), weight: .bold))
        let textMaterial = SimpleMaterial(color: .green, isMetallic: true)
        let gModel = ModelEntity(mesh: textMesh, materials: [textMaterial])
        
        // Center the text and shift it up to the 3/4 mark (relative to the base)
        let textBounds = gModel.visualBounds(relativeTo: nil)
        gModel.position = SIMD3<Float>(-textBounds.extents.x / 2, targetY - 0.75 * basePosition.y, 0)
        
        let billboardComponent = BillboardComponent()
        gModel.components.set(billboardComponent)
        
        glassAnchor.addChild(gModel)
        // ------------------------------
        
        // Finally, add the entire package to the AR world
        arView.scene.addAnchor(glassAnchor)
    }
}
