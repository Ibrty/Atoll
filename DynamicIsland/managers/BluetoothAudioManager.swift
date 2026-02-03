//
//  BluetoothAudioManager.swift
//  DynamicIsland
//
//  Created for Bluetooth audio device connection detection and monitoring
//  Detects when audio devices connect and displays HUD with battery status
//

import Foundation
import Combine
import AppKit
import Defaults
import SwiftUI
import IOBluetooth
import IOKit
import CoreBluetooth

/// Manages detection and monitoring of Bluetooth audio device connections
class BluetoothAudioManager: ObservableObject {
    static let shared = BluetoothAudioManager()
    
    // MARK: - Published Properties
    @Published var lastConnectedDevice: BluetoothAudioDevice?
    @Published var connectedDevices: [BluetoothAudioDevice] = []
    @Published var isBluetoothAudioConnected: Bool = false
    
    // MARK: - Private Properties
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private let coordinator = DynamicIslandViewCoordinator.shared
    private var pollingTimer: Timer?
    private let bluetoothPreferencesSuite = "com.apple.Bluetooth"
    private let batteryReader = BluetoothLEBatteryReader()
    private var isLiveBatteryRefreshInFlight = false

    @Published private(set) var batteryStatus: [String: String] = [:]

    private var batteryStatusByAddress: [String: Int] = [:]
    private var batteryStatusByName: [String: Int] = [:]
    private var missingBatteryLog: Set<String> = []
    private var lastBatteryStatusUpdate: Date?
    private let batteryStatusUpdateInterval: TimeInterval = 20
    private let pmsetFetchQueue = DispatchQueue(label: "com.dynamicisland.bluetooth.pmset", qos: .utility)
    private var isPmsetRefreshInFlight = false
    private var lastPmsetRefreshDate: Date?
    private let pmsetRefreshCooldown: TimeInterval = 5
    private var hudBatteryWaitTasks: [UUID: Task<Void, Never>] = [:]
    private let hudBatteryWaitInterval: TimeInterval = 0.3
    private let hudBatteryWaitTimeout: TimeInterval = 1.8
    
    fileprivate struct AirPodsSides: Equatable {
            var left: Int?
            var right: Int?
            var caseLevel: Int?
            var leftConnected: Bool?
            var rightConnected: Bool?
        }

        @Published fileprivate var airPodsSidesByName: [String: AirPodsSides] = [:]

        fileprivate enum AirPodSide {
            case left
            case right
        }
    
    // MARK: - Initialization
    private init() {
        print("🎧 [BluetoothAudioManager] Initializing...")
        setupBluetoothObservers()
        checkInitialDevices()
        startPollingForChanges()
    }
    
    deinit {
        cleanup()
    }
    
    // MARK: - Setup Methods
    
    /// Sets up observers for Bluetooth device connection/disconnection events
    private func setupBluetoothObservers() {
        print("🎧 [BluetoothAudioManager] Setting up Bluetooth observers...")
        
        // Use DistributedNotificationCenter for IOBluetooth notifications
        let dnc = DistributedNotificationCenter.default()
        
        // Observe device connected notifications
        dnc.addObserver(
            self,
            selector: #selector(handleDeviceConnectedNotification(_:)),
            name: NSNotification.Name("IOBluetoothDeviceConnectedNotification"),
            object: nil
        )
        
        // Observe device disconnected notifications
        dnc.addObserver(
            self,
            selector: #selector(handleDeviceDisconnectedNotification(_:)),
            name: NSNotification.Name("IOBluetoothDeviceDisconnectedNotification"),
            object: nil
        )
        
        print("🎧 [BluetoothAudioManager] ✅ Observers registered with DistributedNotificationCenter")
    }
    
    /// Starts polling for device connection changes (fallback mechanism)
    private func startPollingForChanges() {
        print("🎧 [BluetoothAudioManager] Starting polling timer (3s interval)...")
        
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.checkForDeviceChanges()
        }
    }
    
    /// Checks for device connection/disconnection changes
    private func checkForDeviceChanges() {
        // Check if Bluetooth is powered on
        guard IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON else {
            // Bluetooth is off - clear connected devices if any
            if !connectedDevices.isEmpty {
                print("🎧 [BluetoothAudioManager] ⚠️ Bluetooth powered off - clearing connected devices")
                connectedDevices.removeAll()
                isBluetoothAudioConnected = false
            }
            return
        }
        
        guard let pairedDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return
        }
        
        let currentlyConnectedAddresses = Set(
            pairedDevices
                .filter { $0.isConnected() && isAudioDevice($0) }
                .compactMap { $0.addressString }
        )
        
        let previousAddresses = Set(connectedDevices.map { $0.address })
        
        // Check for new connections
        let newAddresses = currentlyConnectedAddresses.subtracting(previousAddresses)
        if !newAddresses.isEmpty {
            print("🎧 [BluetoothAudioManager] 🔍 Polling detected new connection(s)")
            checkForNewlyConnectedDevices()
        }
        
        // Check for disconnections
        let removedAddresses = previousAddresses.subtracting(currentlyConnectedAddresses)
        if !removedAddresses.isEmpty {
            print("🎧 [BluetoothAudioManager] 🔍 Polling detected disconnection(s)")
            updateConnectedDevices()
        }
    }
    
    /// Checks for already connected Bluetooth audio devices on init
    private func checkInitialDevices() {
        print("🎧 [BluetoothAudioManager] Checking for initially connected devices...")
        
        // Check if Bluetooth is powered on
        guard IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON else {
            print("🎧 [BluetoothAudioManager] ⚠️ Bluetooth is powered off - skipping initial check")
            return
        }
        
        guard let pairedDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            print("🎧 [BluetoothAudioManager] No paired devices found")
            return
        }
        
        let connectedAudioDevices = pairedDevices.filter { device in
            device.isConnected() && isAudioDevice(device)
        }
        
        print("🎧 [BluetoothAudioManager] Found \(connectedAudioDevices.count) connected audio devices")
        
        connectedDevices = connectedAudioDevices.compactMap { device in
            createBluetoothAudioDevice(from: device)
        }
        
        // Update connection state
        isBluetoothAudioConnected = !connectedDevices.isEmpty
        
        refreshBatteryLevelsForConnectedDevices()

        if let lastDevice = connectedDevices.last {
            lastConnectedDevice = lastDevice
            print("🎧 [BluetoothAudioManager] ✅ Bluetooth audio connected: \(lastDevice.name)")
        }
    }
    
    // MARK: - Device Event Handlers
    
    /// Handles Bluetooth device connection notification from DistributedNotificationCenter
    @objc private func handleDeviceConnectedNotification(_ notification: Notification) {
        print("🎧 [BluetoothAudioManager] 📡 Device connection notification received")
        
        // Re-check all devices since distributed notification doesn't contain device object
        checkForNewlyConnectedDevices()
    }
    
    /// Handles Bluetooth device disconnection notification from DistributedNotificationCenter
    @objc private func handleDeviceDisconnectedNotification(_ notification: Notification) {
        print("🎧 [BluetoothAudioManager] 📡 Device disconnection notification received")
        
        // Re-check all devices to update connection state
        updateConnectedDevices()
    }
    
    /// Checks for newly connected devices and displays HUD for new ones
    private func checkForNewlyConnectedDevices() {
        // Check if Bluetooth is powered on
        guard IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON else {
            print("🎧 [BluetoothAudioManager] ⚠️ Bluetooth is powered off - skipping device check")
            return
        }
        
        guard let pairedDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return
        }
        
        let currentlyConnectedDevices = pairedDevices.filter { device in
            device.isConnected() && isAudioDevice(device)
        }
        
        // Find devices that are newly connected
        for device in currentlyConnectedDevices {
            let address = device.addressString ?? "Unknown"
            
            // Check if this device wasn't in our list before
            if !connectedDevices.contains(where: { $0.address == address }) {
                print("🎧 [BluetoothAudioManager] 🎉 New audio device connected: \(device.name ?? "Unknown")")
                
                guard let audioDevice = createBluetoothAudioDevice(from: device) else {
                    continue
                }
                
                // Add to connected devices
                connectedDevices.append(audioDevice)
                lastConnectedDevice = audioDevice
                isBluetoothAudioConnected = true

                refreshBatteryLevelsForConnectedDevices()
                
                // Show HUD for new connection
                if let refreshedDevice = connectedDevices.last {
                    showDeviceConnectedHUD(refreshedDevice)
                } else {
                    showDeviceConnectedHUD(audioDevice)
                }
            }
        }
    }
    
    /// Updates the list of connected devices (for disconnections)
    private func updateConnectedDevices() {
        guard let pairedDevices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return
        }
        
        let currentlyConnectedAddresses = pairedDevices
            .filter { $0.isConnected() && isAudioDevice($0) }
            .compactMap { $0.addressString }
        
        // Remove disconnected devices
        let removedDevices = connectedDevices.filter { device in
            !currentlyConnectedAddresses.contains(device.address)
        }
        connectedDevices.removeAll { device in
            !currentlyConnectedAddresses.contains(device.address)
        }
        
        if !removedDevices.isEmpty {
            print("🎧 [BluetoothAudioManager] 👋 Audio device(s) disconnected")
            removedDevices.forEach { cancelHUDBatteryWait(for: $0) }
        }
        
        isBluetoothAudioConnected = !connectedDevices.isEmpty

        refreshBatteryLevelsForConnectedDevices()
    }
    
    /// Handles Bluetooth device connection event (legacy - kept for compatibility)
    private func handleDeviceConnected(_ notification: Notification) {
        guard let device = notification.object as? IOBluetoothDevice else {
            print("🎧 [BluetoothAudioManager] ⚠️ Could not extract device from notification")
            return
        }
        
        // Only handle audio devices
        guard isAudioDevice(device) else {
            print("🎧 [BluetoothAudioManager] Device is not an audio device, ignoring")
            return
        }
        
        print("🎧 [BluetoothAudioManager] 🎉 Audio device connected: \(device.name ?? "Unknown")")
        
        guard let audioDevice = createBluetoothAudioDevice(from: device) else {
            return
        }
        
        // Add to connected devices list
        if !connectedDevices.contains(where: { $0.address == audioDevice.address }) {
            connectedDevices.append(audioDevice)
        }
        
        // Update last connected device
        lastConnectedDevice = audioDevice
        isBluetoothAudioConnected = true
        
        // Show HUD
        showDeviceConnectedHUD(audioDevice)
    }
    
    /// Handles Bluetooth device disconnection event
    private func handleDeviceDisconnected(_ notification: Notification) {
        guard let device = notification.object as? IOBluetoothDevice else {
            return
        }
        
        guard isAudioDevice(device) else {
            return
        }
        
        print("🎧 [BluetoothAudioManager] 👋 Audio device disconnected: \(device.name ?? "Unknown")")
        
        // Remove from connected devices
        let address = device.addressString ?? "Unknown"
        let removed = connectedDevices.filter { $0.address == address }
        connectedDevices.removeAll { $0.address == address }
        removed.forEach { cancelHUDBatteryWait(for: $0) }
        isBluetoothAudioConnected = !connectedDevices.isEmpty
    }
    
    // MARK: - Device Detection Helpers
    
    /// Determines if a Bluetooth device is an audio device
    private func isAudioDevice(_ device: IOBluetoothDevice) -> Bool {
        // Check if device has audio service UUID
        let audioServiceUUID = IOBluetoothSDPUUID(uuid16: 0x110B)  // Audio Sink
        let headsetServiceUUID = IOBluetoothSDPUUID(uuid16: 0x1108)  // Headset
        let handsfreeServiceUUID = IOBluetoothSDPUUID(uuid16: 0x111E)  // Handsfree
        
        // Check if device has any audio-related services
        if device.getServiceRecord(for: audioServiceUUID) != nil {
            return true
        }
        if device.getServiceRecord(for: headsetServiceUUID) != nil {
            return true
        }
        if device.getServiceRecord(for: handsfreeServiceUUID) != nil {
            return true
        }
        
        // Check device class (major class: Audio/Video)
        let deviceClass = device.classOfDevice
        let majorClass = (deviceClass >> 8) & 0x1F
        let audioVideoMajorClass: UInt32 = 0x04
        
        return majorClass == audioVideoMajorClass
    }
    
    /// Creates a BluetoothAudioDevice model from IOBluetoothDevice
    private func createBluetoothAudioDevice(from device: IOBluetoothDevice) -> BluetoothAudioDevice? {
        let name = device.name ?? "Bluetooth Device"
        let address = device.addressString ?? "Unknown"
        let batteryLevel = getBatteryLevel(from: device)
        let deviceType = detectDeviceType(from: device, name: name)
        
        return BluetoothAudioDevice(
            name: name,
            address: address,
            batteryLevel: batteryLevel,
            deviceType: deviceType
        )
    }
    
    /// Extracts battery level from Bluetooth device
    private func getBatteryLevel(from device: IOBluetoothDevice) -> Int? {
        updateBatteryStatuses()

        if let level = batteryLevelFromRegistry(forAddress: device.addressString) {
            clearMissingBatteryInfo(for: device)
            return level
        }

        if let name = device.name, let level = batteryLevelFromRegistry(forName: name) {
            clearMissingBatteryInfo(for: device)
            return level
        }

        if let level = batteryLevelFromDefaults(forAddress: device.addressString) {
            clearMissingBatteryInfo(for: device)
            return level
        }

        if let name = device.name, let level = batteryLevelFromDefaults(forName: name) {
            clearMissingBatteryInfo(for: device)
            return level
        }

        logMissingBatteryInfo(for: device)
        return nil
    }
    
    // MARK: - AirPods PID-based detection

    /// Known Apple vendor ID
    private let appleVendorID: UInt16 = 0x05AC

    /// Map of Bluetooth Product IDs (PID) -> AirPods device type
    /// Fill in / extend this table as needed.
    private let devicePIDMap: [UInt16: BluetoothAudioDeviceType] = [
        0x2002: .airpods,  //Gen 1 Airpods
        0x200F: .airpods,  //Gen 2 Airpods
        0x2013: .airpodsGen3, //Gen 3 Airpods
        0x2019: .airpodsGen4, //Gen 4 Airpods
        0x201B: .airpodsGen4, //Gen 4 Airpods ANC
        0x200A: .airpodsMax, //Airpods Max Lightning
        0x201F: .airpodsMax,  // Airpods Max USB-C
        0x200E: .airpodsPro, // Airpods Pro Gen 1
        0x2014: .airpodsPro, // Airpods Pro Gen 2 Lightning
        0x2024: .airpodsPro, // Airpods Pro Gen 2 USB-C
        0x2027: .airpodsPro3, // Airpods Pro Gen 3
        0x2017: .beatsstudio, //Beats Studio Pro
        0x2009: .beatsstudio, //Beats Studio 3
        0x2006: .beatssolo, // Beats Solo 3
        0x200C: .beatssolo //Beats Solo Pro
    ]


    /// Extract a UInt16 from common payload formats (Int/NSNumber/String including hex like "0x201B").
    private func extractUInt16(from payload: [String: Any], keys: [String]) -> UInt16? {
        for key in keys {
            guard let raw = payload[key] else { continue }

            if let n = raw as? NSNumber {
                return UInt16(truncatingIfNeeded: n.uint16Value)
            }
            if let i = raw as? Int {
                return UInt16(truncatingIfNeeded: i)
            }
            if let s = raw as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if trimmed.hasPrefix("0x") {
                    let hex = trimmed.dropFirst(2)
                    if let v = UInt16(hex, radix: 16) { return v }
                } else if let v = UInt16(trimmed, radix: 10) {
                    return v
                }
            }
        }
        return nil
    }

    /// Recursively searches nested dictionaries/arrays for the first UInt16 value whose key matches `predicate`.
    private func deepSearchUInt16(in value: Any, predicate: (String) -> Bool) -> UInt16? {
        if let dict = value as? [String: Any] {
            // 1) direct keys
            for (k, v) in dict {
                if predicate(k) {
                    if let found = extractUInt16(from: dict, keys: [k]) {
                        return found
                    }
                    // if the value itself is numeric/string, try parsing it directly
                    if let n = v as? NSNumber { return UInt16(truncatingIfNeeded: n.uint16Value) }
                    if let i = v as? Int { return UInt16(truncatingIfNeeded: i) }
                    if let s = v as? String {
                        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        if t.hasPrefix("0x"), let v16 = UInt16(t.dropFirst(2), radix: 16) { return v16 }
                        if let v16 = UInt16(t, radix: 10) { return v16 }
                    }
                }
            }
            // 2) recurse
            for v in dict.values {
                if let found = deepSearchUInt16(in: v, predicate: predicate) { return found }
            }
            return nil
        } else if let arr = value as? [Any] {
            for v in arr {
                if let found = deepSearchUInt16(in: v, predicate: predicate) { return found }
            }
            return nil
        }
        return nil
    }

    /// Fallback: attempt to get VendorID/ProductID from system_profiler SPBluetoothDataType -json.
    /// NOTE: `device_connected` is an array of dictionaries like `{ "<Device Name>": { ...payload... } }`.
    private func vendorProductIDsFromSystemProfiler(forNormalizedAddress target: String) -> (vendor: UInt16, product: UInt16)? {
        guard !target.isEmpty else { return nil }
        guard let root = systemProfilerBluetoothDictionary() else { return nil }

        
        guard let deviceConnected = root["device_connected"] as? [Any] else { return nil }

        func pidFromPayload(_ payload: [String: Any]) -> UInt16? {
            // system_profiler uses "device_productID" string like "0x2027"
            if let raw = payload["device_productID"] as? String {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if trimmed.hasPrefix("0x"), let v = UInt16(trimmed.dropFirst(2), radix: 16) { return v }
                if let v = UInt16(trimmed, radix: 16) { return v }
            }
            // fallback to our generic extractors
            let productKeys = ["device_productID", "ProductID", "product_id", "productID", "DeviceProductID", "ProductId", "Product ID"]
            return extractUInt16(from: payload, keys: productKeys)
                ?? deepSearchUInt16(in: payload) { $0.lowercased().contains("productid") }
        }

        func vidFromPayload(_ payload: [String: Any]) -> UInt16? {
            let vendorKeys = ["device_vendorID", "VendorID", "vendor_id", "vendorID", "DeviceVendorID", "VendorId", "Vendor ID"]
            return extractUInt16(from: payload, keys: vendorKeys)
                ?? deepSearchUInt16(in: payload) { $0.lowercased().contains("vendorid") }
        }

        // 1) Prefer exact match by address
        for item in deviceConnected {
            guard let d = item as? [String: Any], let n = d.keys.first, let infoAny = d[n], let payload = infoAny as? [String: Any] else {
                continue
            }

            // Match by address-like fields inside payload (system_profiler commonly includes "device_address")
            if let addr = payload["device_address"] as? String {
                if normalizeBluetoothIdentifier(addr) != target { continue }
            } else {
                // If there is no address in payload, try any other address candidates we know about
                let candidates = profilerAddressCandidates(from: payload).map(normalizeBluetoothIdentifier)
                if !candidates.contains(target) { continue }
            }

            if let pid = pidFromPayload(payload) {
                if let vid = vidFromPayload(payload) {
                    return (vendor: vid, product: pid)
                }
                if devicePIDMap[pid] != nil {
                    return (vendor: appleVendorID, product: pid)
                }
            }
        }

        // 2) Secondary fallback: if address wasn't present in payload, match by normalized name,
        // but only return if we find exactly one AirPods PID match.
        // This avoids accidentally mapping the wrong device when multiple AirPods are connected.
        var nameMatches: [(UInt16, UInt16?)] = []
        for item in deviceConnected {
            guard let d = item as? [String: Any], let n = d.keys.first, let infoAny = d[n], let payload = infoAny as? [String: Any] else {
                continue
            }
            // Only consider AirPods-like devices
            let normName = normalizeProductName(n)
            guard normName.contains("airpods") else { continue }

            if let pid = pidFromPayload(payload), devicePIDMap[pid] != nil {
                nameMatches.append((pid, vidFromPayload(payload)))
            }
        }

        if nameMatches.count == 1 {
            let (pid, vid) = nameMatches[0]
            return (vendor: vid ?? appleVendorID, product: pid)
        }

        return nil
    }

    /// Attempts to find VendorID/ProductID for a device using the Bluetooth preference caches.
    private func vendorProductIDs(for device: IOBluetoothDevice) -> (vendor: UInt16, product: UInt16)? {
        guard let preferences = UserDefaults(suiteName: bluetoothPreferencesSuite),
              let deviceCache = preferences.object(forKey: "DeviceCache") as? [String: Any] else {
            return nil
        }

        let target = normalizeBluetoothIdentifier(device.addressString ?? "")
        guard !target.isEmpty else { return nil }

        let vendorKeys = [
            "VendorID", "vendor_id", "vendorID",
            "device_vendorID", "DeviceVendorID", "device_vendor_id",
            "device_vendorId", "DeviceVendorId",
            "VendorId", "Vendor ID",
            "VendorIDSource", "VendorIDSourceLocal", "VendorIDSourceRemote"
        ]
        let productKeys = [
            "ProductID", "product_id", "productID",
            "device_productID", "DeviceProductID", "device_product_id",
            "device_productId", "DeviceProductId",
            "ProductId", "Product ID",
            "ProductIDSource", "ProductIDSourceLocal", "ProductIDSourceRemote"
        ]

        for (key, value) in deviceCache {
            guard let payload = value as? [String: Any] else { continue }
            if matchesBluetoothIdentifier(target, key: key, payload: payload) {
                let vid = extractUInt16(from: payload, keys: vendorKeys)
                    ?? deepSearchUInt16(in: payload) { $0.lowercased().contains("vendorid") }

                let pid = extractUInt16(from: payload, keys: productKeys)
                    ?? deepSearchUInt16(in: payload) { $0.lowercased().contains("productid") }

                if let pid {
                    if let vid {
                        return (vendor: vid, product: pid)
                    }
                    if devicePIDMap[pid] != nil {
                        return (vendor: appleVendorID, product: pid)
                    }
                }
            }
        }

        // Fallback: try CoreBluetoothCache entries (sometimes contains VendorID/ProductID even when DeviceCache doesn't)
        if let coreCache = preferences.object(forKey: "CoreBluetoothCache") as? [String: [String: Any]] {
            for payload in coreCache.values {
                // Match by address if present
                if let addrAny = payload["DeviceAddress"] ?? payload["Address"] ?? payload["BD_ADDR"] ?? payload["device_address"],
                   let addr = normalizeBluetoothIdentifier(from: addrAny),
                   addr == target {
                    let vid = extractUInt16(from: payload, keys: vendorKeys)
                        ?? deepSearchUInt16(in: payload) { $0.lowercased().contains("vendorid") }

                    let pid = extractUInt16(from: payload, keys: productKeys)
                        ?? deepSearchUInt16(in: payload) { $0.lowercased().contains("productid") }

                    if let pid {
                        if let vid {
                            return (vendor: vid, product: pid)
                        }
                        if devicePIDMap[pid] != nil {
                            return (vendor: appleVendorID, product: pid)
                        }
                    }
                }
            }
        }

        // Final fallback: system_profiler (often has vendor/product IDs even when caches don't)
        if let fromProfiler = vendorProductIDsFromSystemProfiler(forNormalizedAddress: target) {
            return fromProfiler
        }

        return nil
    }

    /// Attempts to detect AirPods type using vendor/product IDs.
    /// Returns nil if PID-based detection fails.
    private func airPodsTypeFromPID(_ device: IOBluetoothDevice) -> BluetoothAudioDeviceType? {
        // 1) PRIMARY (AirBattery-style): system_profiler -> device_productID
        if let pid = airBatteryStyleProductIDFromSystemProfiler(for: device) {
            return devicePIDMap[pid]
        }

        // 2) Secondary: your existing cache-based vendor/product logic (if you still want it)
        if let ids = vendorProductIDs(for: device) {
            return devicePIDMap[ids.product]
        }

        return nil
    }

    /// Detects the type of audio device based on name and properties
    private func detectDeviceType(from device: IOBluetoothDevice, name: String) -> BluetoothAudioDeviceType {
        let lowercaseName = name.lowercased()

        // 1) PRIMARY: PID-based AirPods detection (name-independent)
        if let pidBasedType = airPodsTypeFromPID(device) {
            return pidBasedType
        }
        print("[Atoll][AirPods PID] PID lookup FAILED, falling back to name for:", name, "addr:", device.addressString ?? "nil")

        // 2) FALLBACK: name-based AirPods detection (for renamed devices or unknown PIDs)
        if lowercaseName.contains("airpods") {
            if lowercaseName.contains("max") {
                return .airpodsMax
            } else if lowercaseName.contains("pro") {
                return .airpodsPro
            } else if lowercaseName.contains("gen 4")
                        || lowercaseName.contains("gen4")
                        || lowercaseName.contains("4th")
                        || lowercaseName.contains("airpods 4")
                        || lowercaseName.contains("airpods4")
                        || lowercaseName.contains("4") {
                return .airpodsGen4
            } else if lowercaseName.contains("gen 3")
                        || lowercaseName.contains("gen3")
                        || lowercaseName.contains("3rd")
                        || lowercaseName.contains("third")
                        || lowercaseName.contains("airpods 3")
                        || lowercaseName.contains("airpods3")
                        || lowercaseName.contains("3") {
                return .airpodsGen3
            }
            return .airpods
        }

        // Check for other brands
        if lowercaseName.contains("beats") {
            return .beatssolo
        } else if lowercaseName.contains("speaker") || lowercaseName.contains("boombox") {
            return .speaker
        } else if lowercaseName.contains("headphone") || lowercaseName.contains("headset") ||
                  lowercaseName.contains("buds") || lowercaseName.contains("earbuds") {
            return .headphones
        }

        // Check device class for more specific detection
        let deviceClass = device.classOfDevice
        let minorClass = (deviceClass >> 2) & 0x3F

        // Minor classes for audio devices
        switch minorClass {
        case 0x01: return .headphones  // Wearable Headset
        case 0x02: return .headphones  // Hands-free
        case 0x06: return .headphones  // Headphones
        case 0x08: return .speaker     // Portable Audio
        case 0x0C: return .speaker     // Loudspeaker
        default: return .generic
        }
    }

    private func refreshBatteryLevelsForConnectedDevices(forceCacheRefresh: Bool = true) {
        if forceCacheRefresh {
            updateBatteryStatuses(force: true)
        }

        applyConnectedDeviceBatteryLevels()
        triggerLiveBatteryRefreshIfNeeded()
    }

    private func applyConnectedDeviceBatteryLevels(triggerPmsetFallback: Bool = true) {
        guard !connectedDevices.isEmpty else {
            lastConnectedDevice = nil
            return
        }

        var updatedDevices: [BluetoothAudioDevice] = []
        for device in connectedDevices {
            let refreshedLevel = bestBatteryLevel(for: device)
            let updatedDevice = device.withBatteryLevel(refreshedLevel)
            updatedDevices.append(updatedDevice)

            if let refreshedLevel {
                clearMissingBatteryInfo(forName: device.name, address: device.address)
            } else {
                logMissingBatteryInfo(forName: device.name, address: device.address)
            }
        }

        connectedDevices = updatedDevices
        if let last = updatedDevices.last {
            lastConnectedDevice = last
        }

        if triggerPmsetFallback,
           updatedDevices.contains(where: { $0.batteryLevel == nil }) {
            requestPmsetFallback(reason: "missing battery after refresh")
        }
    }

    private func bestBatteryLevel(for device: BluetoothAudioDevice) -> Int? {
        batteryLevelFromRegistry(forAddress: device.address)
            ?? batteryLevelFromRegistry(forName: device.name)
            ?? batteryLevelFromDefaults(forAddress: device.address)
            ?? batteryLevelFromDefaults(forName: device.name)
            ?? device.batteryLevel
    }

    private func requestPmsetFallback(reason: String) {
        guard connectedDevices.contains(where: { $0.batteryLevel == nil }) else { return }
        guard !isPmsetRefreshInFlight else { return }

        let now = Date()
        if let lastPmsetRefreshDate,
           now.timeIntervalSince(lastPmsetRefreshDate) < pmsetRefreshCooldown {
            return
        }

        isPmsetRefreshInFlight = true
        print("🎧 [BluetoothAudioManager] 🔄 Triggering pmset fallback (\(reason))")
        pmsetFetchQueue.async { [weak self] in
            guard let self else { return }
            let entries = self.collectPmsetAccessoryBatteryEntries()
            DispatchQueue.main.async {
                self.handlePmsetFallbackResults(entries)
            }
        }
    }

    private func handlePmsetFallbackResults(_ entries: [PmsetAccessoryBatteryEntry]) {
        isPmsetRefreshInFlight = false
        lastPmsetRefreshDate = Date()
        guard !entries.isEmpty else { return }

        var updatedNames = batteryStatusByName
        _ = mergePmsetEntries(entries, into: &updatedNames, logNewEntries: true)

        // ✅ Apply if anything changed
        guard updatedNames != batteryStatusByName else { return }

        batteryStatusByName = updatedNames
        applyConnectedDeviceBatteryLevels(triggerPmsetFallback: false)

        if let level = hudBatteryLevelCandidate() {
            updateActiveBluetoothHUDBattery(with: level)
        }
    }


    private func triggerLiveBatteryRefreshIfNeeded() {
        guard !connectedDevices.isEmpty else { return }
        guard connectedDevices.contains(where: { $0.batteryLevel == nil }) else { return }
        guard !isLiveBatteryRefreshInFlight else { return }

        let lookups = coreBluetoothLookups(for: connectedDevices)
        guard !lookups.isEmpty else { return }

        isLiveBatteryRefreshInFlight = true
        batteryReader.fetchBatteryLevels(for: lookups) { [weak self] results in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isLiveBatteryRefreshInFlight = false
                self.handleLiveBatteryResults(results)
            }
        }
    }

    private func coreBluetoothLookups(for devices: [BluetoothAudioDevice]) -> [BluetoothLEBatteryReader.Lookup] {
        let snapshot = coreBluetoothCacheSnapshot()
        guard snapshot.hasEntries else { return [] }

        var lookups: [BluetoothLEBatteryReader.Lookup] = []
        var seenUUIDs: Set<UUID> = []

        for device in devices {
            let normalizedAddress = normalizeBluetoothIdentifier(device.address)
            let normalizedName = normalizeProductName(device.name)
            guard !normalizedAddress.isEmpty || !normalizedName.isEmpty else { continue }

            let uuid = snapshot.byAddress[normalizedAddress]
                ?? snapshot.byName[normalizedName]

            guard let uuid, !seenUUIDs.contains(uuid) else { continue }
            seenUUIDs.insert(uuid)

            let canonicalName = snapshot.namesByUUID[uuid] ?? normalizedName
            lookups.append(
                .init(
                    uuid: uuid,
                    addressKey: normalizedAddress.isEmpty ? nil : normalizedAddress,
                    nameKey: canonicalName.isEmpty ? nil : canonicalName
                )
            )
        }

        return lookups
    }

    private func handleLiveBatteryResults(_ results: [BluetoothLEBatteryReader.Result]) {
        guard !results.isEmpty else { return }

        var didUpdate = false

        for result in results {
            let level = clampBatteryPercentage(result.level)

            if let addressKey = result.addressKey, !addressKey.isEmpty {
                let previous = batteryStatusByAddress[addressKey] ?? -1
                if level > previous {
                    batteryStatusByAddress[addressKey] = level
                    batteryStatus[addressKey] = String(level)
                    didUpdate = true
                }
            }

            if let nameKey = result.nameKey, !nameKey.isEmpty {
                let previous = batteryStatusByName[nameKey] ?? -1
                if level > previous {
                    batteryStatusByName[nameKey] = level
                    didUpdate = true
                }
            }
        }

        guard didUpdate else { return }

        applyConnectedDeviceBatteryLevels()
        if let level = hudBatteryLevelCandidate() {
            updateActiveBluetoothHUDBattery(with: level)
        }
    }

    private func updateActiveBluetoothHUDBattery(with level: Int?) {
        guard let level else { return }
        DispatchQueue.main.async {
            guard self.coordinator.sneakPeek.show,
                  self.coordinator.sneakPeek.type == .bluetoothAudio else { return }
            self.coordinator.sneakPeek.value = CGFloat(level) / 100.0
        }
    }

    private func hudBatteryLevelCandidate() -> Int? {
        lastConnectedDevice?.batteryLevel
            ?? connectedDevices.last(where: { $0.batteryLevel != nil })?.batteryLevel
    }

    private func coreBluetoothCacheSnapshot() -> CoreBluetoothCacheSnapshot {
        guard let preferences = UserDefaults(suiteName: bluetoothPreferencesSuite),
              let coreCache = preferences.object(forKey: "CoreBluetoothCache") as? [String: [String: Any]] else {
            return .empty
        }

        var byAddress: [String: UUID] = [:]
        var byName: [String: UUID] = [:]
        var namesByUUID: [UUID: String] = [:]

        for (uuidString, payload) in coreCache {
            guard let uuid = UUID(uuidString: uuidString) else { continue }

            let addressKeys = ["DeviceAddress", "Address", "BD_ADDR", "device_address"]
            for key in addressKeys {
                if let value = payload[key], let normalized = normalizeBluetoothIdentifier(from: value) {
                    byAddress[normalized] = uuid
                }
            }

            if let serialValue = payload["SerialNumber"], let normalizedSerial = normalizeBluetoothIdentifier(from: serialValue) {
                byAddress[normalizedSerial] = uuid
            }

            let nameKeys = ["Name", "DeviceName", "ProductName", "Product", "device_name"]
            for key in nameKeys {
                if let value = payload[key], let normalizedName = normalizeProductName(from: value) {
                    byName[normalizedName] = uuid
                    namesByUUID[uuid] = normalizedName
                }
            }
        }

        return CoreBluetoothCacheSnapshot(byAddress: byAddress, byName: byName, namesByUUID: namesByUUID)
    }

    private func normalizeBluetoothIdentifier(from value: Any) -> String? {
        if let string = value as? String {
            let normalized = normalizeBluetoothIdentifier(string)
            return normalized.isEmpty ? nil : normalized
        }

        if let data = value as? Data,
           let ascii = String(data: data, encoding: .utf8) {
            let normalized = normalizeBluetoothIdentifier(ascii)
            return normalized.isEmpty ? nil : normalized
        }

        return nil
    }

    private func normalizeProductName(from value: Any) -> String? {
        if let string = value as? String {
            let normalized = normalizeProductName(string)
            return normalized.isEmpty ? nil : normalized
        }
        if let data = value as? Data,
           let ascii = String(data: data, encoding: .utf8) {
            let normalized = normalizeProductName(ascii)
            return normalized.isEmpty ? nil : normalized
        }
        return nil
    }

    private struct CoreBluetoothCacheSnapshot {
        let byAddress: [String: UUID]
        let byName: [String: UUID]
        let namesByUUID: [UUID: String]

        var hasEntries: Bool {
            !byAddress.isEmpty || !byName.isEmpty
        }

        static let empty = CoreBluetoothCacheSnapshot(byAddress: [:], byName: [:], namesByUUID: [:])
    }

    private struct PmsetAccessoryBatteryEntry {
        let displayName: String
        let normalizedName: String
        let level: Int
    }

    @discardableResult
    private func mergePmsetEntries(
        _ entries: [PmsetAccessoryBatteryEntry],
        into names: inout [String: Int],
        logNewEntries: Bool
    ) -> [PmsetAccessoryBatteryEntry] {
        guard !entries.isEmpty else { return [] }

        var newlyFilled: [PmsetAccessoryBatteryEntry] = []

        func upsert(_ key: String, _ level: Int) {
            guard !key.isEmpty else { return }
            let prev = names[key]
            if prev == nil {
                names[key] = level
            } else if let prev, level > prev {
                names[key] = level
            }
        }

        for entry in entries {
            let clamped = clampBatteryPercentage(entry.level)

            // 1) store full normalized name (current behavior)
            if names[entry.normalizedName] == nil { newlyFilled.append(entry) }
            upsert(entry.normalizedName, clamped)

            // 2) ALSO store a “product-only” alias starting at airpods/beats if present
            if let r = entry.normalizedName.range(of: "beats") {
                let alias = String(entry.normalizedName[r.lowerBound...]) // e.g. "beatsstudiopro"
                upsert(alias, clamped)
            }
            if let r = entry.normalizedName.range(of: "airpods") {
                let alias = String(entry.normalizedName[r.lowerBound...]) // e.g. "airpodspro"
                upsert(alias, clamped)
            }
        }

        if logNewEntries {
            for entry in newlyFilled {
                print("🎧 [BluetoothAudioManager] ℹ️ pmset reported \(entry.level)% for \(entry.displayName)")
            }
        }

        return newlyFilled
    }


    private func batteryLevelFromDefaults(forAddress address: String?) -> Int? {
        guard let address, !address.isEmpty else { return nil }
        guard let preferences = UserDefaults(suiteName: bluetoothPreferencesSuite) else { return nil }
        guard let deviceCache = preferences.object(forKey: "DeviceCache") as? [String: Any] else { return nil }

        let normalizedTarget = normalizeBluetoothIdentifier(address)
        var bestMatch: Int?

        for (key, value) in deviceCache {
            guard let payload = value as? [String: Any] else { continue }
            if matchesBluetoothIdentifier(normalizedTarget, key: key, payload: payload) {
                if let level = extractBatteryPercentage(from: payload) {
                    let clamped = clampBatteryPercentage(level)
                    bestMatch = max(bestMatch ?? clamped, clamped)
                }
            }
        }

        return bestMatch
    }

    private func batteryLevelFromDefaults(forName name: String) -> Int? {
        guard !name.isEmpty else { return nil }
        guard let preferences = UserDefaults(suiteName: bluetoothPreferencesSuite) else { return nil }
        guard let deviceCache = preferences.object(forKey: "DeviceCache") as? [String: Any] else { return nil }

        var bestMatch: Int?

        for value in deviceCache.values {
            guard let payload = value as? [String: Any] else { continue }
            let candidateName = (payload["Name"] as? String) ?? (payload["DeviceName"] as? String)
            if let candidateName, candidateName.caseInsensitiveCompare(name) == .orderedSame {
                if let level = extractBatteryPercentage(from: payload) {
                    let clamped = clampBatteryPercentage(level)
                    bestMatch = max(bestMatch ?? clamped, clamped)
                }
            }
        }

        return bestMatch
    }

    private func batteryLevelFromRegistry(forName name: String) -> Int? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = normalizeProductName(trimmed)
        guard !normalized.isEmpty else { return nil }
        if let value = batteryStatusByName[normalized] {
            return clampBatteryPercentage(value)
        }
        return nil
    }

    private func updateBatteryStatuses(force: Bool = false) {
        let now = Date()
        if !force, let lastBatteryStatusUpdate,
           now.timeIntervalSince(lastBatteryStatusUpdate) < batteryStatusUpdateInterval {
            return
        }

        var combinedAddressPercentages: [String: Int] = [:]
        var combinedNamePercentages: [String: Int] = [:]
        var combinedAirPodsSidesByName: [String: AirPodsSides] = [:]

        let registry = collectRegistryBatteryLevels()
        mergeBatteryLevels(into: &combinedAddressPercentages, from: registry.addresses)
        mergeBatteryLevels(into: &combinedNamePercentages, from: registry.names)

        let defaults = collectDefaultsBatteryLevels()
        mergeBatteryLevels(into: &combinedAddressPercentages, from: defaults.addresses)
        mergeBatteryLevels(into: &combinedNamePercentages, from: defaults.names)

        let profiler = collectSystemProfilerBatteryLevels()
        mergeBatteryLevels(into: &combinedAddressPercentages, from: profiler.addresses)
        mergeBatteryLevels(into: &combinedNamePercentages, from: profiler.names)
        
        let profilerSides = collectSystemProfilerAirPodsSides()
        mergeAirPodsSides(into: &combinedAirPodsSidesByName, from: profilerSides)

        let defaultsSides = collectDefaultsAirPodsSides()
        mergeAirPodsSides(into: &combinedAirPodsSidesByName, from: defaultsSides)


        let pmsetEntries = collectPmsetAccessoryBatteryEntries()
        mergePmsetEntries(pmsetEntries, into: &combinedNamePercentages, logNewEntries: true)

        var statuses: [String: String] = [:]
        for (key, value) in combinedAddressPercentages {
            statuses[key] = String(clampBatteryPercentage(value))
        }

        let applyUpdates = {
            self.batteryStatus = statuses
            self.batteryStatusByAddress = combinedAddressPercentages
            self.batteryStatusByName = combinedNamePercentages
            self.airPodsSidesByName = combinedAirPodsSidesByName
            self.lastBatteryStatusUpdate = now
        }

        if Thread.isMainThread {
            applyUpdates()
        } else {
            DispatchQueue.main.sync(execute: applyUpdates)
        }
    }

    private func mergeBatteryLevels(into target: inout [String: Int], from source: [String: Int]) {
        guard !source.isEmpty else { return }
        for (key, value) in source {
            guard !key.isEmpty else { continue }
            if let existing = target[key] {
                target[key] = max(existing, value)
            } else {
                target[key] = value
            }
        }
    }
    
    private func mergeAirPodsSides(into target: inout [String: AirPodsSides], from source: [String: AirPodsSides]) {
            guard !source.isEmpty else { return }

            for (key, value) in source {
                guard !key.isEmpty else { continue }
                var current = target[key] ?? AirPodsSides(left: nil, right: nil, caseLevel: nil, leftConnected: nil, rightConnected: nil)

                if let left = value.left {
                    current.left = max(current.left ?? left, left)
                }
                if let right = value.right {
                    current.right = max(current.right ?? right, right)
                }
                if let caseLevel = value.caseLevel {
                    current.caseLevel = max(current.caseLevel ?? caseLevel, caseLevel)
                }
                if let lc = value.leftConnected {
                    current.leftConnected = current.leftConnected ?? lc
                }
                if let rc = value.rightConnected {
                    current.rightConnected = current.rightConnected ?? rc
                }

                target[key] = current
            }
        }

        private func collectSystemProfilerAirPodsSides() -> [String: AirPodsSides] {
            guard let root = systemProfilerBluetoothDictionary() else { return [:] }

            var result: [String: AirPodsSides] = [:]

            if let connectedList = root["device_connected"] as? [[String: [String: Any]]] {
                for deviceGroup in connectedList {
                    for (rawName, payload) in deviceGroup {
                        let normalizedName = normalizeProductName(rawName)
                        guard normalizedName.contains("airpods") else { continue }

                        let sides = extractAirPodsSides(from: payload)
                        if sides.left != nil || sides.right != nil {
                            result[normalizedName] = AirPodsSides(
                                left: sides.left.map(clampBatteryPercentage),
                                right: sides.right.map(clampBatteryPercentage),
                                caseLevel: sides.caseLevel.map(clampBatteryPercentage),
                                leftConnected: sides.leftConnected,
                                rightConnected: sides.rightConnected
                            )
                        }
                    }
                }
            }

            return result
        }

        private func collectDefaultsAirPodsSides() -> [String: AirPodsSides] {
            guard let preferences = UserDefaults(suiteName: bluetoothPreferencesSuite),
                  let deviceCache = preferences.object(forKey: "DeviceCache") as? [String: Any] else {
                return [:]
            }

            var result: [String: AirPodsSides] = [:]

            for value in deviceCache.values {
                guard let payload = value as? [String: Any] else { continue }
                let rawName = (payload["Name"] as? String) ?? (payload["DeviceName"] as? String) ?? ""
                let normalizedName = normalizeProductName(rawName)
                guard normalizedName.contains("airpods") else { continue }

                let sides = extractAirPodsSides(from: payload)
                if sides.left != nil || sides.right != nil {
                    result[normalizedName] = AirPodsSides(
                        left: sides.left.map(clampBatteryPercentage),
                        right: sides.right.map(clampBatteryPercentage),
                        caseLevel: sides.caseLevel.map(clampBatteryPercentage),
                        leftConnected: sides.leftConnected,
                        rightConnected: sides.rightConnected
                    )
                }
            }

            return result
        }

        private func extractAirPodsSides(from payload: [String: Any]) -> AirPodsSides {
            // Try the most common keys we see across DeviceCache + system_profiler.
            let leftKeys = [
                "BatteryPercentLeft",
                "device_batteryLevelLeft",
                "device_batteryPercentLeft",
                "Left Battery Level",
                "LeftBatteryLevel",
                "BatteryLevelLeft",
                "BatteryLeft"
            ]

            let rightKeys = [
                "BatteryPercentRight",
                "device_batteryLevelRight",
                "device_batteryPercentRight",
                "Right Battery Level",
                "RightBatteryLevel",
                "BatteryLevelRight",
                "BatteryRight"
            ]
            
            let caseKeys = [
                "BatteryPercentCase",
                "device_batteryLevelCase",
                "device_batteryPercentCase",
                "Case Battery Level",
                "CaseBatteryLevel",
                "BatteryLevelCase",
                "BatteryCase",
                "CaseBattery",
                // extra variants
                "BatteryPercentChargeCase",
                "ChargeCaseBattery",
                "ChargeCaseBatteryLevel",
                "Charging Case Battery Level",
                "ChargingCaseBatteryLevel",
                "chargingCaseBatteryLevel",
                "charging_case_battery_level"
            ]

            func firstValue(in keys: [String]) -> Int? {
                for key in keys {
                    if let raw = payload[key], let converted = convertToBatteryPercentage(raw) {
                        return converted
                    }
                }
                return nil
            }

            // 1) Primary lookup using known keys
            var left = firstValue(in: leftKeys)
            var right = firstValue(in: rightKeys)
            var caseLevel = firstValue(in: caseKeys)

            // 2) Fallback: scan every key/value in the payload for anything that looks like left/right battery.
            if left == nil || right == nil || caseLevel == nil {
                for (key, raw) in payload {
                    let k = key.lowercased()

                    // only consider keys that look battery-related
                    if !(k.contains("batt") || k.contains("battery") || k.contains("percent") || k.contains("level")) {
                        continue
                    }

                    if left == nil, k.contains("left") {
                        if let converted = convertToBatteryPercentage(raw) {
                            left = converted
                        }
                    }

                    if right == nil, k.contains("right") {
                        if let converted = convertToBatteryPercentage(raw) {
                            right = converted
                        }
                    }
                    
                    if caseLevel == nil, (k.contains("case") || k.contains("chargingcase") || k.contains("chargecase")) {
                        if let converted = convertToBatteryPercentage(raw) {
                            caseLevel = converted
                        }
                    }

                    if left != nil && right != nil && caseLevel != nil { break }
                }
            }

            let connections = extractAirPodsConnections(from: payload)
            return AirPodsSides(
                left: left,
                right: right,
                caseLevel: caseLevel,
                leftConnected: connections.left,
                rightConnected: connections.right
            )
        }

        // Helper to extract per-side connected flags for AirPods
        private func extractAirPodsConnections(from payload: [String: Any]) -> (left: Bool?, right: Bool?) {
            // Common/likely keys across system_profiler + DeviceCache variants
            let leftKeys = [
                "device_connectedLeft",
                "device_isConnectedLeft",
                "DeviceConnectedLeft",
                "LeftConnected",
                "leftConnected",
                "left_connected",
                // Expanded keys for left
                "device_inEarLeft",
                "device_inEarDetectedLeft",
                "InEarLeft",
                "LeftInEar",
                "leftInEar",
                "left_in_ear",
                "device_wornLeft",
                "LeftWorn",
                "leftWorn"
            ]

            let rightKeys = [
                "device_connectedRight",
                "device_isConnectedRight",
                "DeviceConnectedRight",
                "RightConnected",
                "rightConnected",
                "right_connected",
                // Expanded keys for right
                "device_inEarRight",
                "device_inEarDetectedRight",
                "InEarRight",
                "RightInEar",
                "rightInEar",
                "right_in_ear",
                "device_wornRight",
                "RightWorn",
                "rightWorn"
            ]

            func toBool(_ raw: Any) -> Bool? {
                if let b = raw as? Bool { return b }
                if let n = raw as? Int { return n != 0 }
                if let n = raw as? NSNumber { return n.intValue != 0 }
                if let s = raw as? String {
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if ["1","true","yes","y","connected"].contains(t) { return true }
                    if ["0","false","no","n","disconnected"].contains(t) { return false }
                }
                return nil
            }

            func firstBool(in keys: [String]) -> Bool? {
                for k in keys {
                    if let raw = payload[k], let b = toBool(raw) {
                        return b
                    }
                }
                return nil
            }

            // Fallback scan: look for any battery-ish key that also contains left/right + connect/inear/in_ear/worn
            func scan(side: String) -> Bool? {
                for (key, raw) in payload {
                    let k = key.lowercased()
                    guard k.contains(side) else { continue }
                    guard k.contains("connect") || k.contains("inear") || k.contains("in_ear") || k.contains("worn") else { continue }
                    if let b = toBool(raw) { return b }
                }
                return nil
            }

            let left = firstBool(in: leftKeys) ?? scan(side: "left")
            let right = firstBool(in: rightKeys) ?? scan(side: "right")
            return (left, right)
        }

    private func collectRegistryBatteryLevels() -> (addresses: [String: Int], names: [String: Int]) {
        var addressPercentages: [String: Int] = [:]
        var namePercentages: [String: Int] = [:]

        var iterator = io_iterator_t()
        let matchingDict: CFDictionary = IOServiceMatching("AppleDeviceManagementHIDEventService")

        let servicePort: mach_port_t
        if #available(macOS 12.0, *) {
            servicePort = kIOMainPortDefault
        } else {
            servicePort = kIOMasterPortDefault
        }

        let kernResult = IOServiceGetMatchingServices(servicePort, matchingDict, &iterator)

        if kernResult == KERN_SUCCESS {
            var entry: io_object_t = IOIteratorNext(iterator)
            while entry != 0 {
                if let percent = IORegistryEntryCreateCFProperty(entry, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
                    let normalizedPercent = clampBatteryPercentage(percent)

                    let identifierKeys = ["DeviceAddress", "SerialNumber", "BD_ADDR"]
                    for key in identifierKeys {
                        if let identifier = stringValue(forKey: key, entry: entry) {
                            let normalizedIdentifier = normalizeBluetoothIdentifier(identifier)
                            if !normalizedIdentifier.isEmpty {
                                if let existing = addressPercentages[normalizedIdentifier] {
                                    addressPercentages[normalizedIdentifier] = max(existing, normalizedPercent)
                                } else {
                                    addressPercentages[normalizedIdentifier] = normalizedPercent
                                }
                            }
                        }
                    }

                    let nameKeys = [
                        "Product",
                        "ProductName",
                        "DeviceName",
                        "Name",
                        "USB Product Name",
                        "Bluetooth Product Name"
                    ]

                    for key in nameKeys {
                        if let product = stringValue(forKey: key, entry: entry) {
                            let normalizedName = normalizeProductName(product)
                            if !normalizedName.isEmpty {
                                if let existing = namePercentages[normalizedName] {
                                    namePercentages[normalizedName] = max(existing, normalizedPercent)
                                } else {
                                    namePercentages[normalizedName] = normalizedPercent
                                }
                            }
                        }
                    }
                }

                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
        }

        IOObjectRelease(iterator)

        return (addressPercentages, namePercentages)
    }

    private func collectDefaultsBatteryLevels() -> (addresses: [String: Int], names: [String: Int]) {
        guard let preferences = UserDefaults(suiteName: bluetoothPreferencesSuite),
              let deviceCache = preferences.object(forKey: "DeviceCache") as? [String: Any] else {
            return ([:], [:])
        }

        var addressPercentages: [String: Int] = [:]
        var namePercentages: [String: Int] = [:]

        for (key, value) in deviceCache {
            guard let payload = value as? [String: Any] else { continue }
            guard let level = extractBatteryPercentage(from: payload) else { continue }
            let clamped = clampBatteryPercentage(level)

            let normalizedKey = normalizeBluetoothIdentifier(key)
            if !normalizedKey.isEmpty {
                addressPercentages[normalizedKey] = max(addressPercentages[normalizedKey] ?? clamped, clamped)
            }

            for identifier in identifiersFromDeviceCachePayload(payload) {
                addressPercentages[identifier] = max(addressPercentages[identifier] ?? clamped, clamped)
            }

            if let name = (payload["Name"] as? String) ?? (payload["DeviceName"] as? String) {
                let normalizedName = normalizeProductName(name)
                if !normalizedName.isEmpty {
                    namePercentages[normalizedName] = max(namePercentages[normalizedName] ?? clamped, clamped)
                }
            }
        }

        return (addressPercentages, namePercentages)
    }

    private func collectSystemProfilerBatteryLevels() -> (addresses: [String: Int], names: [String: Int]) {
        guard let root = systemProfilerBluetoothDictionary() else {
            return ([:], [:])
        }

        var addressPercentages: [String: Int] = [:]
        var namePercentages: [String: Int] = [:]

        if let connectedList = root["device_connected"] as? [[String: [String: Any]]] {
            for deviceGroup in connectedList {
                for (rawName, payload) in deviceGroup {
                    guard let percent = extractSystemProfilerBatteryPercentage(from: payload) else { continue }
                    let clamped = clampBatteryPercentage(percent)

                    let normalizedName = normalizeProductName(rawName)
                    if !normalizedName.isEmpty {
                        namePercentages[normalizedName] = max(namePercentages[normalizedName] ?? clamped, clamped)
                    }

                    for address in profilerAddressCandidates(from: payload) {
                        let normalizedAddress = normalizeBluetoothIdentifier(address)
                        if !normalizedAddress.isEmpty {
                            addressPercentages[normalizedAddress] = max(addressPercentages[normalizedAddress] ?? clamped, clamped)
                        }
                    }
                }
            }
        }

        return (addressPercentages, namePercentages)
    }

    private func collectPmsetAccessoryBatteryEntries() -> [PmsetAccessoryBatteryEntry] {
        let process = Process()
        process.launchPath = "/usr/bin/pmset"
        process.arguments = ["-g", "accps"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else { return [] }
        guard !data.isEmpty else { return [] }

        // pmset output may not be UTF-8 inside a GUI app; fall back to common encodings
        let output =
            String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .macOSRoman)
            ?? String(data: data, encoding: .isoLatin1)

        guard let output else { return [] }

        // Parse any line that starts with '-' and contains a "<number>%"
        guard let percentRegex = try? NSRegularExpression(pattern: #"(\d+)\s*%"#, options: []) else {
            return []
        }

        var entries: [PmsetAccessoryBatteryEntry] = []

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("-") else { continue }

            // Remove leading '-'
            line.removeFirst()
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)

            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)

            guard let match = percentRegex.firstMatch(in: line, options: [], range: fullRange),
                  match.numberOfRanges >= 2 else {
                continue
            }

            let percentString = nsLine.substring(with: match.range(at: 1))
            guard let level = Int(percentString) else { continue }

            // Name = everything before the percent match; strip trailing "(id=...)" if present
            var namePart = nsLine.substring(to: match.range.location)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            namePart = namePart.replacingOccurrences(
                of: #"\s*\([^)]*\)\s*$"#,
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)

            guard !namePart.isEmpty else { continue }

            let normalizedName = normalizeProductName(namePart)
            guard !normalizedName.isEmpty else { continue }
            if normalizedName.hasPrefix("internalbattery") { continue }

            entries.append(
                PmsetAccessoryBatteryEntry(
                    displayName: namePart,
                    normalizedName: normalizedName,
                    level: level
                )
            )
        }

        return entries
    }


    private func identifiersFromDeviceCachePayload(_ payload: [String: Any]) -> [String] {
        var identifiers: Set<String> = []
        let candidateKeys = ["DeviceAddress", "Address", "BD_ADDR", "SerialNumber"]

        for key in candidateKeys {
            if let value = payload[key] as? String {
                let normalized = normalizeBluetoothIdentifier(value)
                if !normalized.isEmpty {
                    identifiers.insert(normalized)
                }
            } else if let data = payload[key] as? Data,
                      let ascii = String(data: data, encoding: .utf8) {
                let normalized = normalizeBluetoothIdentifier(ascii)
                if !normalized.isEmpty {
                    identifiers.insert(normalized)
                }
            }
        }

        return Array(identifiers)
    }

    private func systemProfilerBluetoothDictionary() -> [String: Any]? {
        let process = Process()
        process.launchPath = "/usr/sbin/system_profiler"
        process.arguments = ["SPBluetoothDataType", "-json"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return nil
        }
        guard !data.isEmpty else { return nil }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let entries = jsonObject["SPBluetoothDataType"] as? [[String: Any]],
              let root = entries.first else {
            return nil
        }

        return root
    }
    
    /// AirBattery-style: read ProductID directly from system_profiler SPBluetoothDataType JSON.
    /// Returns the PID as UInt16 if found (hex string like "0x2027").
    private func airBatteryStyleProductIDFromSystemProfiler(for device: IOBluetoothDevice) -> UInt16? {
        let target = normalizeBluetoothIdentifier(device.addressString ?? "")
        guard !target.isEmpty else { return nil }

        guard
            let jsonObject = systemProfilerBluetoothDictionary(),
            let deviceConnected = jsonObject["device_connected"] as? [Any]
        else { return nil }

        for entry in deviceConnected {
            guard let dict = entry as? [String: Any],
                  let nameKey = dict.keys.first,
                  let info = dict[nameKey] as? [String: Any]
            else { continue }

            // Match address
            if let addr = info["device_address"] as? String {
                if normalizeBluetoothIdentifier(addr) != target { continue }
            } else {
                continue
            }

            // Read PID like AirBattery does
            if let pidString = info["device_productID"] as? String {
                let cleaned = pidString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .replacingOccurrences(of: "0x", with: "")

                if let pid = UInt16(cleaned, radix: 16) {
                    print("[Atoll][AirPods PID] system_profiler matched addr=\(device.addressString ?? "nil") pid=\(pidString)")
                    return pid
                }
            }
        }

        return nil
    }

    private func extractSystemProfilerBatteryPercentage(from payload: [String: Any]) -> Int? {
        let preferredKeys = [
            "device_batteryLevelCase",
            "device_batteryLevelLeft",
            "device_batteryLevelRight",
            "device_batteryLevelMain",
            "device_batteryLevel",
            "device_batteryLevelCombined",
            "device_batteryPercentCombined",
            "Left Battery Level",
            "Right Battery Level",
            "Battery Level",
            "BatteryPercent"
        ]

        var values: [Int] = []

        for key in preferredKeys {
            if let raw = payload[key], let converted = convertToBatteryPercentage(raw) {
                values.append(converted)
            }
        }

        if values.isEmpty {
            for (key, raw) in payload where key.lowercased().contains("battery") {
                if let converted = convertToBatteryPercentage(raw) {
                    values.append(converted)
                }
            }
        }

        let validValues = values.filter { $0 >= 0 }
        return validValues.max()
    }

    private func profilerAddressCandidates(from payload: [String: Any]) -> [String] {
        var addresses: Set<String> = []
        let keys = [
            "device_address",
            "device_mac_address",
            "device_bdaddr",
            "device_bd_addr",
            "bd_addr",
            "BD_ADDR",
            "DeviceAddress",
            "Address",
            "Device Address",
            "device_address_string",
            "device_serial_num",
            "device_serialNumber",
            "device_serial_number"
        ]

        for key in keys {
            if let value = payload[key] as? String, !value.isEmpty {
                addresses.insert(value)
            } else if let data = payload[key] as? Data,
                      let ascii = String(data: data, encoding: .utf8), !ascii.isEmpty {
                addresses.insert(ascii)
            }
        }

        return Array(addresses)
    }

    private func batteryLevelFromRegistry(forAddress address: String?) -> Int? {
        guard let address, !address.isEmpty else { return nil }
        let normalized = normalizeBluetoothIdentifier(address)
        if let value = batteryStatusByAddress[normalized] {
            return clampBatteryPercentage(value)
        }
        if let storedValue = batteryStatus[normalized], let value = Int(storedValue) {
            return clampBatteryPercentage(value)
        }
        return nil
    }

    private func extractBatteryPercentage(from payload: [String: Any]) -> Int? {
        let keys = [
            "BatteryPercent",
            "BatteryPercentCase",
            "BatteryPercentLeft",
            "BatteryPercentRight",
            "BatteryPercentSingle",
            "BatteryPercentCombined",
            "BatteryPercentMain",
            "device_batteryLevelLeft",
            "device_batteryLevelRight",
            "device_batteryLevelMain",
            "Left Battery Level",
            "Right Battery Level"
        ]

        var values: [Int] = []

        for key in keys {
            guard let raw = payload[key] else { continue }
            if let converted = convertToBatteryPercentage(raw) {
                values.append(converted)
            }
        }

        if values.isEmpty,
           let services = payload["Services"] as? [[String: Any]] {
            for service in services {
                if let serviceValues = service["BatteryPercentages"] as? [String: Any] {
                    for value in serviceValues.values {
                        if let converted = convertToBatteryPercentage(value) {
                            values.append(converted)
                        }
                    }
                }
            }
        }

        return values.max()
    }

    private func convertToBatteryPercentage(_ value: Any) -> Int? {
        if let number = value as? Int {
            if number == 1 {
                return 100
            }
            return number
        }
        if let number = value as? Double {
            // Some sources report battery as a fraction (0.0–1.0). Others report percent (0–100).
            // Treat ONLY strict fractions (< 1.0) as fractions. A value of 1.0 is ambiguous and
            // previously caused real 1% readings (sometimes serialized as 1.0) to display as 100%.
            if number > 0.0 && number < 1.0 {
                return Int(number * 100)
            }
            return Int(number)
        }
        if let string = value as? String {
            let trimmed = string.replacingOccurrences(of: "%", with: "")
            if let doubleValue = Double(trimmed) {
                if doubleValue > 0.0 && doubleValue < 1.0 {
                    return Int(doubleValue * 100)
                }
                return Int(doubleValue)
            }
        }

        return nil
    }

    private func clampBatteryPercentage(_ value: Int) -> Int {
        min(max(value, 0), 100)
    }

    private func matchesBluetoothIdentifier(_ normalizedTarget: String, key: String, payload: [String: Any]) -> Bool {
        if normalizeBluetoothIdentifier(key) == normalizedTarget {
            return true
        }

        let candidateFields: [String?] = [
            payload["DeviceAddress"] as? String,
            payload["Address"] as? String,
            payload["BD_ADDR"] as? String,
            payload["SerialNumber"] as? String
        ]

        for field in candidateFields {
            if let field, normalizeBluetoothIdentifier(field) == normalizedTarget {
                return true
            }
        }

        if let deviceAddressData = payload["DeviceAddress"] as? Data,
           let ascii = String(data: deviceAddressData, encoding: .utf8),
           normalizeBluetoothIdentifier(ascii) == normalizedTarget {
            return true
        }

        if let addressData = payload["BD_ADDR"] as? Data,
           let ascii = String(data: addressData, encoding: .utf8),
           normalizeBluetoothIdentifier(ascii) == normalizedTarget {
            return true
        }

        if let serialData = payload["SerialNumber"] as? Data,
           let ascii = String(data: serialData, encoding: .utf8),
           normalizeBluetoothIdentifier(ascii) == normalizedTarget {
            return true
        }

        return false
    }

    private func logMissingBatteryInfo(for device: IOBluetoothDevice) {
        let name = device.name ?? ""
        let address = device.addressString ?? ""
        logMissingBatteryInfo(forName: name, address: address)
    }

    private func clearMissingBatteryInfo(for device: IOBluetoothDevice) {
        let name = device.name ?? ""
        let address = device.addressString ?? ""
        clearMissingBatteryInfo(forName: name, address: address)
    }

    private func logMissingBatteryInfo(forName name: String, address: String) {
        let key = missingBatteryKey(name: name, address: address)
        guard !missingBatteryLog.contains(key) else { return }
        missingBatteryLog.insert(key)

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)

        let displayName = trimmedName.isEmpty ? "unknown device" : trimmedName
        let isUnknownAddress = trimmedAddress.caseInsensitiveCompare("unknown") == .orderedSame
        let displayAddress = (trimmedAddress.isEmpty || isUnknownAddress) ? "N/A" : trimmedAddress
        print("🎧 [BluetoothAudioManager] ⚠️ Battery percentage unavailable for \(displayName) (\(displayAddress))")
    }

    private func clearMissingBatteryInfo(forName name: String, address: String) {
        let key = missingBatteryKey(name: name, address: address)
        missingBatteryLog.remove(key)
    }

    private func missingBatteryKey(name: String, address: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)

        let normalizedName = normalizeProductName(trimmedName)

        let isUnknownAddress = trimmedAddress.caseInsensitiveCompare("unknown") == .orderedSame
        let normalizedAddress = (trimmedAddress.isEmpty || isUnknownAddress) ? "" : normalizeBluetoothIdentifier(trimmedAddress)

        if normalizedName.isEmpty && normalizedAddress.isEmpty {
            return "unknown"
        }

        return normalizedName + "#" + normalizedAddress
    }

    private func stringValue(forKey key: String, entry: io_object_t) -> String? {
        guard let unmanaged = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }

        let value = unmanaged.takeRetainedValue()

        if let string = value as? String, !string.isEmpty {
            return string
        }

        if let data = value as? Data, let ascii = String(data: data, encoding: .utf8), !ascii.isEmpty {
            return ascii
        }

        return nil
    }

    private func cancelHUDBatteryWait(for device: BluetoothAudioDevice) {
        let cancelBlock = { [weak self] in
            guard let self else { return }
            self.hudBatteryWaitTasks[device.id]?.cancel()
            self.hudBatteryWaitTasks.removeValue(forKey: device.id)
        }

        if Thread.isMainThread {
            cancelBlock()
        } else {
            DispatchQueue.main.async(execute: cancelBlock)
        }
    }

    private func normalizeBluetoothIdentifier(_ value: String) -> String {
        return value
            .lowercased()
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private func normalizeProductName(_ name: String) -> String {
        let components = name
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        return components.joined()
    }
    
    struct WidgetBluetoothDevice: Identifiable, Equatable {
            let id: String
            let symbolName: String
            let batteryLevel: Int?
        }

        func widgetBluetoothDevices() -> [WidgetBluetoothDevice] {
            let threshold = 5
            var output: [WidgetBluetoothDevice] = []

            let appendCaseIfAvailable: (_ device: BluetoothAudioDevice, _ caseLevel: Int?) -> Void = { device, caseLevel in
                guard Defaults[.lockScreenShowAirPodsCaseBattery] else { return }
                guard let caseLevel else { return }
                output.append(
                    WidgetBluetoothDevice(
                        id: device.address + "-C",
                        symbolName: device.deviceType.caseSymbol(),
                        batteryLevel: caseLevel
                    )
                )
            }
            for device in connectedDevices {
                // Only split earbud AirPods pairs (AirPods / AirPods Pro). Keep others as-is.
                guard device.deviceType.isEarbudAirPodsPair else {
                    output.append(
                        WidgetBluetoothDevice(
                            id: device.address,
                            symbolName: device.deviceType.sfSymbol,
                            batteryLevel: device.batteryLevel
                        )
                    )
                    continue
                }

                let key = normalizeProductName(device.name)

                // Primary lookup by exact normalized name
                var sides = airPodsSidesByName[key]

                // Fallback: some sources include the user's name in the cache key (e.g. "aidansairpodspro").
                // If we don't find an exact match, match any cached key that ends with the product key.
                if sides == nil {
                    if let matchedKey = airPodsSidesByName.keys.first(where: { $0.hasSuffix(key) }) {
                        sides = airPodsSidesByName[matchedKey]
                    }
                }

                let left = sides?.left
                let right = sides?.right
                let leftConnected = sides?.leftConnected
                let rightConnected = sides?.rightConnected
                let caseLevel = sides?.caseLevel
                let bothConnected = (leftConnected == true && rightConnected == true)
                
                print("[Atoll][AirPods] name=\(device.name) normalized=\(key) left=\(String(describing: left)) right=\(String(describing: right)) case=\(String(describing: caseLevel)) cacheKeys=\(Array(airPodsSidesByName.keys))")

                // If we have no per-side info, keep current behavior.
                guard left != nil || right != nil else {
                    output.append(
                        WidgetBluetoothDevice(
                            id: device.address,
                            symbolName: device.deviceType.pairSymbol(),
                            batteryLevel: device.batteryLevel
                        )
                    )
                    appendCaseIfAvailable(device, caseLevel)
                    continue
                }

                // If we have explicit connection flags, prefer them (prevents showing both when one bud is in the case).
                if let lc = leftConnected, let rc = rightConnected, lc != rc {
                    if lc {
                        output.append(
                            WidgetBluetoothDevice(
                                id: device.address + "-L",
                                symbolName: device.deviceType.earbudSymbol(for: .left),
                                batteryLevel: left
                            )
                        )
                    } else {
                        output.append(
                            WidgetBluetoothDevice(
                                id: device.address + "-R",
                                symbolName: device.deviceType.earbudSymbol(for: .right),
                                batteryLevel: right
                            )
                        )
                    }
                    appendCaseIfAvailable(device, caseLevel)
                    continue
                }
                
                // Case-based inference: if the case battery matches exactly one side,
                // that side is likely in the case → show ONLY the other bud.
                if (leftConnected != nil || rightConnected != nil), !bothConnected, let left, let right, let caseLevel {
                    let eps = 2
                    let leftIsCase = abs(left - caseLevel) <= eps
                    let rightIsCase = abs(right - caseLevel) <= eps

                    if leftIsCase != rightIsCase {
                        if leftIsCase {
                            output.append(
                                WidgetBluetoothDevice(
                                    id: device.address + "-R",
                                    symbolName: device.deviceType.earbudSymbol(for: .right),
                                    batteryLevel: right
                                )
                            )
                            appendCaseIfAvailable(device, caseLevel)
                            continue
                        } else {
                            output.append(
                                WidgetBluetoothDevice(
                                    id: device.address + "-L",
                                    symbolName: device.deviceType.earbudSymbol(for: .left),
                                    batteryLevel: left
                                )
                            )
                            appendCaseIfAvailable(device, caseLevel)
                            continue
                        }
                    }
                }

                // Heuristic fallback (ONLY when it looks like “one bud in case, one bud in ear”):
                // Sometimes macOS reports BOTH left/right percentages even when only one bud is connected.
                // We only collapse to a single bud when:
                // - left/right differ by at least `threshold`
                // - the lower side is quite low (<= 25%), suggesting it's sitting in the case
                // - the device overall battery closely matches the higher side (<= 2%)
                // - and does NOT closely match the lower side
                if (leftConnected != nil || rightConnected != nil), !bothConnected, let left, let right, let overall = device.batteryLevel {
                    let diff = abs(left - right)
                    let lowSide = min(left, right)
                    let highSide = max(left, right)

                    let matchesHigh = abs(highSide - overall) <= 2
                    let matchesLow = abs(lowSide - overall) <= 2

                    if diff >= threshold && lowSide <= 25 && matchesHigh && !matchesLow {
                        if left >= right {
                            output.append(
                                WidgetBluetoothDevice(
                                    id: device.address + "-L",
                                    symbolName: device.deviceType.earbudSymbol(for: .left),
                                    batteryLevel: left
                                )
                            )
                        } else {
                            output.append(
                                WidgetBluetoothDevice(
                                    id: device.address + "-R",
                                    symbolName: device.deviceType.earbudSymbol(for: .right),
                                    batteryLevel: right
                                )
                            )
                        }
                        appendCaseIfAvailable(device, caseLevel)
                        continue
                    }
                }

                // One earbud connected -> show only that side (fallback if no connection flags).
                if let left, right == nil {
                    output.append(
                        WidgetBluetoothDevice(
                            id: device.address + "-L",
                            symbolName: device.deviceType.earbudSymbol(for: .left),
                            batteryLevel: left
                        )
                    )
                    appendCaseIfAvailable(device, caseLevel)
                    continue
                }

                if let right, left == nil {
                    output.append(
                        WidgetBluetoothDevice(
                            id: device.address + "-R",
                            symbolName: device.deviceType.earbudSymbol(for: .right),
                            batteryLevel: right
                        )
                    )
                    appendCaseIfAvailable(device, caseLevel)
                    continue
                }

                // Both connected.
                if let left, let right {
                    let diff = abs(left - right)

                    // diff < 5% -> maintain existing behavior.
                    if diff < threshold {
                        output.append(
                            WidgetBluetoothDevice(
                                id: device.address,
                                symbolName: device.deviceType.pairSymbol(),
                                batteryLevel: max(left, right)
                            )
                        )
                        appendCaseIfAvailable(device, caseLevel)
                        continue
                    }

                    // diff > 5% -> show both.
                    output.append(
                        WidgetBluetoothDevice(
                            id: device.address + "-L",
                            symbolName: device.deviceType.earbudSymbol(for: .left),
                            batteryLevel: left
                        )
                    )
                    output.append(
                        WidgetBluetoothDevice(
                            id: device.address + "-R",
                            symbolName: device.deviceType.earbudSymbol(for: .right),
                            batteryLevel: right
                        )
                    )
                    appendCaseIfAvailable(device, caseLevel)
                    continue
                }

                // Fallback.
                output.append(
                    WidgetBluetoothDevice(
                        id: device.address,
                        symbolName: device.deviceType.sfSymbol,
                        batteryLevel: device.batteryLevel
                    )
                )
            }

            return output
        }
    
    // MARK: - HUD Display
    
    /// Shows HUD notification for newly connected audio device
    private func showDeviceConnectedHUD(_ device: BluetoothAudioDevice) {
        guard Defaults[.showBluetoothDeviceConnections] else { return }

        cancelHUDBatteryWait(for: device)

        if let battery = bestBatteryLevel(for: device) {
            presentDeviceConnectedHUD(device: device, batteryLevel: battery)
            return
        }

        requestPmsetFallback(reason: "hud missing battery")

        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(self.hudBatteryWaitTimeout)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: UInt64(self.hudBatteryWaitInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }

                let batteryInfo = await MainActor.run { () -> (BluetoothAudioDevice, Int)? in
                    guard let refreshedDevice = self.connectedDevices.first(where: { $0.id == device.id }),
                          let battery = self.bestBatteryLevel(for: refreshedDevice) else {
                        return nil
                    }
                    return (refreshedDevice, battery)
                }

                if let (refreshedDevice, battery) = batteryInfo {
                    await MainActor.run {
                        self.presentDeviceConnectedHUD(device: refreshedDevice, batteryLevel: battery)
                    }
                    self.cancelHUDBatteryWait(for: device)
                    return
                }
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.presentDeviceConnectedHUD(device: device, batteryLevel: nil)
            }
            self.cancelHUDBatteryWait(for: device)
        }

        hudBatteryWaitTasks[device.id] = task
    }

    private func presentDeviceConnectedHUD(device: BluetoothAudioDevice, batteryLevel: Int?) {
        guard Defaults[.showBluetoothDeviceConnections] else { return }

        print("🎧 [BluetoothAudioManager] 📱 Showing device connected HUD")

        let batteryValue: CGFloat = if let batteryLevel {
            CGFloat(clampBatteryPercentage(batteryLevel)) / 100.0
        } else {
            0.0
        }

        HUDSuppressionCoordinator.shared.suppressVolumeHUD(for: 1.5)

        Task { @MainActor in
            coordinator.toggleSneakPeek(
                status: true,
                type: .bluetoothAudio,
                duration: 2.5,
                value: batteryValue,
                icon: device.deviceType.sfSymbol
            )
        }
    }
    
    // MARK: - Cleanup
    
    private func cleanup() {
        print("🎧 [BluetoothAudioManager] Cleaning up observers...")
        
        pollingTimer?.invalidate()
        pollingTimer = nil
        
        let dnc = DistributedNotificationCenter.default()
        dnc.removeObserver(self)
        observers.removeAll()
        cancellables.removeAll()
        hudBatteryWaitTasks.values.forEach { $0.cancel() }
        hudBatteryWaitTasks.removeAll()
    }

    @MainActor
    func refreshConnectedDeviceBatteries() {
        refreshBatteryLevelsForConnectedDevices()
    }

    @MainActor
    func activeDeviceIconSymbol() -> String? {
        if let prioritizedDevice = connectedDevices.last ?? lastConnectedDevice {
            return prioritizedDevice.deviceType.sfSymbol
        }
        return nil
    }
}

// MARK: - CoreBluetooth Battery Reader

private final class BluetoothLEBatteryReader: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    struct Lookup {
        let uuid: UUID
        let addressKey: String?
        let nameKey: String?
    }

    struct Result {
        let uuid: UUID
        let level: Int
        let addressKey: String?
        let nameKey: String?
    }

    private enum State {
        case idle
        case requesting
    }

    private static let batteryServiceUUID = CBUUID(string: "180F")
    private static let batteryCharacteristicUUID = CBUUID(string: "2A19")

    private let timeoutInterval: TimeInterval = 6.0

    private var central: CBCentralManager!
    private var state: State = .idle
    private var pendingLookups: [Lookup] = []
    private var lookupByUUID: [UUID: Lookup] = [:]
    private var completion: (([Result]) -> Void)?
    private var pendingPeripherals: [UUID: CBPeripheral] = [:]
    private var results: [UUID: Result] = [:]
    private var missingUUIDs: Set<UUID> = []
    private var timeoutWorkItem: DispatchWorkItem?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func fetchBatteryLevels(for lookups: [Lookup], completion: @escaping ([Result]) -> Void) {
        guard !lookups.isEmpty else {
            completion([])
            return
        }

        guard state == .idle else {
            completion([])
            return
        }

        state = .requesting
        pendingLookups = lookups
        lookupByUUID = Dictionary(uniqueKeysWithValues: lookups.map { ($0.uuid, $0) })
        self.completion = completion
    results.removeAll()
    pendingPeripherals.removeAll()
    missingUUIDs = Set(lookups.map { $0.uuid })

        switch central.state {
        case .poweredOn:
            startRequest()
        case .unauthorized, .unsupported, .poweredOff:
            complete(with: [])
        default:
            break
        }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard state == .requesting else { return }

        switch central.state {
        case .poweredOn:
            startRequest()
        case .unauthorized, .unsupported, .poweredOff:
            complete(with: [])
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.batteryServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        markPeripheralFinished(peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard state == .requesting else { return }
        markPeripheralFinished(peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard state == .requesting else { return }
        guard missingUUIDs.contains(peripheral.identifier) else { return }

        missingUUIDs.remove(peripheral.identifier)
        configurePeripheral(peripheral)
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard state == .requesting else { return }

        if let error {
            print("🎧 [BluetoothLEBatteryReader] Service discovery failed: \(error.localizedDescription)")
            markPeripheralFinished(peripheral.identifier)
            return
        }

        guard let service = peripheral.services?.first(where: { $0.uuid == Self.batteryServiceUUID }) else {
            markPeripheralFinished(peripheral.identifier)
            return
        }

        peripheral.discoverCharacteristics([Self.batteryCharacteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard state == .requesting else { return }

        if let error {
            print("🎧 [BluetoothLEBatteryReader] Characteristic discovery failed: \(error.localizedDescription)")
            markPeripheralFinished(peripheral.identifier)
            return
        }

        guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.batteryCharacteristicUUID }) else {
            markPeripheralFinished(peripheral.identifier)
            return
        }

        peripheral.readValue(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard state == .requesting else { return }

        defer { markPeripheralFinished(peripheral.identifier) }

        if let error {
            print("🎧 [BluetoothLEBatteryReader] Battery read failed: \(error.localizedDescription)")
            return
        }

        guard let data = characteristic.value, let byte = data.first, let lookup = lookupByUUID[peripheral.identifier] else {
            return
        }

        let level = Int(byte)
        results[peripheral.identifier] = Result(
            uuid: peripheral.identifier,
            level: level,
            addressKey: lookup.addressKey,
            nameKey: lookup.nameKey
        )
    }

    // MARK: - Helpers

    private func startRequest() {
        central.stopScan()

        let identifiers = Array(missingUUIDs)
        if !identifiers.isEmpty {
            let peripherals = central.retrievePeripherals(withIdentifiers: identifiers)
            for peripheral in peripherals {
                missingUUIDs.remove(peripheral.identifier)
                configurePeripheral(peripheral)
            }
        }

        let connectedPeripherals = central.retrieveConnectedPeripherals(withServices: [Self.batteryServiceUUID])
        for peripheral in connectedPeripherals where missingUUIDs.contains(peripheral.identifier) {
            missingUUIDs.remove(peripheral.identifier)
            configurePeripheral(peripheral)
        }

        if !missingUUIDs.isEmpty {
            central.scanForPeripherals(withServices: [Self.batteryServiceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }

        if pendingPeripherals.isEmpty && missingUUIDs.isEmpty {
            complete(with: Array(results.values))
            return
        }

        scheduleTimeout()
    }

    private func configurePeripheral(_ peripheral: CBPeripheral) {
        pendingPeripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self

        switch peripheral.state {
        case .connected:
            peripheral.discoverServices([Self.batteryServiceUUID])
        default:
            central.connect(peripheral, options: nil)
        }
    }

    private func markPeripheralFinished(_ identifier: UUID) {
        pendingPeripherals.removeValue(forKey: identifier)
        missingUUIDs.remove(identifier)

        if missingUUIDs.isEmpty {
            central.stopScan()
        }

        if pendingPeripherals.isEmpty && missingUUIDs.isEmpty {
            complete(with: Array(results.values))
        }
    }

    private func scheduleTimeout() {
        cancelTimeout()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.complete(with: Array(self.results.values))
        }
        timeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutInterval, execute: workItem)
    }

    private func cancelTimeout() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
    }

    private func complete(with results: [Result]) {
        guard state == .requesting else { return }
        cancelTimeout()
        central.stopScan()
        state = .idle

        pendingPeripherals.removeAll()
        missingUUIDs.removeAll()
        pendingLookups.removeAll()
        lookupByUUID.removeAll()

        let completion = self.completion
        self.completion = nil
        self.results.removeAll()

        completion?(results)
    }
}

// MARK: - Models

struct BluetoothAudioDevice: Identifiable {
    let id: UUID
    let name: String
    let address: String
    let batteryLevel: Int?  // 0-100, nil if not available
    let deviceType: BluetoothAudioDeviceType

    init(
        id: UUID = UUID(),
        name: String,
        address: String,
        batteryLevel: Int?,
        deviceType: BluetoothAudioDeviceType
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.batteryLevel = batteryLevel
        self.deviceType = deviceType
    }
}

extension BluetoothAudioDevice {
    func withBatteryLevel(_ batteryLevel: Int?) -> BluetoothAudioDevice {
        BluetoothAudioDevice(
            id: id,
            name: name,
            address: address,
            batteryLevel: batteryLevel,
            deviceType: deviceType
        )
    }
}

enum BluetoothAudioDeviceType {
    case airpods
    case airpodsGen3
    case airpodsGen4
    case airpodsPro
    case airpodsPro3
    case airpodsMax
    case beatsstudio
    case beatssolo
    case headphones
    case speaker
    case generic
    
    var sfSymbol: String {
        switch self {
        case .airpods:
            return "airpods"
        case .airpodsGen3:
            return "airpods.gen3"
        case .airpodsGen4:
            return "airpods.gen4"
        case .airpodsPro:
            return "airpods.pro"
        case .airpodsPro3:
            return "airpods.pro"
        case .airpodsMax:
            return "airpodsmax"
        case .beatsstudio:
            return "beats.headphones"
        case .beatssolo:
            return "beats.headphones"
        case .headphones:
            return "headphones"
        case .speaker:
            return "hifispeaker.fill"
        case .generic:
            return "bluetooth.circle.fill"
        }
    }
    
    var displayName: String {
        switch self {
        case .airpods: return "AirPods"
        case .airpodsGen3: return "AirPods (Gen 3)"
        case .airpodsGen4: return "AirPods (Gen 4)"
        case .airpodsPro: return "AirPods Pro"
        case .airpodsPro3: return "Airpods Pro 3"
        case .airpodsMax: return "AirPods Max"
        case .beatsstudio: return "Beats Studio"
        case .beatssolo: return "Beats Solo"
        case .headphones: return "Headphones"
        case .speaker: return "Speaker"
        case .generic: return "Bluetooth Device"
        }
    }

    /// Inline HUD only: base filename (no extension) for a looping .mov animation.
    /// Naming convention: add a resource named exactly like this value + ".mov" to the app bundle.
    /// Example: for `.airpodsPro`, add `airpodsPro.mov`.
    var inlineHUDAnimationBaseName: String {
        String(describing: self)
    }
}

fileprivate extension BluetoothAudioDeviceType {
    var isEarbudAirPodsPair: Bool {
        self == .airpods || self == .airpodsGen3 || self == .airpodsGen4 || self == .airpodsPro || self == .airpodsPro3
    }
    
    func pairSymbol() -> String {
        // Preferred pair symbols per model (with fallbacks for OS/SF Symbols variations)
        let candidates: [String]
        switch self {
        case .airpods:
            candidates = ["airpods"]
        case .airpodsGen3:
            candidates = ["airpods.gen3", "airpods"]
        case .airpodsGen4:
            candidates = ["airpods.gen4", "airpods"]
        case .airpodsPro:
            candidates = ["airpods.pro", "airpodspro", "airpods"]
        case .airpodsPro3:
            candidates = ["airpods.pro", "airpodspro", "airpods"]
        case .airpodsMax:
            candidates = ["airpodsmax", "airpods.max", "headphones"]
        default:
            candidates = [sfSymbol]
        }

        for name in candidates {
            if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
                return name
            }
        }
        return sfSymbol
    }
    
    func caseSymbol() -> String {
        // Exact names you requested (with fallback if symbol missing on this OS)
        let candidates: [String]
        switch self {
        case .airpodsPro:
            // AirPods Pro Gen 1 & Gen 2 → FILLED case icon
            candidates = [
                "airpods.pro.chargingcase.wireless.fill",
                "airpods.chargingcase.wireless.fill"
            ]

        case .airpodsPro3:
            // AirPods Pro Gen 3 → NON-FILLED case icon
            candidates = [
                "airpods.pro.chargingcase.wireless",
                "airpods.chargingcase.wireless"
            ]
        case .airpodsGen3:
            candidates = ["airpods.gen3.chargingcase.wireless.fill", "airpods.chargingcase.wireless.fill"]
        case .airpodsGen4:
            candidates = ["airpods.gen4.chargingcase.wireless.fill", "airpods.chargingcase.wireless.fill"]
        case .airpods:
            candidates = ["airpods.chargingcase.wireless.fill"]
        default:
            candidates = [sfSymbol]
        }

        for name in candidates {
            if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
                return name
            }
        }
        return sfSymbol
    }

    func earbudSymbol(for side: BluetoothAudioManager.AirPodSide) -> String {
        // AirPods Max is not a left/right earbud pair.
        guard self != .airpodsMax else { return sfSymbol }

        let suffix = (side == .left) ? ".left" : ".right"

        let candidate: String
        switch self {
        case .airpods:
            // Base AirPods: pair icon is "airpods", individual buds are "airpod.left/right"
            candidate = "airpod" + suffix
        case .airpodsGen3:
            // Gen 3: pair icon is "airpods.gen3", individual buds are "airpod.gen3.left/right"
            candidate = "airpod.gen3" + suffix
        case .airpodsGen4:
            // Gen 4: pair icon is "airpods.gen4", individual buds are "airpods.gen4.left/right"
            candidate = "airpods.gen4" + suffix
        case .airpodsPro:
            // Pro: pair icon is "airpods.pro", individual buds are "airpods.pro.left/right"
            candidate = "airpods.pro" + suffix
        case .airpodsPro3:
            // Pro: pair icon is "airpods.pro", individual buds are "airpods.pro.left/right"
            candidate = "airpods.pro" + suffix
        default:
            candidate = sfSymbol
        }

        // If the OS doesn't support this SF Symbol, fall back to the base symbol.
        #if canImport(AppKit)
        if NSImage(systemSymbolName: candidate, accessibilityDescription: nil) != nil {
            return candidate
        } else {
            return sfSymbol
        }
        #else
        return candidate
        #endif
    }
}

// MARK: - Notification Name Constants

private let IOBluetoothDeviceConnectionNotification = "IOBluetoothDeviceConnectionNotification"
private let IOBluetoothDeviceDisconnectionNotification = "IOBluetoothDeviceDisconnectionNotification"
