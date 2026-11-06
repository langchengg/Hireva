import CoreAudio
import Combine
import Foundation
import AVFoundation
import os

@MainActor
public final class AudioDeviceManager: ObservableObject {
    public static let shared = AudioDeviceManager()

    // One metadata read is one fact. Commit all copied values before invoking
    // synchronous observers, which may close admission or request a new read.
    private let route: CurrentValueSubject<AudioDeviceRouteSnapshot, Never>

    /// A read-only projection retains the generated `$field` subscription name.
    /// Its getter and publisher derive from one route snapshot; it stores no
    /// copied field value. The projected type is now AnyPublisher, so callers
    /// explicitly requiring Published<Value>.Publisher must migrate that type.
    @propertyWrapper
    @MainActor
    public struct RouteProjection<Value> {
        private let read: () -> Value
        private let publication: AnyPublisher<Value, Never>
        fileprivate init(read: @escaping () -> Value, publication: AnyPublisher<Value, Never>) {
            self.read = read
            self.publication = publication
        }
        public var wrappedValue: Value { read() }
        public var projectedValue: AnyPublisher<Value, Never> { publication }
    }

    @RouteProjection public var currentInputDeviceName: String
    @RouteProjection public var currentOutputDeviceName: String
    @RouteProjection public var currentInputDeviceID: String
    @RouteProjection public var currentOutputDeviceID: String
    @RouteProjection public var isUsingHeadphonesOrBluetooth: Bool
    @RouteProjection public var routeDescription: String

    nonisolated private let deviceQueue = DispatchQueue(label: "com.langcheng.hireva.audiodevice")

    nonisolated private let inputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    nonisolated private let outputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    nonisolated private let observations = AudioDeviceObservationRegistrations()
    nonisolated private let refreshWork = AudioDeviceRefreshWork()
    nonisolated private let testingOperations: AudioDeviceManagerTestingOperations?

    private init() {
        let route = CurrentValueSubject<AudioDeviceRouteSnapshot, Never>(.initial)
        self.route = route
        _currentInputDeviceName = RouteProjection(read: { route.value.inputName }, publication: route.map(\.inputName).eraseToAnyPublisher())
        _currentOutputDeviceName = RouteProjection(read: { route.value.outputName }, publication: route.map(\.outputName).eraseToAnyPublisher())
        _currentInputDeviceID = RouteProjection(read: { route.value.inputID }, publication: route.map(\.inputID).eraseToAnyPublisher())
        _currentOutputDeviceID = RouteProjection(read: { route.value.outputID }, publication: route.map(\.outputID).eraseToAnyPublisher())
        _isUsingHeadphonesOrBluetooth = RouteProjection(read: { route.value.isUsingHeadphonesOrBluetooth }, publication: route.map(\.isUsingHeadphonesOrBluetooth).eraseToAnyPublisher())
        _routeDescription = RouteProjection(read: { Self.makeRouteDescription(snapshot: route.value) }, publication: route.map { Self.makeRouteDescription(snapshot: $0) }.eraseToAnyPublisher())
        testingOperations = nil
        deviceQueue.async { [weak self] in self?.setupObservers() }
        refreshDevices()
    }

    init(testingOperations: AudioDeviceManagerTestingOperations) {
        let route = CurrentValueSubject<AudioDeviceRouteSnapshot, Never>(.initial)
        self.route = route
        _currentInputDeviceName = RouteProjection(read: { route.value.inputName }, publication: route.map(\.inputName).eraseToAnyPublisher())
        _currentOutputDeviceName = RouteProjection(read: { route.value.outputName }, publication: route.map(\.outputName).eraseToAnyPublisher())
        _currentInputDeviceID = RouteProjection(read: { route.value.inputID }, publication: route.map(\.inputID).eraseToAnyPublisher())
        _currentOutputDeviceID = RouteProjection(read: { route.value.outputID }, publication: route.map(\.outputID).eraseToAnyPublisher())
        _isUsingHeadphonesOrBluetooth = RouteProjection(read: { route.value.isUsingHeadphonesOrBluetooth }, publication: route.map(\.isUsingHeadphonesOrBluetooth).eraseToAnyPublisher())
        _routeDescription = RouteProjection(read: { Self.makeRouteDescription(snapshot: route.value) }, publication: route.map { Self.makeRouteDescription(snapshot: $0) }.eraseToAnyPublisher())
        self.testingOperations = testingOperations
        deviceQueue.async { [weak self] in
            guard let self, !self.refreshWork.isClosed else { return }
            self.observations.addTestingRemoval(testingOperations.observe { [weak self] in self?.refreshDevices() })
        }
        refreshDevices()
    }

    deinit {
        refreshWork.closeAdmission()
        let observations = self.observations
        deviceQueue.async { _ = observations.close() }
    }

    /// Close callbacks immediately, then await the exact queue cleanup and any
    /// already admitted publication. Native removal failure retains its handle.
    public func shutdown() async -> Bool {
        refreshWork.closeAdmission()
        testingOperations?.onAdmissionClosed()
        let observations = self.observations
        let removed = await withCheckedContinuation { continuation in
            deviceQueue.async { continuation.resume(returning: observations.close()) }
        }
        await refreshWork.waitForIdle()
        return removed
    }

    var pendingRefreshCountForTesting: Int { refreshWork.pendingCount }
    func finishRefreshesForTesting() async { await refreshWork.waitForIdle() }

    nonisolated private func setupObservers() {
        guard !refreshWork.isClosed else { return }
        // Observe default input device changes
        let inputBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshDevices()
        }
        
        var addrInput = inputAddress
        let inputBlockStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addrInput,
            DispatchQueue.main,
            inputBlock
        )
        if inputBlockStatus == noErr { observations.addCoreAudio(address: addrInput, block: inputBlock) }

        // Observe default output device changes
        let outputBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshDevices()
        }
        
        var addrOutput = outputAddress
        let outputBlockStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addrOutput,
            DispatchQueue.main,
            outputBlock
        )
        if outputBlockStatus == noErr { observations.addCoreAudio(address: addrOutput, block: outputBlock) }

        // Observe AVAudioEngineConfigurationChange Notification as a backup
        let configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshDevices()
        }
        observations.addNotification(configObserver)

        // Observe AVCaptureDevice connection / disconnection notifications
        let connObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshDevices()
        }
        observations.addNotification(connObserver)

        let disconnObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshDevices()
        }
        observations.addNotification(disconnObserver)
    }

    nonisolated public func refreshDevices() {
        guard let revision = refreshWork.request() else { return }
        enqueueRefresh(revision: revision)
    }

    nonisolated private func enqueueRefresh(revision: UInt64) {
        let refreshWork = self.refreshWork
        deviceQueue.async { [weak self] in
            guard let self else { refreshWork.closeAdmission(); refreshWork.complete(); return }
            let snapshot = self.testingOperations?.read() ?? self.readNativeSnapshot()
            // Only copied scalar metadata crosses this queue boundary. One
            // active read/publication and one replaceable refresh are bounded.
            DispatchQueue.main.async { [weak self] in
                guard let self else { refreshWork.closeAdmission(); refreshWork.complete(); return }
                if refreshWork.isCurrent(revision) {
                    MainActor.assumeIsolated { self.apply(snapshot) }
                }
                if let next = refreshWork.complete() { self.enqueueRefresh(revision: next) }
            }
        }
    }

    nonisolated private func readNativeSnapshot() -> AudioDeviceRouteSnapshot {
        let inputID = getDefaultInputDeviceID(), outputID = getDefaultOutputDeviceID()
        let inputName = Self.resolvedDeviceName(getDeviceName(deviceID: inputID), fallback: "Unknown Input")
        let outputName = Self.resolvedDeviceName(getDeviceName(deviceID: outputID), fallback: "Unknown Output")
        return AudioDeviceRouteSnapshot(inputName: inputName, outputName: outputName,
            inputID: String(inputID), outputID: String(outputID),
            isUsingHeadphonesOrBluetooth:
                isBluetoothOrHeadphone(transportType: getDeviceTransportType(deviceID: inputID), deviceName: inputName) ||
                isBluetoothOrHeadphone(transportType: getDeviceTransportType(deviceID: outputID), deviceName: outputName))
    }

    private func apply(_ snapshot: AudioDeviceRouteSnapshot) {
        route.send(snapshot)
        objectWillChange.send()
    }

    nonisolated static func resolvedDeviceName(_ name: String?, fallback: String) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    nonisolated static func makeRouteDescription(inputName: String, outputName: String) -> String {
        "Input: \(inputName), Output: \(outputName)"
    }

    nonisolated private static func makeRouteDescription(snapshot: AudioDeviceRouteSnapshot) -> String {
        // Keep the existing initial placeholder while deriving every native
        // route description from the one copied metadata value.
        if snapshot == .initial { return "Input: Default, Output: Default" }
        return makeRouteDescription(inputName: snapshot.inputName, outputName: snapshot.outputName)
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

    nonisolated private func getDefaultInputDeviceID() -> AudioDeviceID {
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

    nonisolated private func getDefaultOutputDeviceID() -> AudioDeviceID {
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

    nonisolated private func getAudioDeviceIDs() -> [AudioDeviceID] {
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

    nonisolated private func getDeviceName(deviceID: AudioDeviceID) -> String? {
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

    nonisolated private func getDeviceUID(deviceID: AudioDeviceID) -> String? {
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

    nonisolated private func getDeviceTransportType(deviceID: AudioDeviceID) -> UInt32 {
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

    nonisolated private func hasStreams(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
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

    nonisolated private func getTransportTypeString(_ transportType: UInt32) -> String {
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

    nonisolated private func isBluetoothOrHeadphone(transportType: UInt32, deviceName: String) -> Bool {
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

struct AudioDeviceRouteSnapshot: Sendable, Equatable {
    static let initial = Self(inputName: "Default Input", outputName: "Default Output",
        inputID: "default", outputID: "default", isUsingHeadphonesOrBluetooth: false)
    let inputName: String
    let outputName: String
    let inputID: String
    let outputID: String
    let isUsingHeadphonesOrBluetooth: Bool
}

/// Per-instance metadata/observer replacement. Tests never call CoreAudio,
/// create an engine tap, request permission, or inspect actual device lists.
struct AudioDeviceManagerTestingOperations: Sendable {
    let read: @Sendable () -> AudioDeviceRouteSnapshot
    let observe: @Sendable (@escaping @Sendable () -> Void) -> (@Sendable () -> Bool)
    let onAdmissionClosed: @Sendable () -> Void

    init(read: @escaping @Sendable () -> AudioDeviceRouteSnapshot,
        observe: @escaping @Sendable (@escaping @Sendable () -> Void) -> (@Sendable () -> Bool),
        onAdmissionClosed: @escaping @Sendable () -> Void = {}) {
        self.read = read
        self.observe = observe
        self.onAdmissionClosed = onAdmissionClosed
    }
}

/// This leaf owns only this manager's opaque SDK registrations. The original
/// address/queue/block identity is preserved; failed removals remain retained.
private final class AudioDeviceObservationRegistrations: Sendable {
    private struct NativeRegistration {
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private struct State {
        var native: [NativeRegistration] = []
        var notifications: [any NSObjectProtocol] = []
        var testing: [@Sendable () -> Bool] = []
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    func addCoreAudio(address: AudioObjectPropertyAddress, block: @escaping AudioObjectPropertyListenerBlock) {
        state.withLockUnchecked { $0.native.append(.init(address: address, block: block)) }
    }
    func addNotification(_ token: any NSObjectProtocol) {
        state.withLockUnchecked { $0.notifications.append(token) }
    }
    func addTestingRemoval(_ remove: @escaping @Sendable () -> Bool) {
        state.withLockUnchecked { $0.testing.append(remove) }
    }
    // Called only on the one device queue. Opaque references are borrowed
    // synchronously outside the short lock, never sent through a Task/await.
    func close() -> Bool {
        let captured = state.withLockUnchecked { value in
            let captured = value
            value = State()
            return captured
        }
        var failedNative: [NativeRegistration] = []
        for var registration in captured.native {
            let result = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                &registration.address, DispatchQueue.main, registration.block)
            if result != noErr { failedNative.append(registration) }
        }
        for token in captured.notifications { NotificationCenter.default.removeObserver(token) }
        let failedTesting = captured.testing.filter { !$0() }
        state.withLockUnchecked {
            $0.native.append(contentsOf: failedNative)
            $0.testing.append(contentsOf: failedTesting)
        }
        return failedNative.isEmpty && failedTesting.isEmpty
    }
}

/// Device names are replaceable display facts, not business control events.
/// Only one queued read/publication plus one coalesced refresh can be owned.
private final class AudioDeviceRefreshWork: Sendable {
    private struct State: Sendable {
        var revision: UInt64 = 0
        var closed = false
        var active = false
        var pending = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var isClosed: Bool { state.withLock { $0.closed } }
    var pendingCount: Int { state.withLock { ($0.active ? 1 : 0) + ($0.pending ? 1 : 0) } }
    func request() -> UInt64? {
        state.withLock {
            guard !$0.closed else { return nil }
            $0.revision &+= 1
            if $0.active { $0.pending = true; return nil }
            $0.active = true
            return $0.revision
        }
    }
    func isCurrent(_ revision: UInt64) -> Bool { state.withLock { !$0.closed && $0.revision == revision } }
    func closeAdmission() { state.withLock { $0.closed = true; $0.pending = false; $0.revision &+= 1 } }
    @discardableResult
    func complete() -> UInt64? {
        let captured = state.withLock { value -> (UInt64?, [CheckedContinuation<Void, Never>]) in
            if !value.closed && value.pending {
                value.pending = false
                return (value.revision, [])
            }
            value.active = false
            let waiters = value.waiters; value.waiters.removeAll()
            return (nil, waiters)
        }
        captured.1.forEach { $0.resume() }
        return captured.0
    }
    func waitForIdle() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock {
                guard $0.active else { return true }
                $0.waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
