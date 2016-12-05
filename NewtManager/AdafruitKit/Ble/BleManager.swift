//
//  BleManager.swift
//  BleManager
//
//  Created by Antonio García on 13/10/2016.
//  Copyright © 2016 Adafruit. All rights reserved.
//

import Foundation
import CoreBluetooth
import MSWeakTimer

class BleManager: NSObject {
    // Configuration
    private static let kStopScanningWhenConnectingToPeripheral = false
    private static let kAlwaysAllowDuplicateKeys = false

    // Singleton
    static let sharedInstance = BleManager()
    
    // Ble
    var centralManager: CBCentralManager?
    fileprivate var centralManagerPoweredOnSemaphore = DispatchSemaphore(value: 1)
    
    // Scanning
    fileprivate var isScanning = false
    fileprivate var isScanningWaitingToStart = false
    fileprivate var scanningServicesFilter: [CBUUID]?
    fileprivate var peripheralsFound = [UUID: BlePeripheral]()
    fileprivate var peripheralsFoundLock = NSLock()

    // Connecting
    fileprivate var connectionTimeoutTimers = [UUID: MSWeakTimer]()
    
    // Notifications
    enum NotificationUserInfoKey: String {
        case uuid = "uuid"
    }
    
    override init() {
        super.init()

        centralManagerPoweredOnSemaphore.wait()
        centralManager = CBCentralManager(delegate: self, queue: DispatchQueue.global(qos: .background), options: [:])
    }
    
    // MARK: - Scan
    func startScan(withServices services: [CBUUID]? = nil) {
        centralManagerPoweredOnSemaphore.wait()
        centralManagerPoweredOnSemaphore.signal()
        
        guard let centralManager = centralManager, centralManager.state != .poweredOff && centralManager.state != .unauthorized && centralManager.state != .unsupported else {
            DLog("startScan failed because central manager is not ready")
            return
        }
        
        isScanningWaitingToStart = true
        scanningServicesFilter = services
        
        guard centralManager.state == .poweredOn else {
            return
        }
        
        isScanning = true
        NotificationCenter.default.post(name: .didStartScanning, object: nil)
        centralManager.scanForPeripherals(withServices: services, options: BleManager.kAlwaysAllowDuplicateKeys ? [CBCentralManagerScanOptionAllowDuplicatesKey: true] : nil)
    }
    
    func stopScan() {
        centralManager?.stopScan()
        isScanning = false
        isScanningWaitingToStart = false
        NotificationCenter.default.post(name: .didStopScanning, object: nil)
    }
    
    func peripherals() -> [BlePeripheral] {
        peripheralsFoundLock.lock() ; defer { peripheralsFoundLock.unlock() }
        return Array(peripheralsFound.values)
    }
    
    func refreshPeripherals() {
        stopScan()
        
        peripheralsFoundLock.lock()
        // Don't remove connnected or connecting peripherals
        for (identifier, peripheral) in peripheralsFound {
            if peripheral.state != .connected && peripheral.state != .connecting {
                peripheralsFound.removeValue(forKey: identifier)
            }
        }
        peripheralsFoundLock.unlock()
        
        NotificationCenter.default.post(name: .didUnDiscoverPeripheral, object: nil)
        startScan(withServices: scanningServicesFilter)
    }
    
    
    // MARK: - Connection Management
    func connect(to peripheral: BlePeripheral, timeout: TimeInterval? = nil, shouldNotifyOnConnection: Bool = false, shouldNotifyOnDisconnection: Bool = false, shouldNotifyOnNotification: Bool = false) {
        
        centralManagerPoweredOnSemaphore.wait()
        centralManagerPoweredOnSemaphore.signal()
        
        // Stop scanning when connecting to a peripheral 
        if BleManager.kStopScanningWhenConnectingToPeripheral {
            stopScan()
        }
        
        // Connect
        NotificationCenter.default.post(name: .willConnectToPeripheral, object: nil, userInfo: [NotificationUserInfoKey.uuid.rawValue: peripheral.identifier])
        
        //DLog("connect")
        var options: [String: Bool]?
        if shouldNotifyOnConnection || shouldNotifyOnDisconnection || shouldNotifyOnDisconnection {
            options = [CBConnectPeripheralOptionNotifyOnConnectionKey: shouldNotifyOnConnection, CBConnectPeripheralOptionNotifyOnDisconnectionKey: shouldNotifyOnDisconnection, CBConnectPeripheralOptionNotifyOnNotificationKey: shouldNotifyOnDisconnection]
        }
        
        if let timeout = timeout {
            connectionTimeoutTimers[peripheral.identifier] = MSWeakTimer.scheduledTimer(withTimeInterval: timeout, target: self, selector: #selector(connectionTimeoutFired), userInfo: peripheral.identifier, repeats: false, dispatchQueue: .global(qos: .background))
        }
        centralManager?.connect(peripheral.peripheral, options: options)
    }
    
    @objc func connectionTimeoutFired(timer: MSWeakTimer) {
        let peripheralIdentifier = timer.userInfo() as! UUID
        DLog("connection timeout fired: \(peripheralIdentifier)")
        connectionTimeoutTimers[peripheralIdentifier] = nil
        
        NotificationCenter.default.post(name: .willDisconnectFromPeripheral, object: nil, userInfo: [NotificationUserInfoKey.uuid.rawValue: peripheralIdentifier])

        if let blePeripheral = peripheralsFound[peripheralIdentifier] {
            centralManager?.cancelPeripheralConnection(blePeripheral.peripheral)
        }
        else {
            DLog("simulate disconnection")
            // The blePeripheral is available on peripheralsFound, so simulate the disconnection
            NotificationCenter.default.post(name: .didDisconnectFromPeripheral, object: nil, userInfo: [NotificationUserInfoKey.uuid.rawValue: peripheralIdentifier])
            
        }
    }
    
    func disconnect(from peripheral: BlePeripheral) {
        
        DLog("disconnect")
        NotificationCenter.default.post(name: .willDisconnectFromPeripheral, object: nil, userInfo: [NotificationUserInfoKey.uuid.rawValue: peripheral.identifier])
        centralManager?.cancelPeripheralConnection(peripheral.peripheral)
    }

    func reconnecToPeripherals(withIdentifiers identifiers: [UUID], withServices services: [CBUUID], timeout: Double? = nil) -> Bool {
        var reconnecting = false
        
        let knownPeripherals = centralManager?.retrievePeripherals(withIdentifiers: identifiers)
        if let peripherals = knownPeripherals?.filter({identifiers.contains($0.identifier)}) {
            for peripheral in peripherals {
                discovered(peripheral: peripheral)
                if let blePeripheral = peripheralsFound[peripheral.identifier] {
                    connect(to: blePeripheral, timeout: timeout)
                    reconnecting = true
                }
            }
        }
        else {
            let connectedPeripherals =  centralManager?.retrieveConnectedPeripherals(withServices: services)
            if let peripherals = connectedPeripherals?.filter({identifiers.contains($0.identifier)}) {
                for peripheral in peripherals {
                    discovered(peripheral: peripheral)
                    if let blePeripheral = peripheralsFound[peripheral.identifier] {
                        connect(to: blePeripheral, timeout: timeout)
                        reconnecting = true
                    }
                }
            }
        }
        
        return reconnecting
    }
    
    fileprivate func discovered(peripheral: CBPeripheral, advertisementData: [String: Any]? = nil, rssi: Int? = nil) {
        if let existingPeripheral = peripheralsFound[peripheral.identifier] {
            existingPeripheral.lastSeenTime = CFAbsoluteTimeGetCurrent()
            existingPeripheral.rssi = rssi
            if let advertisementData = advertisementData {
                for (key, value) in advertisementData {
                    existingPeripheral.advertisementData.updateValue(value, forKey: key);
                }
            }
            peripheralsFound[peripheral.identifier] = existingPeripheral
        }
        else {      // New peripheral found
            let peripheral = BlePeripheral(peripheral: peripheral, advertisementData: advertisementData, rssi: rssi)
            peripheralsFound[peripheral.identifier] = peripheral
        }
    }
    
    // MARK:- Notifications
    func peripheral(from notification: Notification) -> BlePeripheral? {
        
        guard let uuid = notification.userInfo?[NotificationUserInfoKey.uuid.rawValue] as? UUID else {
            return nil
        }
        
        return peripheral(with: uuid)
    }
    
    func peripheral(with uuid: UUID) -> BlePeripheral? {
        return peripheralsFound[uuid]
    }
}

// MARK: - CBCentralManagerDelegate
extension BleManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        
        // Unlock state lock if we have a known state
        if central.state == .poweredOn || central.state == .poweredOff || central.state == .unsupported || central.state == .unauthorized {
            centralManagerPoweredOnSemaphore.signal()
        }
        
        // Scanning
        if central.state == .poweredOn {

            if (isScanningWaitingToStart) {
                startScan(withServices: scanningServicesFilter)        // Continue scanning now that bluetooth is back
            }
        }
        else {
            isScanning = false
        }
        
        NotificationCenter.default.post(name: .didUpdateBleState, object: nil)
    }

    /*
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        
    }*/
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {

        discovered(peripheral: peripheral, advertisementData: advertisementData, rssi: RSSI.intValue)
        
        NotificationCenter.default.post(name: .didDiscoverPeripheral, object: nil, userInfo: [NotificationUserInfoKey.uuid.rawValue: peripheral.identifier])
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        DLog("didConnect")
        
        // Remove connection timeout if exists
        if let timer = connectionTimeoutTimers[peripheral.identifier] {
            timer.invalidate()
            connectionTimeoutTimers[peripheral.identifier] = nil
        }
        
        // Send notification
        NotificationCenter.default.post(name: .didConnectToPeripheral, object: nil, userInfo: [NotificationUserInfoKey.uuid.rawValue: peripheral.identifier])
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        DLog("didFailToConnect")

        NotificationCenter.default.post(name: .didDisconnectFromPeripheral, object: nil, userInfo: [NotificationUserInfoKey.uuid.rawValue: peripheral.identifier])
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        DLog("didDisconnectPeripheral")

        // Clean
        peripheralsFound[peripheral.identifier]?.disconnected()

        // Notify
        NotificationCenter.default.post(name: .didDisconnectFromPeripheral, object: nil, userInfo: [NotificationUserInfoKey.uuid.rawValue: peripheral.identifier])
        
        // Remove from peripheral list (after sending notification so the receiving objects can query about the peripheral before being removed)
        peripheralsFoundLock.lock()
        peripheralsFound.removeValue(forKey: peripheral.identifier)
        peripheralsFoundLock.unlock()
    }
}

// MARK: - Custom Notifications
extension Notification.Name {
    private static let kPrefix = Bundle.main.bundleIdentifier!
    static let didUpdateBleState = Notification.Name(kPrefix+".didUpdateBleState")
    static let didStartScanning = Notification.Name(kPrefix+".didStartScanning")
    static let didStopScanning = Notification.Name(kPrefix+".didStopScanning")
    static let didDiscoverPeripheral = Notification.Name(kPrefix+".didDiscoverPeripheral")
    static let didUnDiscoverPeripheral = Notification.Name(kPrefix+".didUnDiscoverPeripheral")
    static let willConnectToPeripheral = Notification.Name(kPrefix+".willConnectToPeripheral")
    static let didConnectToPeripheral = Notification.Name(kPrefix+".didConnectToPeripheral")
    static let willDisconnectFromPeripheral = Notification.Name(kPrefix+".willDisconnectFromPeripheral")
    static let didDisconnectFromPeripheral = Notification.Name(kPrefix+".didDisconnectFromPeripheral")
}
