// SPDX-License-Identifier: MIT
// AquaVR phase 3: ALVR client session glue -- ported from alvr-visionos
// ALVRClient/EventHandler.swift (AGPL-3.0), visionOS pieces replaced for iOS:
//   - no mDNS discovery (USB tunnel only, UDP broadcast disabled in client_core patch)
//   - no exit(0) on backgrounding (the app must survive a locked screen)
//   - WorldTracker ARKit calls replaced with HeadTracker (CoreMotion 3DoF)

import Combine
import CoreVideo
import Foundation
import Metal
import VideoToolbox

enum AlvrConnectionState {
    case connected, disconnected, connecting
}

struct QueuedFrame {
    let imageBuffer: CVImageBuffer
    let timestamp: UInt64
    let viewParamsValid: Bool
    let viewParams: [AlvrViewParams]
}

final class AlvrSession: ObservableObject {
    static let shared = AlvrSession()

    var alvrInitialized = false
    var streamingActive = false
    var inputRunning = false

    @Published var connectionState: AlvrConnectionState = .disconnected
    @Published var statusText: String = "off"
    @Published var lastHudMessage: String = ""

    let refreshRate: Float = 90.0
    let renderWidth: UInt32 = 1600
    let renderHeight: UInt32 = 1000

    var headId: UInt64 = 0

    var vtDecompressionSession: VTDecompressionSession? = nil
    var videoFormat: CMFormatDescription? = nil
    var currentCodec: Int = -1

    var frameQueueLock = NSObject()
    var frameQueue = [QueuedFrame]()
    var frameQueueLastTimestamp: UInt64 = 0
    var framesSinceLastIDR: Int = 0
    var framesSinceLastDecode: Int = 0
    var lastRequestedTimestamp: UInt64 = 0
    var lastSubmittedTimestamp: UInt64 = 0
    var needsEncoderReset = true

    var viewFovs: [AlvrFov] = [
        AlvrFov(left: -1.0471973, right: 0.7853982, up: 0.7853982, down: -0.8726632),
        AlvrFov(left: -0.7853982, right: 1.0471973, up: 0.7853982, down: -0.8726632)
    ]

    private var eventsThread: Thread? = nil

    private init() {}

    func initializeAlvr() {
        if !alvrInitialized {
            print("Initialize ALVR")
            alvrInitialized = true
            headId = alvr_path_string_to_id("/user/head")
            let refreshRates: [Float] = [AlvrSession.shared.refreshRate]
            let capabilities = AlvrClientCapabilities(
                default_view_width: renderWidth,
                default_view_height: renderHeight,
                refresh_rates: refreshRates,
                refresh_rates_count: UInt64(refreshRates.count),
                foveated_encoding: false,
                encoder_high_profile: true,
                encoder_10_bits: false,
                encoder_av1: false,
                prefer_10bit: false,
                prefer_full_range: true,
                preferred_encoding_gamma: 1.0,
                prefer_hdr: false)
            alvr_initialize(/*capabilities=*/capabilities)
            alvr_initialize_logging()
            alvr_set_decoder_input_callback(nil, { data in
                return AlvrSession.shared.handleNals(frameData: data)
            })
            alvr_resume()
        }
    }

    // Starts the event thread.
    func start() {
        initializeAlvr()
        alvr_resume()

        if !inputRunning {
            print("Starting event thread")
            inputRunning = true
            eventsThread = Thread {
                self.handleAlvrEvents()
            }
            eventsThread?.qualityOfService = .userInteractive
            eventsThread?.name = "AlvrSession Events"
            eventsThread?.start()
        }
    }

    // Stops the event thread stream.
    func stop() {
        print("AlvrSession.stop")
        streamingActive = false
        vtDecompressionSession = nil
        videoFormat = nil
        lastRequestedTimestamp = 0
        lastSubmittedTimestamp = 0
        framesSinceLastIDR = 0
        framesSinceLastDecode = 0
        lastQueuedFrame = nil
        frameQueue.removeAll()

        updateConnectionState(.disconnected)
    }

    var lastQueuedFrame: QueuedFrame? = nil

    // Landing for frames fed by the decoder input callback.
    func handleNals(frameData: AlvrVideoFrameData) -> Bool {
        timeLastFrameGot = CACurrentMediaTime()

        // Prevent NAL buildup while not rendering
        if !renderStarted {
            return true
        }

        if needsEncoderReset {
            needsEncoderReset = false
            print("Resetting encoder")
            return false
        }

        let timestamp = frameData.timestamp_ns
        let nal = UnsafeMutableBufferPointer<UInt8>(
            start: UnsafeMutablePointer(mutating: frameData.buffer_ptr),
            count: Int(frameData.buffer_size))

        objc_sync_enter(frameQueueLock)
        framesSinceLastIDR += 1

        // Stop decoding NALs timestamped >400 ms in the past to avoid decode lag cascades
        let nsDiffFromLastReqTs = lastRequestedTimestamp > timestamp ? lastRequestedTimestamp &- timestamp : 0
        let lagSpiked = nsDiffFromLastReqTs > 1000 * 1000 * 600 && framesSinceLastIDR > Int(refreshRate * 2)

        if lastRequestedTimestamp != 0 && (lagSpiked || framesSinceLastDecode > Int(refreshRate * 2)) {
            objc_sync_exit(frameQueueLock)

            print("Handle spike! asking IDR")
            framesSinceLastIDR = 0
            framesSinceLastDecode = 0

            return false
        }
        objc_sync_exit(frameQueueLock)

        framesSinceLastDecode = 0

        if let session = vtDecompressionSession {
            VideoHandler.feedVideoIntoDecoder(
                decompressionSession: session,
                nals: nal,
                timestamp: timestamp,
                videoFormat: videoFormat!,
                codec: currentCodec) { [weak self] imageBuffer in
                guard let self = self, let imageBuffer = imageBuffer else {
                    return
                }

                self.timeLastFrameDecoded = CACurrentMediaTime()

                objc_sync_enter(self.frameQueueLock)
                alvr_report_frame_decoded(timestamp)

                let dummyPose = AlvrPose()
                let viewParamsDummy = [
                    AlvrViewParams(pose: dummyPose, fov: self.viewFovs[0]),
                    AlvrViewParams(pose: dummyPose, fov: self.viewFovs[1])
                ]
                self.frameQueue.append(QueuedFrame(
                    imageBuffer: imageBuffer,
                    timestamp: timestamp,
                    viewParamsValid: false,
                    viewParams: viewParamsDummy))
                if self.frameQueue.count > 2 {
                    self.frameQueue.removeFirst()
                }
                self.frameQueueLastTimestamp = timestamp

                objc_sync_exit(self.frameQueueLock)
            }
        } else {
            var nalViewsPtrDiscarded = [AlvrViewParams](repeating: AlvrViewParams(), count: 2)
            alvr_report_frame_decoded(timestamp)
            nalViewsPtrDiscarded.withUnsafeMutableBufferPointer { buf in
                alvr_report_compositor_start(timestamp, buf.baseAddress!)
            }
            alvr_report_submit(timestamp, 0)

            print("Force reset decoder")
            return false
        }

        return true
    }

    // Timers mirroring the donor watchdogs. Keep names short.
    var renderStarted = false
    var timeLastFrameGot: Double = 0.0
    var timeLastFrameDecoded: Double = 0.0

    func handleRenderStarted() {
        renderStarted = true
        timeLastFrameGot = CACurrentMediaTime()
        timeLastFrameDecoded = CACurrentMediaTime()
    }

    func requestIDR() {
        needsEncoderReset = true
    }

    // The main event thread
    func handleAlvrEvents() {
        print("Start event thread...")
        currentCodec = -1
        sendViewParams()
        while inputRunning {
            let currentTime = CACurrentMediaTime()

            if !renderStarted && streamingActive {
                HeadTracker.shared.sendTracking(targetTimestamp: currentTime)
            }

            // Request an IDR when frames dried up
            if alvrInitialized && (currentTime - timeLastFrameGot >= 5.0) {
                print("Request IDR")
                requestIDR()
                timeLastFrameGot = CACurrentMediaTime()
            }

            var alvrEvent = AlvrEvent()
            let res = alvr_poll_event(&alvrEvent)
            if !res {
                Thread.sleep(forTimeInterval: 0.001)
                continue
            }

            switch UInt32(alvrEvent.tag) {
            case ALVR_EVENT_HUD_MESSAGE_UPDATED.rawValue:
                if !renderStarted {
                    let hudMessageBuffer = UnsafeMutableBufferPointer<CChar>.allocate(capacity: 1024)
                    alvr_hud_message(hudMessageBuffer.baseAddress)
                    let message = String(cString: hudMessageBuffer.baseAddress!, encoding: .utf8) ?? ""
                    if message.starts(with: "The streamer is restarting") {
                        if streamingActive {
                            streamingActive = false
                            stop()
                            currentCodec = -1
                        }
                    }
                    DispatchQueue.main.async { self.lastHudMessage = message }
                    print(message)
                    hudMessageBuffer.deallocate()
                }
                updateHostVersion()
            case ALVR_EVENT_STREAMING_STARTED.rawValue:
                print("streaming started")
                if !streamingActive {
                    streamingActive = true
                    requestIDR()
                    framesSinceLastIDR = 0
                    framesSinceLastDecode = 0
                    currentCodec = -1
                    updateConnectionState(.connected)
                }
            case ALVR_EVENT_STREAMING_STOPPED.rawValue:
                print("streaming stopped")
                if streamingActive {
                    streamingActive = false
                    stop()
                    currentCodec = -1
                }
            case ALVR_EVENT_HAPTICS.rawValue:
                // Phone has no controllers: drop haptics events.
                break
            case ALVR_EVENT_DECODER_CONFIG.rawValue:
                streamingActive = true
                currentCodec = Int(alvrEvent.DECODER_CONFIG.codec)
                print("create decoder for codec ID: \(currentCodec)")

                if vtDecompressionSession == nil {
                    let numBytes = alvr_get_decoder_config(nil)
                    let nalBuffer: UnsafeMutableBufferPointer<UInt8>
                    if numBytes > 0 {
                        nalBuffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: Int(numBytes))
                    } else {
                        nalBuffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 1)
                    }
                    defer { nalBuffer.deallocate() }
                    alvr_get_decoder_config(nalBuffer.baseAddress)

                    (vtDecompressionSession, videoFormat) = VideoHandler.createVideoDecoder(
                        initialNals: nalBuffer, codec: currentCodec)
                }

                updateConnectionState(.connected)
            case ALVR_EVENT_REAL_TIME_CONFIG.rawValue:
                print("real-time config ignored")
            default:
                print("unknown msg")
            }
            Thread.sleep(forTimeInterval: 0.0001)
        }

        print("Events thread stopped")
    }

    func updateConnectionState(_ newState: AlvrConnectionState) {
        DispatchQueue.main.async {
            self.connectionState = newState
            self.statusText =
                (newState == .connected) ? "stream"
                : (newState == .connecting) ? "connecting"
                : (self.streamingActive ? "stream" : "no connection")
        }
    }

    // MARK: - View params (fixed stereo geometry for the Cardboard)

    private var viewParamsSent = false
    private let viewIpdM: Float = 0.063

    func sendViewParams() {
        let ipdHalf = viewIpdM / 2
        // Donor defaults (EventHandler.viewFovs): a typical binocular canted view; refine later.
        let leftFov = AlvrFov(left: -1.0471973, right: 0.7853982, up: 0.7853982, down: -0.8726632)
        let rightFov = AlvrFov(left: -0.7853982, right: 1.0471973, up: 0.7853982, down: -0.8726632)
        let identity = AlvrQuat(x: 0, y: 0, z: 0, w: 1)
        let leftPose = AlvrPose(orientation: identity, position: (-ipdHalf, 0, 0))
        let rightPose = AlvrPose(orientation: identity, position: (ipdHalf, 0, 0))
        let params = [
            AlvrViewParams(pose: leftPose, fov: leftFov),
            AlvrViewParams(pose: rightPose, fov: rightFov)
        ]
        params.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                alvr_send_view_params(base)
            }
        }
        viewParamsSent = true
    }

    private var hostAlvrVersion: String = ""

    func updateHostVersion() {
        var byteArray = [UInt8](repeating: 0, count: 256)
        byteArray.withUnsafeMutableBytes { ptr in
            let cStringPtr = ptr.bindMemory(to: CChar.self).baseAddress
            alvr_get_server_version(cStringPtr)
        }
        if let utf8 = String(bytes: byteArray, encoding: .utf8) {
            hostAlvrVersion = utf8.trimmingCharacters(in: ["\0"])
            DispatchQueue.main.async {
                self.statusText = "ALVR \(self.hostAlvrVersion)"
            }
        }
    }

    // MARK: - Renderer-facing report path (one eye)

    func pollFrameForRender() -> QueuedFrame? {
        var frame: QueuedFrame? = nil
        objc_sync_enter(frameQueueLock)
        if let newest = frameQueue.last {
            frame = newest
        }
        objc_sync_exit(frameQueueLock)
        return frame
    }

    func reportCompositorStart(forFrame frame: QueuedFrame) -> [AlvrViewParams] {
        var views = [AlvrViewParams](repeating: AlvrViewParams(), count: 2)
        views.withUnsafeMutableBufferPointer { buf in
            if let base = buf.baseAddress {
                alvr_report_compositor_start(frame.timestamp, base)
                views = [base[0], base[1]]
            }
        }
        return views
    }

    func reportSubmit(timestamp: UInt64, vsyncQueueNs: UInt64) {
        alvr_report_submit(timestamp, vsyncQueueNs)
        lastSubmittedTimestamp = timestamp
    }
}
