import CoreAudio
import Combine
import Foundation
import AVFoundation

public final class AudioDeviceManager: ObservableObject {
    public static let shared = AudioDeviceManager()

    @MainActor @Published public private(set) var currentInputDeviceName: String = "Default Input"
    @MainActor @Published public private(set) var currentOutputDeviceName: String = "Default Output"
    @MainActor @Published public private(set) var currentInputDeviceID: String = "default"
    @MainActor @Published public private(set) var currentOutputDeviceID: String = "default"
    @MainActor @Published public private(set) var isUsingHeadphonesOrBluetooth: Bool = false
    @MainActor @Published public private(set) var routeDescription: String = "Input: Default, Output: Default"

    private let deviceQueue = DispatchQueue(label: "com.interviewcopilot.audiodevice")

    private var inputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var outputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var observers: [NSObjectProtocol] = []
    
    // Hold block references strongly so they don't get deallocated
    private var inputListenerBlock: AudioObjectPropertyListenerBlock?
    private var outputListenerBlock: AudioObjectPropertyListenerBlock?

    private init() {
        setupObservers()
        refreshDevices()
    }

    deinit {
        let activeObservers = observers
        let blockIn = inputListenerBlock
        let blockOut = outputListenerBlock
        let addrIn = inputAddress
        let addrOutput = outputAddress
        
        deviceQueue.async {
            var tempAddrIn = addrIn
            var tempAddrOut = addrOutput
            if let block = blockIn {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &tempAddrIn, DispatchQueue.main, block)
            }
            if let block = blockOut {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &tempAddrOut, DispatchQueue.main, block)
            }
        }

        Task { @MainActor in
            for observer in activeObservers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    private func setupObservers() {
        // Observe default input device changes
        let inputBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshDevices()
        }
        self.inputListenerBlock = inputBlock
        
        var addrInput = inputAddress
        _ = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addrInput,
            DispatchQueue.main,
            inputBlock
        )

        // Observe default output device changes
        let outputBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshDevices()
        }
        self.outputListenerBlock = outputBlock
        
        var addrOutput = outputAddress
        _ = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addrOutput,
            DispatchQueue.main,
            outputBlock
        )

        // Observe AVAudioEngineConfigurationChange Notification as a backup
        let configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshDevices()
        }
        observers.append(configObserver)

        // Observe AVCaptureDevice connection / disconnection notifications
        let connObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshDevices()
        }
        observers.append(connObserver)

        let disconnObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshDevices()
        }
        observers.append(disconnObserver)
    }

    public func refreshDevices() {
        deviceQueue.async { [weak self] in
            guard let self else { return }
            let inputID = self.getDefaultInputDeviceID()
            let outputID = self.getDefaultOutputDeviceID()

            let inputName = self.getDeviceName(deviceID: inputID) ?? "Unknown Input"
            let outputName = self.getDeviceName(deviceID: outputID) ?? "Unknown Output"

            let inputTransport = self.getDeviceTransportType(deviceID: inputID)
            let outputTransport = self.getDeviceTransportType(deviceID: outputID)

            let isInputBluetoothOrHeadphone = self.isBluetoothOrHeadphone(transportType: inputTransport, deviceName: inputName)
            let isOutputBluetoothOrHeadphone = self.isBluetoothOrHeadphone(transportType: outputTransport, deviceName: outputName)

            let isUsingHeadphonesOrBluetooth = isInputBluetoothOrHeadphone || isOutputBluetoothOrHeadphone
            let routeDescription = "Input: \(inputName), Output: \(outputName)"

            Task { @MainActor in
                self.currentInputDeviceID = String(inputID)
                self.currentOutputDeviceID = String(outputID)
                self.currentInputDeviceName = inputName
                self.currentOutputDeviceName = outputName
                self.isUsingHeadphonesOrBluetooth = isUsingHeadphonesOrBluetooth
                self.routeDescription = routeDescription
            }
        }
    }

    public func listAvailableDevices() -> [AudioDeviceInfo] {
        // Enqueue onto deviceQueue for reading to be thread-safe
        return deviceQueue.sync {
            let deviceIDs = getAudioDeviceIDs()
            let defaultInput = getDefaultInputDeviceID()
            let defaultOutput = getDefaultOutputDeviceID()

            return deviceIDs.compactMap { deviceID in
                guard let name = getDeviceName(deviceID: deviceID),
                      let uid = getDeviceUID(deviceID: deviceID) else { return nil }

                let isInput = hasStreams(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput)
                let isOutput = hasStreams(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)
                
                // Skip devices that are neither input nor output
                guard isInput || isOutput else { return nil }

                let transportTypeRaw = getDeviceTransportType(deviceID: deviceID)
                let transportString = getTransportTypeString(transportTypeRaw)

                return AudioDeviceInfo(
                    id: uid,
                    name: name,
                    transportType: transportString,
                    isDefaultInput: deviceID == defaultInput,
                    isDefaultOutput: deviceID == defaultOutput,
                    isInput: isInput,
                    isOutput: isOutput
                )
            }
        }
    }

    // MARK: - Core Audio Helpers

    private func getDefaultInputDeviceID() -> AudioDeviceID {
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = inputAddress

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        return status == noErr ? deviceID : 0
    }

    private func getDefaultOutputDeviceID() -> AudioDeviceID {
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = outputAddress

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        return status == noErr ? deviceID : 0
    }

    private func getAudioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard sizeStatus == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        let dataStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        return dataStatus == noErr ? deviceIDs : []
    }

    private func getDeviceName(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var result: Unmanaged<CFString>?
        var propSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propSize,
            &result
        )
        if status == noErr, let unmanaged = result {
            return unmanaged.takeRetainedValue() as String
        }
        return nil
    }

    private func getDeviceUID(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var result: Unmanaged<CFString>?
        var propSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propSize,
            &result
        )
        if status == noErr, let unmanaged = result {
            return unmanaged.takeRetainedValue() as String
        }
        return nil
    }

    private func getDeviceTransportType(deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var propSize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propSize,
            &transportType
        )
        return status == noErr ? transportType : 0
    }

    private func hasStreams(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var propSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &propSize
        )
        return status == noErr && propSize > 0
    }

    private func getTransportTypeString(_ transportType: UInt32) -> String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-In"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        default:
            let bytes = [
                UInt8((transportType >> 24) & 0xff),
                UInt8((transportType >> 16) & 0xff),
                UInt8((transportType >> 8) & 0xff),
                UInt8(transportType & 0xff)
            ]
            if let str = String(bytes: bytes, encoding: .ascii) {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "Unknown" : trimmed
            }
            return "Unknown"
        }
    }

    private func isBluetoothOrHeadphone(transportType: UInt32, deviceName: String) -> Bool {
        // Prioritize Core Audio transport type
        if transportType == kAudioDeviceTransportTypeBluetooth ||
           transportType == kAudioDeviceTransportTypeBluetoothLE {
            return true
        }
        
        // Fall back to name-matching only if the transport type is virtual/unknown (0) or aggregate
        if transportType == 0 || transportType == kAudioDeviceTransportTypeAggregate || transportType == kAudioDeviceTransportTypeVirtual {
            let lower = deviceName.lowercased()
            return lower.contains("bluetooth") ||
                   lower.contains("airpods") ||
                   lower.contains("headphone") ||
                   lower.contains("headset")
        }
        
        return false
    }
}
