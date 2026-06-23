import Foundation

// Self-describing HUP manifests for the phone-bridged peripherals.
//
// This is the iOS half of "plug in any device, zero code": the phone, acting
// as the BLE bridge, tells the brain what each peripheral can do. The brain
// builds the LLM tools, safety policy, UI card, and the closed-loop honesty
// check from these manifests alone — there is no per-device code on the brain
// for the glasses or wristband.
//
// Capabilities are in DeviceCapability model shape (id / parameters), which is
// exactly what the brain's `peripheral_bridge_register` handler feeds into
// `DeviceManifest(**...)`. The second glasses model (W610) is the live
// "unknown device, zero code" proof — it appears as a full card with no app or
// brain change beyond this declarative manifest.

public enum PeripheralManifests {

    /// Build the bridge `devices[]` payload for every self-describing
    /// peripheral. Send via `FeralNode.sendPeripheralBridgeRegister`.
    public static func bridgeDevices() -> [[String: AnyCodable]] {
        [theoraGlasses(), w610Glasses(), veepooWristband()]
    }

    // MARK: - Devices

    static func theoraGlasses() -> [String: AnyCodable] {
        deviceEntry(
            deviceId: "theora-w300",
            kind: "glasses",
            proto: "ble",
            manifest: manifest(
                deviceId: "theora-w300",
                deviceType: "glasses",
                name: "Theora Glasses",
                manufacturer: "Theora",
                model: "W300",
                location: "head",
                sensors: ["heart_rate", "spo2", "temperature", "uv", "steps"],
                actuators: ["speaker", "haptic"],
                capabilities: [
                    sensorCap("read_heart_rate", "Read Heart Rate",
                              "Current heart rate (BPM) from the PPG sensor."),
                    sensorCap("read_spo2", "Read Blood Oxygen",
                              "Blood-oxygen saturation (%)."),
                    sensorCap("read_temperature", "Read Temperature",
                              "Skin temperature."),
                    actuatorCap("play_audio", "Play Audio",
                                "Play audio out the glasses speaker.",
                                tier: "active", confirm: false,
                                params: [param("audio_b64", "string"),
                                         param("encoding", "string", required: false)]),
                    actuatorCap("vibrate", "Haptic Buzz",
                                "Pulse the glasses haptic.",
                                tier: "active", confirm: false,
                                params: [param("ms", "integer")]),
                ]
            )
        )
    }

    /// The second, different glasses model — the "unknown device, zero code"
    /// proof. Same declarative path, a control surface the brain has never
    /// seen before.
    static func w610Glasses() -> [String: AnyCodable] {
        deviceEntry(
            deviceId: "w610-open",
            kind: "glasses",
            proto: "ble",
            manifest: manifest(
                deviceId: "w610-open",
                deviceType: "glasses",
                name: "W610 Open Glasses",
                manufacturer: "OpenGlass",
                model: "W610",
                location: "head",
                sensors: ["imu"],
                actuators: ["camera", "speaker"],
                capabilities: [
                    sensorCap("capture_photo", "Capture Photo",
                              "Take a photo from the glasses camera."),
                    actuatorCap("play_audio", "Play Audio",
                                "Play audio out the glasses speaker.",
                                tier: "active", confirm: false,
                                params: [param("audio_b64", "string")]),
                    actuatorCap("set_led", "Set LED",
                                "Set the status LED color.",
                                tier: "passive", confirm: false,
                                params: [param("r", "integer"), param("g", "integer"),
                                         param("b", "integer")]),
                ]
            )
        )
    }

    static func veepooWristband() -> [String: AnyCodable] {
        deviceEntry(
            deviceId: "veepoo-band",
            kind: "wristband",
            proto: "ble",
            manifest: manifest(
                deviceId: "veepoo-band",
                deviceType: "wristband",
                name: "Veepoo Wristband",
                manufacturer: "Veepoo",
                model: "FERAL-1",
                location: "wrist",
                sensors: ["heart_rate", "spo2", "temperature", "ecg"],
                actuators: ["haptic"],
                capabilities: [
                    sensorCap("read_heart_rate", "Read Heart Rate",
                              "Current heart rate (BPM)."),
                    sensorCap("read_spo2", "Read Blood Oxygen",
                              "Blood-oxygen saturation (%)."),
                    actuatorCap("vibrate", "Haptic Buzz",
                                "Pulse the wristband haptic to get the wearer's attention.",
                                tier: "active", confirm: false,
                                params: [param("ms", "integer")]),
                ]
            )
        )
    }

    // MARK: - Builders

    private static func deviceEntry(
        deviceId: String, kind: String, proto: String, manifest: [String: AnyCodable]
    ) -> [String: AnyCodable] {
        [
            "device_id": .string(deviceId),
            "kind": .string(kind),
            "protocol": .string(proto),
            "manifest": .object(manifest),
        ]
    }

    private static func manifest(
        deviceId: String,
        deviceType: String,
        name: String,
        manufacturer: String,
        model: String,
        location: String,
        sensors: [String],
        actuators: [String],
        capabilities: [[String: AnyCodable]]
    ) -> [String: AnyCodable] {
        [
            "device_id": .string(deviceId),
            "device_type": .string(deviceType),
            "name": .string(name),
            "manufacturer": .string(manufacturer),
            "model": .string(model),
            "connection_type": .string("ble"),
            "location": .string(location),
            "battery_powered": .bool(true),
            "sensors": .array(sensors.map { .string($0) }),
            "actuators": .array(actuators.map { .string($0) }),
            "capabilities": .array(capabilities.map { .object($0) }),
        ]
    }

    private static func sensorCap(_ id: String, _ name: String, _ desc: String) -> [String: AnyCodable] {
        [
            "id": .string(id),
            "name": .string(name),
            "description": .string(desc),
            "category": .string("sensor"),
            "permission_tier": .string("passive"),
        ]
    }

    private static func actuatorCap(
        _ id: String, _ name: String, _ desc: String,
        tier: String, confirm: Bool, params: [[String: AnyCodable]]
    ) -> [String: AnyCodable] {
        [
            "id": .string(id),
            "name": .string(name),
            "description": .string(desc),
            "category": .string("actuator"),
            "permission_tier": .string(tier),
            "requires_confirmation": .bool(confirm),
            "parameters": .array(params.map { .object($0) }),
        ]
    }

    private static func param(_ name: String, _ type: String, required: Bool = true) -> [String: AnyCodable] {
        [
            "name": .string(name),
            "type": .string(type),
            "required": .bool(required),
        ]
    }
}
