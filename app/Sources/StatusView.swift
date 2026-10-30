import SwiftUI
import CoreMotion

struct StatusView: View {
    @State private var tracking = false
    @State private var pitch = "0.0"
    @State private var roll = "0.0"
    @State private var yaw = "0.0"

    private let motion = CMMotionManager()

    var body: some View {
        NavigationStack {
            List {
                Section("Сборка") {
                    Label("Приложение установлено", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Label("Фаза 1: скелет + CoreMotion тест", systemImage: "sparkles")
                }
                Section("Гиро (CoreMotion)") {
                    Button {
                        toggleTracking()
                    } label: {
                        Label(tracking ? "Остановить тест" : "Запустить тест гиро",
                              systemImage: tracking ? "stop.circle" : "play.circle")
                    }
                    if tracking {
                        Text("pitch: \(pitch)°")
                        Text("roll:  \(roll)°")
                        Text("yaw : \(yaw)°")
                    } else {
                        Text("Запусти тест и покрути телефон — цифры должны меняться плавно.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("О телефоне") {
                    Label("Модель: \(modelIdentifier())", systemImage: "iphone")
                    Label("Память: \(freeMemoryMB()) МБ свободно", systemImage: "memorychip")
                }
            }
            .navigationTitle("AquaVR")
        }
    }

    private func toggleTracking() {
        guard motion.isDeviceMotionAvailable else {
            pitch = "н/д"; roll = "н/д"; yaw = "н/д"
            return
        }
        if tracking {
            motion.stopDeviceMotionUpdates()
            tracking = false
        } else {
            motion.deviceMotionUpdateInterval = 1.0 / 60.0
            motion.startDeviceMotionUpdates(to: .main) { data, _ in
                guard let a = data?.attitude else { return }
                pitch = String(format: "%.1f", a.pitch * 180 / .pi)
                roll = String(format: "%.1f", a.roll * 180 / .pi)
                yaw = String(format: "%.1f", a.yaw * 180 / .pi)
            }
            tracking = true
        }
    }

    private func modelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return String(cString: machine)
    }

    private func freeMemoryMB() -> String {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return "?" }
        let freeBytes = UInt64(stats.free_count) * UInt64(vm_kernel_page_size)
        return String(freeBytes / 1_048_576)
    }
}
