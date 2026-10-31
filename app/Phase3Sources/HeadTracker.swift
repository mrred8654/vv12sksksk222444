// SPDX-License-Identifier: AGPL-3.0-or-later
// AquaVR phase 3: CoreMotion 3DoF head tracking — replaces alvr-visionos
// WorldTracker.swift (ARKit/visionOS, AGPL-3.0). Rotation-only, sitting play:
//   pose.position = 0; velocities = 0 (v20 protocol zeroes head velocities anyway).
// TODO: verify axis conventions on-device; may need a fixed-axis remap quaternion.

import CoreMotion
import Foundation
import simd

final class HeadTracker {
    static let shared = HeadTracker()

    private let motionManager = CMMotionManager()
    private var startedTracking = false
    private var latestAttitude: (Float, Float, Float, Float)? = nil

    private init() {}

    func startTracking() {
        guard !startedTracking else { return }
        guard motionManager.isDeviceMotionAvailable else {
            print("HeadTracker: device motion unavailable")
            return
        }
        startedTracking = true
        motionManager.deviceMotionUpdateInterval = 1.0 / Double(AlvrSession.shared.refreshRate)
        motionManager.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: .main) { motion, _ in
            guard let motion = motion else { return }
            // CMAttitude quaternion: (x, y, z, w)
            self.latestAttitude = (motion.attitude.quaternion.x,
                                   motion.attitude.quaternion.y,
                                   motion.attitude.quaternion.z,
                                   motion.attitude.quaternion.w)
        }
    }

    func stopTracking() {
        guard startedTracking else { return }
        startedTracking = false
        motionManager.stopDeviceMotionUpdates()
    }

    // Send the current head motion to client_core. Called once per rendered frame.
    func sendTracking(targetTimestamp: Double) {
        startTracking()

        let quat = simd_quatf(ix: latestAttitude?.0 ?? 0, iy: latestAttitude?.1 ?? 0, iz: latestAttitude?.2 ?? 0, r: latestAttitude?.3 ?? 1)

        let zeroVec: (Float, Float, Float) = (0.0, 0.0, 0.0)
        var motion = AlvrDeviceMotion()
        motion.device_id = AlvrSession.shared.headId
        motion.pose.orientation = AlvrQuat(x: quat.imag.x, y: quat.imag.y, z: quat.imag.z, w: quat.real)
        motion.pose.position = zeroVec
        motion.linear_velocity = zeroVec
        motion.angular_velocity = zeroVec

        let timestampNs = UInt64(targetTimestamp * Double(NSEC_PER_SEC))
        withUnsafePointer(to: motion) { motPtr in
            alvr_send_tracking(timestampNs, motPtr, 1, nil, nil)
        }
    }
}
