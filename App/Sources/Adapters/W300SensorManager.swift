//
//  W300SensorManager.swift
//  FERAL Companion
//
//  Ported verbatim from the JieLi vendor demo's
//  VoiceHealthAgent/Managers/W300SensorManager.swift. This file
//  carries hard-won SDK quirk fixes the vendor demo accumulated
//  during integration with the W300 hardware — DO NOT rewrite the
//  callback handling without re-validating against real glasses.
//
//  Key SDK quirks documented inline:
//    * SpO2: `jwTestOxygen(.start)` returns Status=1 (Fail) WITH
//      valid data — we ignore status and trust resultType + payload.
//    * Temperature: device auto-stops the test, signalled either by
//      callback value == -999 OR `testStatus == .testEnd`.
//    * UV: status==1 (success) AND status==4 (Factory Mode) are
//      both valid for W300 firmware variants.
//    * Heart rate: never stop the test manually; SDK crashes. Let
//      it auto-time-out instead.
//    * SpO2: never call `jwTestOxygen(.end)`; SDK crashes.

import Foundation

#if canImport(JWBle)
import JWBle

// MARK: - Sensor Types
enum SensorType {
    case heartRate
    case spo2
    case temperature
    case uv
    case steps
}

// MARK: - Sensor Errors
enum SensorError: Error {
    case deviceBusy
    case notConnected
    case deviceNotReady
    case timeout
    case invalidData
    case deviceStopped
    case unknown(String)

    var localizedDescription: String {
        switch self {
        case .deviceBusy: return "Device is busy with another test"
        case .notConnected: return "W300 glasses not connected"
        case .deviceNotReady: return "Device not ready. Please ensure glasses are worn properly."
        case .timeout: return "Sensor test timed out"
        case .invalidData: return "Invalid sensor data received"
        case .deviceStopped: return "Device stopped the test"
        case .unknown(let msg): return msg
        }
    }
}

// MARK: - Sensor Data Models
struct HeartRateReading {
    let bpm: Int
    let isWearing: Bool
    let timestamp: Date
    var isValid: Bool { return bpm > 0 && bpm < 220 && isWearing }
}

struct SpO2Reading {
    let current: Int
    let high: Int
    let low: Int
    let timestamp: Date
    var isValid: Bool { return current >= 85 && current <= 100 }
}

struct TemperatureReading {
    let celsius: Float
    let fahrenheit: Float
    let isWearing: Bool
    let timestamp: Date
    var isValid: Bool { return celsius >= 30.0 && celsius <= 42.0 && isWearing }
}

struct UVReading {
    let level: Int
    let timestamp: Date
    var isValid: Bool { return level >= 0 && level <= 15 }
}

struct StepsReading {
    let steps: Int
    let distance: Int  // meters
    let calories: Int  // kcal
    let timestamp: Date
}

// MARK: - W300 Sensor Manager
@objc final class W300SensorManager: NSObject {

    @objc static let shared = W300SensorManager()

    // MARK: - Cache Storage
    private var hrCache: HeartRateReading?
    private var spo2Cache: SpO2Reading?
    private var tempCache: TemperatureReading?
    private var uvCache: UVReading?
    private var stepsCache: StepsReading?

    // MARK: - Busy Flags
    private var busyFlags: [SensorType: Bool] = [
        .heartRate: false, .spo2: false, .temperature: false, .uv: false, .steps: false
    ]

    // MARK: - Cache Expiration (seconds)
    private let cacheExpiration: [SensorType: TimeInterval] = [
        .heartRate: 5,
        .spo2: 300,
        .temperature: 600,
        .uv: 120,
        .steps: 60
    ]

    private override init() { super.init() }

    // MARK: - Cache Validation
    private func isCacheValid(_ type: SensorType) -> Bool {
        let expiration = cacheExpiration[type] ?? 0
        let now = Date()
        switch type {
        case .heartRate: guard let c = hrCache else { return false }; return now.timeIntervalSince(c.timestamp) < expiration
        case .spo2: guard let c = spo2Cache else { return false }; return now.timeIntervalSince(c.timestamp) < expiration
        case .temperature: guard let c = tempCache else { return false }; return now.timeIntervalSince(c.timestamp) < expiration
        case .uv: guard let c = uvCache else { return false }; return now.timeIntervalSince(c.timestamp) < expiration
        case .steps: guard let c = stepsCache else { return false }; return now.timeIntervalSince(c.timestamp) < expiration
        }
    }

    // MARK: - Busy
    private func isBusy(_ type: SensorType) -> Bool { busyFlags[type] ?? false }
    private func setBusy(_ type: SensorType, busy: Bool) { busyFlags[type] = busy }

    // MARK: - Connection Check
    @objc func isDeviceConnected() -> Bool {
        return JWBleManager.shareInstance().isConnected
    }

    // MARK: - Heart Rate
    func getHeartRate(completion: @escaping (Result<HeartRateReading, SensorError>) -> Void) {
        if isCacheValid(.heartRate), let cached = hrCache { completion(.success(cached)); return }
        guard isDeviceConnected() else { completion(.failure(.notConnected)); return }
        guard !isBusy(.heartRate) else { completion(.failure(.deviceBusy)); return }

        setBusy(.heartRate, busy: true)
        var hasReturned = false
        var lastValidHR: Int = 0

        JWBleAction.jwTestHRAction(true) { [weak self] status, testStatus, hrValue in
            guard let self = self, !hasReturned else { return }
            if status == .busy {
                hasReturned = true
                self.setBusy(.heartRate, busy: false)
                completion(.failure(.deviceBusy))
                return
            }
            if hrValue > 0 && hrValue < 220 { lastValidHR = Int(hrValue) }
            // testStatus: 0=starting, 1=in-progress, 2=stopped
            if testStatus.rawValue == 1 && hrValue > 0 {
                let reading = HeartRateReading(bpm: Int(hrValue), isWearing: true, timestamp: Date())
                if reading.isValid {
                    hasReturned = true
                    self.hrCache = reading
                    self.setBusy(.heartRate, busy: false)
                    completion(.success(reading))
                }
            }
            if testStatus.rawValue == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self = self, !hasReturned else { return }
                    if lastValidHR > 0 {
                        let reading = HeartRateReading(bpm: lastValidHR, isWearing: true, timestamp: Date())
                        hasReturned = true
                        self.hrCache = reading
                        self.setBusy(.heartRate, busy: false)
                        completion(.success(reading))
                    } else {
                        hasReturned = true
                        self.setBusy(.heartRate, busy: false)
                        completion(.failure(.deviceNotReady))
                    }
                }
            }
        }

        // Don't stop test - SDK crashes. Let it auto-time-out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self = self, !hasReturned else { return }
            if self.isBusy(.heartRate) {
                hasReturned = true
                self.setBusy(.heartRate, busy: false)
                completion(.failure(.timeout))
            }
        }
    }

    // MARK: - SpO2
    func getSpO2(completion: @escaping (Result<SpO2Reading, SensorError>) -> Void) {
        if isCacheValid(.spo2), let cached = spo2Cache { completion(.success(cached)); return }
        guard isDeviceConnected() else { completion(.failure(.notConnected)); return }
        guard !isBusy(.spo2) else { completion(.failure(.deviceBusy)); return }

        setBusy(.spo2, busy: true)

        JWBleAction.jwTestOxygen(.start) { [weak self] status, resultType, oxygenModel in
            guard let self = self else { return }
            // SDK QUIRK: Status field is unreliable. Trust resultType + payload.
            if (resultType == .start || resultType == .available),
               let model = oxygenModel,
               model.mCurValue > 0 {
                let reading = SpO2Reading(
                    current: Int(model.mCurValue),
                    high: Int(model.mHighValue),
                    low: Int(model.mLowValue),
                    timestamp: Date()
                )
                if reading.isValid {
                    self.spo2Cache = reading
                    self.setBusy(.spo2, busy: false)
                    completion(.success(reading))
                }
            } else if status == .busy {
                self.setBusy(.spo2, busy: false)
                completion(.failure(.deviceBusy))
            }
        }

        // Don't call jwTestOxygen(.end) - SDK crashes when stopping SpO2.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self = self else { return }
            if self.isBusy(.spo2) {
                self.setBusy(.spo2, busy: false)
                completion(.failure(.timeout))
            }
        }
    }

    // MARK: - Temperature
    func getTemperature(completion: @escaping (Result<TemperatureReading, SensorError>) -> Void) {
        if isCacheValid(.temperature), let cached = tempCache { completion(.success(cached)); return }
        guard isDeviceConnected() else { completion(.failure(.notConnected)); return }
        guard !isBusy(.temperature) else { completion(.failure(.deviceBusy)); return }

        setBusy(.temperature, busy: true)
        var testCompleted = false

        JWBleManager.shareInstance().realTimeTemperatureCallBack = { [weak self] value, gradientStatus, wearingState, compensationStatus in
            guard let self = self else { return }
            // SDK QUIRK: device auto-stop signal value == -999.
            if value == -999 {
                testCompleted = true
                self.setBusy(.temperature, busy: false)
                JWBleManager.shareInstance().realTimeTemperatureCallBack = { _, _, _, _ in }
                completion(.failure(.deviceStopped))
                return
            }
            if value > 0 && wearingState {
                let celsius = value
                let fahrenheit = (celsius * 9.0/5.0) + 32.0
                let reading = TemperatureReading(
                    celsius: celsius, fahrenheit: fahrenheit,
                    isWearing: wearingState, timestamp: Date()
                )
                if reading.isValid {
                    self.tempCache = reading
                    self.setBusy(.temperature, busy: false)
                    JWBleManager.shareInstance().realTimeTemperatureCallBack = { _, _, _, _ in }
                    completion(.success(reading))
                }
            }
        }

        JWBleAction.jwTestTemperatureAction(1) { [weak self] status, testStatus in
            guard let self = self else { return }
            // SDK QUIRK: device auto-stop also signalled by testStatus == .testEnd.
            if testStatus == .testEnd && !testCompleted {
                testCompleted = true
                self.setBusy(.temperature, busy: false)
                JWBleManager.shareInstance().realTimeTemperatureCallBack = { _, _, _, _ in }
                completion(.failure(.deviceStopped))
            } else if status == .busy {
                self.setBusy(.temperature, busy: false)
                JWBleManager.shareInstance().realTimeTemperatureCallBack = { _, _, _, _ in }
                completion(.failure(.deviceBusy))
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self = self else { return }
            if !testCompleted && self.isBusy(.temperature) {
                JWBleAction.jwTestTemperatureAction(0, callBack: nil)
                JWBleManager.shareInstance().realTimeTemperatureCallBack = { _, _, _, _ in }
                self.setBusy(.temperature, busy: false)
                completion(.failure(.timeout))
            }
        }
    }

    // MARK: - UV
    func getUVLevel(completion: @escaping (Result<UVReading, SensorError>) -> Void) {
        if isCacheValid(.uv), let cached = uvCache { completion(.success(cached)); return }
        guard isDeviceConnected() else { completion(.failure(.notConnected)); return }
        guard !isBusy(.uv) else { completion(.failure(.deviceBusy)); return }

        setBusy(.uv, busy: true)

        JWBleAction.jwGetDeviceUV(true) { [weak self] status, level in
            guard let self = self else { return }
            // SDK QUIRK: status==1 (success) and status==4 (Factory Mode) both valid.
            if status == .success || status.rawValue == 4 {
                let reading = UVReading(level: Int(level), timestamp: Date())
                if reading.isValid {
                    self.uvCache = reading
                    self.setBusy(.uv, busy: false)
                    completion(.success(reading))
                }
            } else if status == .busy {
                self.setBusy(.uv, busy: false)
                completion(.failure(.deviceBusy))
            } else {
                self.setBusy(.uv, busy: false)
                completion(.failure(.invalidData))
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self else { return }
            if self.isBusy(.uv) {
                JWBleAction.jwGetDeviceUV(false, callBack: nil)
                self.setBusy(.uv, busy: false)
            }
        }
    }

    // MARK: - Steps
    func getSteps(completion: @escaping (Result<StepsReading, SensorError>) -> Void) {
        if isCacheValid(.steps), let cached = stepsCache { completion(.success(cached)); return }
        guard isDeviceConnected() else { completion(.failure(.notConnected)); return }

        JWBleAction.jwGetRealTimeStep { [weak self] status, step, dis, calories in
            guard let self = self else { return }
            if status == .success {
                let reading = StepsReading(
                    steps: Int(step), distance: Int(dis),
                    calories: Int(calories), timestamp: Date()
                )
                self.stepsCache = reading
                completion(.success(reading))
            } else {
                completion(.failure(.invalidData))
            }
        }
    }
}
#endif
