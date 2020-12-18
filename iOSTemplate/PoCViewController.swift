// Copyright Anton Kondrashov 2020
// Code can't be used until payment

import UIKit
import AVFoundation
import os.log

final class PoCViewController: UIViewController {
    private let sessionQueue = DispatchQueue(label: "session queue", attributes: [], autoreleaseFrequency: .workItem)
    private let session = AVCaptureSession()
    private var setupResult: SessionSetupResult = .success

    private let dataOutputQueue = DispatchQueue(label: "video data queue", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem)

    private var videoDeviceInput: AVCaptureDeviceInput!
    private let videoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInTrueDepthCamera],
        mediaType: .video,
        position: .front
    )

    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let depthDataOutput = AVCaptureDepthDataOutput()
    private var outputSynchronizer: AVCaptureDataOutputSynchronizer?

    @IBOutlet weak var videoView: UIView!
    @IBOutlet weak var previewImageView: UIImageView!

    @IBOutlet weak var averageLabel: UILabel!
    @IBOutlet weak var minLabel: UILabel!
    @IBOutlet weak var maxLabel: UILabel!

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        sessionQueue.async {
            switch self.setupResult {
            case .success:
                self.session.startRunning()
            case .notAuthorized:
                DispatchQueue.main.async {
                    let message = NSLocalizedString(
                        "TrueDepthStreamer doesn't have permission to use the camera, please change privacy settings",
                        comment: "Alert message when the user has denied access to the camera"
                    )
                    let alertController = UIAlertController(title: "TrueDepthStreamer", message: message, preferredStyle: .alert)
                    alertController.addAction(
                        UIAlertAction(
                            title: NSLocalizedString("OK", comment: "Alert OK button"),
                            style: .cancel,
                            handler: nil
                        )
                    )
                    alertController.addAction(
                        UIAlertAction(
                            title: NSLocalizedString("Settings", comment: "Alert button to open Settings"),
                            style: .`default`,
                            handler: { _ in
                                UIApplication.shared.open(
                                    URL(
                                        string: UIApplication.openSettingsURLString)!,
                                    options: [:],
                                    completionHandler: nil
                                )
                            }
                        )
                    )
                    self.present(alertController, animated: true, completion: nil)
                }

            case .configurationFailed:
                os_log(.error, "Configuration failed")
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            // The user has previously granted access to the camera
            break

        case .notDetermined:
            /*
             The user has not yet been presented with the option to grant video access
             We suspend the session queue to delay session setup until the access request has completed
             */
            sessionQueue.suspend()
            AVCaptureDevice.requestAccess(for: .video, completionHandler: { granted in
                if !granted {
                    self.setupResult = .notAuthorized
                }
                self.sessionQueue.resume()
            })

        default:
            // The user has previously denied access
            setupResult = .notAuthorized
        }

        sessionQueue.async {
            self.configureSession()
            self.session.startRunning()
        }

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = AVLayerVideoGravity.resizeAspect
        previewLayer.connection?.videoOrientation = .portrait
        videoView.layer.addSublayer(previewLayer)
        previewLayer.frame = view.frame
    }

    private func configureSession() {
        if setupResult != .success {
            return
        }

        let defaultVideoDevice = videoDeviceDiscoverySession.devices.first

        guard let videoDevice = defaultVideoDevice else {
            print("Could not find any video device")
            setupResult = .configurationFailed
            return
        }

        do {
            videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
        } catch {
            print("Could not create video device input: \(error)")
            setupResult = .configurationFailed
            return
        }

        session.beginConfiguration()

        session.sessionPreset = AVCaptureSession.Preset.vga640x480

        // Add a video input
        guard session.canAddInput(videoDeviceInput) else {
            print("Could not add video device input to the session")
            setupResult = .configurationFailed
            session.commitConfiguration()
            return
        }
        session.addInput(videoDeviceInput)

        // Add a video data output
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
            videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        } else {
            print("Could not add video data output to the session")
            setupResult = .configurationFailed
            session.commitConfiguration()
            return
        }

        // Add a depth data output
        if session.canAddOutput(depthDataOutput) {
            session.addOutput(depthDataOutput)
            depthDataOutput.isFilteringEnabled = true
            if let connection = depthDataOutput.connection(with: .depthData) {
                connection.isEnabled = true
            } else {
                print("No AVCaptureConnection")
            }
        } else {
            print("Could not add depth data output to the session")
            setupResult = .configurationFailed
            session.commitConfiguration()
            return
        }

        // Search for highest resolution with half-point depth values
        let depthFormats = videoDevice.activeFormat.supportedDepthDataFormats
        let filtered = depthFormats.filter({
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat16
        })
        let selectedFormat = filtered.max(by: {
            first, second in CMVideoFormatDescriptionGetDimensions(first.formatDescription).width < CMVideoFormatDescriptionGetDimensions(second.formatDescription).width
        })

        do {
            try videoDevice.lockForConfiguration()
            videoDevice.activeDepthDataFormat = selectedFormat
            videoDevice.unlockForConfiguration()
        } catch {
            print("Could not lock device for configuration: \(error)")
            setupResult = .configurationFailed
            session.commitConfiguration()
            return
        }

        // Use an AVCaptureDataOutputSynchronizer to synchronize the video data and depth data outputs.
        // The first output in the dataOutputs array, in this case the AVCaptureVideoDataOutput, is the "master" output.
        outputSynchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoDataOutput, depthDataOutput])
        outputSynchronizer!.setDelegate(self, queue: dataOutputQueue)
        session.commitConfiguration()
    }

    private func setupCamera() {
        let captureSession = AVCaptureSession()
        captureSession.sessionPreset = .vga640x480

        guard
            let captureDevice = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .back)
        else {
            return
        }

        let availableFormats = captureDevice.activeFormat.supportedDepthDataFormats

        let depthFormat = availableFormats.filter { format in
            let pixelFormatType = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            return pixelFormatType == kCVPixelFormatType_DepthFloat16 || pixelFormatType == kCVPixelFormatType_DepthFloat32
        }.max(by: {
            CMVideoFormatDescriptionGetDimensions($0.formatDescription).width < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
        })

        // Set the capture device to use that depth format.
        captureSession.beginConfiguration()
        captureDevice.activeDepthDataFormat = depthFormat
        captureSession.commitConfiguration()

        guard
            let input = try? AVCaptureDeviceInput(device: captureDevice)
        else {
            return
        }
        captureSession.addInput(input)

        captureSession.startRunning()

        let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = AVLayerVideoGravity.resizeAspect
        previewLayer.connection?.videoOrientation = .portrait
        view.layer.addSublayer(previewLayer)
        previewLayer.frame = view.frame

        let dataOutput = AVCaptureVideoDataOutput()
        captureSession.addOutput(dataOutput)
    }

    private enum SessionSetupResult {
        case success
        case notAuthorized
        case configurationFailed
    }
}

extension PoCViewController: AVCaptureDataOutputSynchronizerDelegate {
    func dataOutputSynchronizer(
        _ synchronizer: AVCaptureDataOutputSynchronizer,
        didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection
    ) {
        guard
            let syncedDepthData = synchronizedDataCollection.synchronizedData(for: depthDataOutput) as? AVCaptureSynchronizedDepthData,
            let syncedVideoData = synchronizedDataCollection.synchronizedData(for: videoDataOutput) as? AVCaptureSynchronizedSampleBufferData
        else {
            return
        }

        if syncedDepthData.depthDataWasDropped || syncedVideoData.sampleBufferWasDropped {
            return
        }

        let depthData = syncedDepthData.depthData
        let depthPixelBuffer = depthData.depthDataMap

        guard depthData.depthDataAccuracy == .absolute else {
            print("not absolute")
            return
        }

        CVPixelBufferLockBaseAddress(depthPixelBuffer, .readOnly)
        let buf = unsafeBitCast(CVPixelBufferGetBaseAddress(depthPixelBuffer), to: UnsafeMutablePointer<Float16>.self)

        let width = CVPixelBufferGetWidth(depthPixelBuffer)
        let height = CVPixelBufferGetHeight(depthPixelBuffer)

        let xWindow = 40
        let yWindow = 20
        let x = width / 2 - xWindow / 2
        let y = height / 2 - yWindow / 2

        var sum: Float16 = 0
        var min = Float16.greatestFiniteMagnitude
        var max = Float16.leastNormalMagnitude

        for w in x..<(x + xWindow) {
            for h in y..<(y + yWindow) {
                let index = h * w
                let m = buf[index]

                sum += m

                if (0.15...0.5).contains(m)  {
                    min = min > m ? m : min
                    max = max < m ? m : max
                }
            }
        }


        let avOut = ((sum / Float16(xWindow) / Float16(yWindow)) * 10000.0) / 10.0
        let minOut = (min * 10000.0) / 10.0
        let maxOut = (max * 10000.0) / 10.0

        CVPixelBufferUnlockBaseAddress(depthPixelBuffer, .readOnly)

        let ciImage = CIImage(
            cvPixelBuffer: depthPixelBuffer,
            options: [
                .applyOrientationProperty: true,
                .properties: [
                    kCGImagePropertyOrientation: CGImagePropertyOrientation.leftMirrored.rawValue
                ]
            ]
        )

        guard
            avOut != .infinity,
            minOut != .infinity,
            maxOut != .infinity
        else {
            return
        }

        DispatchQueue.main.async {
            self.averageLabel.text = "avg: \(avOut)mm"
            self.minLabel.text = "min: \(Int(minOut)) mm"
            self.maxLabel.text = "max: \(Int(maxOut)) mm"

            let depthMapImage = UIImage(ciImage: ciImage, scale: 2, orientation: .up)
            self.previewImageView.image = depthMapImage
        }
    }
}

