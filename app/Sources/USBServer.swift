import Foundation
import Network

// Фаза 2: USB-сервер AquaVR.
// Слушает ТОЛЬКО 127.0.0.1 (loopback) порты 9943 (управление) и 9944 (данные).
// ПК-сторона подключается через usbmuxd-туннель (iproxy / pymobiledevice3 forward).
//
// Протокол v0.1 (текстовые строки, \n-терминированные) на 9943:
//   HELLO          -> OK AquaUSB 0.1
//   STAT           -> STAT in=<байт> out=<байт> conn=<шт>
//   RX <байт>      -> готовим приём <байт> на 9944; по завершении -> DONE RX <байт> <мс>
//   TX <байт>      -> шлём <байт> в 9944; по завершении             -> DONE TX <байт> <мс>
//   STOP           -> прервать текущий тест
//
// Канал 9944 — сырой TCP-поток данных (без обрамления), используется для замера скорости.

final class USBServer: ObservableObject {
    static let shared = USBServer()

    // Публикуемое состояние (меняется только с main)
    @Published private(set) var running = false
    @Published private(set) var status = "не запущен"
    @Published private(set) var connections = 0
    @Published private(set) var dataInMB = 0
    @Published private(set) var dataOutMB = 0
    @Published private(set) var lastTestLine = "нет тестов"
    @Published private(set) var connDebug = ""

    // Внутреннее состояние (все обращения — с self.queue)
    private let queue = DispatchQueue(label: "com.mrred8654.aquavr.usb")
    private var listeners: [NWListener] = []
    private var controlConn: NWConnection?
    private var dataConn: NWConnection?

    private var dataIn: UInt64 = 0
    private var dataOut: UInt64 = 0
    private var connectionsCount = 0

    // Тест скорости
    private var rxLimit: UInt64 = 0      // >0: считаем до этого объёма, потом DONE RX
    private var txTotal: UInt64 = 0      // >0: шлём до этого объёма
    private var txSent: UInt64 = 0
    private var txChunk = Data()
    private var testStarted = Date()
    private var lastPush = Date()
    private var controlIn = ""

    private let txChunkSize = 64 * 1024

    func start() {
        queue.async { [weak self] in self?.startSync() }
    }

    func stop() {
        queue.async { [weak self] in self?.stopSync() }
    }

    // MARK: - Внутреннее (выполняется на self.queue)

    private func startSync() {
        stopSync()
        lastPush = .distantPast

        for (portNum, isControl) in [(UInt16(9943), true), (UInt16(9944), false)] {
            guard let port = NWEndpoint.Port(rawValue: portNum) else { continue }
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)

            guard let listener = try? NWListener(using: params) else {
                setStatus("ошибка: listener порт \(portNum) недоступен")
                continue
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    setStatus("слушаю 127.0.0.1:\(portNum)")
                    setRunning(true)
                    pushStats()
                case .waiting:
                    setStatus("waiting: порт \(portNum) не готов (сеть/разрешение)")
                case .setup:
                    setStatus("setup: порт \(portNum) настраивается")
                case .failed(let error):
                    setStatus("ошибка listener \(portNum): \(error)")
                case .cancelled:
                    break
                @unknown default:
                    setStatus("listener \(portNum): неизвестное состояние")
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                guard let self = self else { return }
                self.handle(conn, control: isControl)
            }
            listener.start(queue: queue)
            listeners.append(listener)
        }
        setStatus("стартую 9943/9944...")
    }

    private func stopSync() {
        for l in listeners { l.cancel() }
        listeners.removeAll()
        controlConn?.cancel()
        dataConn?.cancel()
        controlConn = nil
        dataConn = nil
        connectionsCount = 0
        rxLimit = 0
        txTotal = 0
        setRunning(false, statusText: "не запущен")
    }

    private func handle(_ conn: NWConnection, control: Bool) {
        let portTag = control ? 9943 : 9944
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.setConnDebug("conn \(portTag): ready")
                if control {
                    self.controlConn = conn
                    self.controlIn = ""
                    self.sendControlSync("OK AquaUSB 0.1 ready")
                } else {
                    self.dataConn = conn
                }
                self.connectionsCount += 1
                self.pushStats()
                self.recvLoop(conn, control: control)
            case .setup:
                self.setConnDebug("conn \(portTag): setup")
            case .waiting:
                self.setConnDebug("conn \(portTag): waiting")
            case .failed(let error):
                self.setConnDebug("conn \(portTag): failed: \(error)")
                if control && self.controlConn === conn { self.controlConn = nil }
                if !control && self.dataConn === conn { self.dataConn = nil }
                if self.connectionsCount > 0 { self.connectionsCount -= 1 }
                self.pushStats()
            case .cancelled:
                if control && self.controlConn === conn { self.controlConn = nil }
                if !control && self.dataConn === conn { self.dataConn = nil }
                if self.connectionsCount > 0 { self.connectionsCount -= 1 }
                self.pushStats()
            @unknown default:
                self.setConnDebug("conn \(portTag): unknown state")
            }
        }
        conn.start(queue: queue)
    }

    private func recvLoop(_ conn: NWConnection, control: Bool) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let d = data, !d.isEmpty {
                if control {
                    self.onControlBytes(d)
                } else {
                    self.dataIn += UInt64(d.count)
                    self.checkRxTest()
                }
            }
            if error != nil || isComplete {
                conn.cancel()
                return
            }
            self.recvLoop(conn, control: control)
        }
    }

    // MARK: - Протокол управления

    private func onControlBytes(_ data: Data) {
        controlIn += String(decoding: data, as: UTF8.self)
        while let nl = controlIn.firstIndex(of: "\n") {
            let line = String(controlIn[..<nl])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            controlIn.removeSubrange(...nl)
            if !line.isEmpty { onControlLine(line) }
        }
    }

    private func onControlLine(_ line: String) {
        let parts = line.split(separator: " ").map(String.init)
        switch parts.first {
        case "HELLO":
            sendControlSync("OK AquaUSB 0.1")
        case "STAT":
            sendControlSync("STAT in=\(dataIn) out=\(dataOut) conn=\(connectionsCount)")
        case "RX":
            guard let n = atLeastOneArg(parts) else {
                sendControlSync("ERR RX требует число байт")
                return
            }
            dataIn = 0
            rxLimit = n
            testStarted = Date()
            sendControlSync("READY RX \(n)")
        case "TX":
            guard let n = atLeastOneArg(parts) else {
                sendControlSync("ERR TX требует число байт")
                return
            }
            dataOut = 0
            txSent = 0
            txTotal = n
            txChunk = Data(count: txChunkSize)
            testStarted = Date()
            sendControlSync("READY TX \(n)")
            pumpTx()
        case "STOP":
            rxLimit = 0
            txTotal = 0
            sendControlSync("OK stopped")
        default:
            sendControlSync("ERR неизвестная команда: \(line)")
        }
    }

    private func atLeastOneArg(_ parts: [String]) -> UInt64? {
        guard parts.count >= 2, let n = UInt64(parts[1]), n > 0 else { return nil }
        return n
    }

    private func checkRxTest() {
        guard rxLimit > 0, dataIn >= rxLimit else { return }
        let n = rxLimit
        rxLimit = 0
        finishTest(kind: "RX", bytes: n)
    }

    private func pumpTx() {
        guard let conn = dataConn, txTotal > txSent else { return }
        let remaining = txTotal - txSent
        let chunkSize = Int(min(UInt64(txChunkSize), remaining))
        let chunk = txChunk.prefix(chunkSize)
        conn.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            self.txSent += UInt64(chunkSize)
            if error != nil {
                self.txTotal = 0
                self.sendControlSync("ERR TX сбой: \(String(describing: error))")
                return
            }
            if self.txSent >= self.txTotal {
                let n = self.txTotal
                self.txTotal = 0
                self.finishTest(kind: "TX", bytes: n)
            } else {
                self.pumpTx()
            }
        })
    }

    private func finishTest(kind: String, bytes: UInt64) {
        let ms = Int(Date().timeIntervalSince(testStarted) * 1000)
        lastTestLine = "\(kind) \(megabytes(bytes)) МБ за \(max(ms, 1)) мс"
        sendControlSync("DONE \(kind) \(bytes) \(ms)")
        pushStats()
    }

    private func sendControlSync(_ text: String) {
        guard let conn = controlConn else { return }
        let payload = Data("\(text)\n".utf8)
        conn.send(content: payload, completion: .contentProcessed { _ in })
    }

    // MARK: - Публикация в UI

    private func pushStats() {
        let now = Date()
        guard now.timeIntervalSince(lastPush) > 0.2 else { return }
        lastPush = now
        let inMB = megabytes(dataIn)
        let outMB = megabytes(dataOut)
        let conns = connectionsCount
        DispatchQueue.main.async {
            self.dataInMB = inMB
            self.dataOutMB = outMB
            self.connections = conns
        }
    }

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.status = text }
    }

    private func setRunning(_ value: Bool, statusText: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.running = value
            if let t = statusText { self.status = t }
        }
    }

    private func setConnDebug(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.connDebug = text }
    }

    private func megabytes(_ bytes: UInt64) -> Int {
        Int(bytes / 1_048_576)
    }
}
