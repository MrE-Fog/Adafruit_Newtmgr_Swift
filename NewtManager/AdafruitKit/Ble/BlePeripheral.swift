//
//  Peripheral.swift
//  NewtManager
//
//  Created by Antonio García on 12/09/2016.
//  Copyright © 2016 Adafruit. All rights reserved.
//

import Foundation
import CoreBluetooth
import MSWeakTimer

class BlePeripheral: NSObject {
    // Config
    fileprivate static var kProfileCharacteristicUpdates = true
    
    // Data
    var peripheral: CBPeripheral!
    var advertisementData: [String: Any]!
    var rssi: Int?
    var lastSeenTime: CFAbsoluteTime!
    
    var identifier: UUID {
        return peripheral.identifier
    }
    
    var name: String? {
        return peripheral.name
    }

    var state: CBPeripheralState {
        return peripheral.state
    }
    
    typealias CapturedReadCompletionHandler = ((_ data: Any?, _ error: Error?) -> Void)
    fileprivate class CaptureReadHandler {

        var identifier: String
        var result: CapturedReadCompletionHandler
        var timeoutTimer: MSWeakTimer?
        var isNotifyOmitted: Bool
        
        init(identifier: String, result: @escaping CapturedReadCompletionHandler, timeout: Double?, isNotifyOmitted: Bool = false) {
            self.identifier = identifier
            self.result = result
            self.isNotifyOmitted = isNotifyOmitted
            
            if let timeout = timeout {
                timeoutTimer = MSWeakTimer.scheduledTimer(withTimeInterval: timeout, target: self, selector: #selector(timerFired), userInfo: nil, repeats: false, dispatchQueue: DispatchQueue.global(qos: .background))
            }
        }
        
        @objc func timerFired() {
            timeoutTimer = nil
            result(nil, UartError.timeout)
        }
    }
    
    // Internal data
    fileprivate var notifyHandlers = [String: ((Error?) -> Void)]()                 // Nofify handlers for each service-characteristic
    fileprivate var captureReadHandlers = [CaptureReadHandler]()
    fileprivate var commandQueue = CommandQueue<BleCommand>()

    // Profiling
    //fileprivate var profileStartTime: CFTimeInterval = 0
    
    
    init(peripheral: CBPeripheral, advertisementData: [String: Any]?, rssi: Int?) {
        super.init()
        
        self.peripheral = peripheral
        self.peripheral.delegate = self
        self.advertisementData = advertisementData ?? [String: Any]()
        self.rssi = rssi
        self.lastSeenTime = CFAbsoluteTimeGetCurrent()
        
        commandQueue.executeHandler = executeCommand
    }
    
    deinit {
        DLog("peripheral deinit")
    }
    
    func disconnected() {
        rssi = nil
        notifyHandlers.removeAll()
        captureReadHandlers.removeAll()
        commandQueue.removeAll()
    }
    
    // MARK: - Discover
    func discover(serviceUuids: [CBUUID]?, completion: ((Error?) -> Void)?) {
        let command = BleCommand(type: .discoverService, parameters: serviceUuids, completion: completion)
        commandQueue.append(command)
    }

    func discover(characteristicUuids: [CBUUID]?, service: CBService, completion: ((Error?) -> Void)?) {
        let command = BleCommand(type: .discoverCharacteristic, parameters: [characteristicUuids as Any, service], completion: completion)
        commandQueue.append(command)
    }
    
    func discover(characteristicUuids: [CBUUID]?, serviceUuid: CBUUID, completion: ((Error?) -> Void)?) {
        // Discover service
        discover(serviceUuids: [serviceUuid]) { [unowned self] error in
            guard error == nil else {
                completion?(error)
                return
            }

            guard let service = self.peripheral.services?.first(where: {$0.uuid == serviceUuid}) else {
                completion?(BleCommand.CommandError.invalidService)
                return
            }
            
            // Discover characteristic
            self.discover(characteristicUuids: characteristicUuids, service: service, completion: completion)
        }
    }
    
    // MARK: - Service
    func discoveredService(uuid: CBUUID) -> CBService? {
        let service = peripheral.services?.first(where: {$0.uuid == uuid})
        return service
    }
    
    func service(uuid: CBUUID, completion: ((CBService?, Error?) -> Void)?) {
        
        if let discoveredService = discoveredService(uuid: uuid) {                      // Service was already discovered
            completion?(discoveredService, nil)
        }
        else {
            discover(serviceUuids: [uuid], completion: { [unowned self] (error) in      // Discover service
                var discoveredService: CBService?
                if error == nil {
                    discoveredService = self.discoveredService(uuid: uuid)
                }
                completion?(discoveredService, error)
            })
        }
    }
    
    // MARK: - Characteristic
    func discoveredCharacteristic(uuid: CBUUID, service: CBService) -> CBCharacteristic? {
        let characteristic = service.characteristics?.first(where: {$0.uuid == uuid})
        return characteristic
    }
    
    func characteristic(uuid: CBUUID, service: CBService, completion: ((CBCharacteristic?, Error?) -> Void)?) {
        
        if let discoveredCharacteristic = discoveredCharacteristic(uuid: uuid, service: service) {              // Characteristic was already discovered
            completion?(discoveredCharacteristic, nil)
        }
        else {
            discover(characteristicUuids: [uuid], service: service, completion: { [unowned self] (error) in     // Discover characteristic
                var discoveredCharacteristic: CBCharacteristic?
                if error == nil {
                    discoveredCharacteristic = self.discoveredCharacteristic(uuid: uuid, service: service)
                }
                completion?(discoveredCharacteristic, error)
            })
        }
    }
    
    func characteristic(uuid: CBUUID, serviceUuid: CBUUID, completion: ((CBCharacteristic?, Error?) -> Void)?) {
        if let discoveredService = discoveredService(uuid: uuid) {                                              // Service was already discovered
            characteristic(uuid: uuid, service: discoveredService, completion: completion)
        }
        else {                                                                                                  // Discover service
            service(uuid: serviceUuid) { (service, error) in
                if let service = service, error == nil {                                                        // Discover characteristic
                    self.characteristic(uuid: uuid, service: service, completion: completion)
                }
                else {
                    completion?(nil, error != nil ? error:BleCommand.CommandError.invalidService)
                }
            }
        }
    }
    
    func setNotify(for characteristic: CBCharacteristic, enabled: Bool, handler: ((Error?) -> Void)? = nil, completion: ((Error?) -> Void)? = nil) {
        let command = BleCommand(type: .setNotify, parameters: [characteristic, enabled, handler as Any], completion: completion)
        commandQueue.append(command)
    }
    
    func read(data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType, completion: ((Error?) -> Void)? = nil) {
        let command = BleCommand(type: .readCharacteristic, parameters: [characteristic], completion: completion)
        commandQueue.append(command)
    }
    
    func write(data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType, completion: ((Error?) -> Void)? = nil) {
        let command = BleCommand(type: .writeCharacteristic, parameters: [characteristic, type, data], completion: completion)
        commandQueue.append(command)
    }

    func writeAndCaptureNotify(data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType, writeCompletion: ((Error?) -> Void)? = nil, readCharacteristic: CBCharacteristic, readTimeout: Double? = nil, readCompletion: CapturedReadCompletionHandler? = nil) {
        let command = BleCommand(type: .writeCharacteristicAndWaitNofity, parameters: [characteristic, type, data, readCharacteristic, readCompletion as Any, readTimeout as Any], timeout: readTimeout, completion: writeCompletion)
        commandQueue.append(command)
    }
    
    // MARK: - Command Queue
    fileprivate class BleCommand: Equatable {
        enum CommandType {
            case discoverService
            case discoverCharacteristic
            case setNotify
            case readCharacteristic
            case writeCharacteristic
            case writeCharacteristicAndWaitNofity
        }

        enum CommandError: Error {
            case invalidService
        }
        
        var type: CommandType
        var parameters: [Any]?
        var completion: ((Error?) -> Void)?
        var isCancelled = false
        
        init(type: CommandType, parameters: [Any]?, timeout: Double? = nil, completion: ((Error?) -> Void)?) {
            self.type = type
            self.parameters = parameters
            self.completion = completion
        }
        
        func endExecution(withError error: Error?) {
            completion?(error)
        }
        
        static func == (left: BleCommand, right: BleCommand) -> Bool {
            return left.type == right.type
        }
    }
    
    private func executeCommand(command: BleCommand) {

        switch command.type {
        case .discoverService:
            discoverService(with: command)
        case .discoverCharacteristic:
            discoverCharacteristic(with: command)
        case .setNotify:
            setNotify(with: command)
        case .readCharacteristic:
            read(with: command)
        case .writeCharacteristic, .writeCharacteristicAndWaitNofity:
            write(with: command)
        }
    }
 
    fileprivate func handlerIdentifier(from characteristic: CBCharacteristic) -> String {
        return "\(characteristic.service.uuid.uuidString)-\(characteristic.uuid.uuidString)"
    }

    fileprivate func finishedExecutingCommand(error: Error?) {
        // Result Callback
        if let command = commandQueue.first(), !command.isCancelled {
            command.endExecution(withError: error)
            commandQueue.next()
        }
    }
    
    // MARK: - Commands
    private func discoverService(with command: BleCommand) {
        var serviceUuids = command.parameters as? [CBUUID]
        let discoverAll = serviceUuids == nil
        
        // Remove services already discovered from the query
        if let services = peripheral.services, let serviceUuidsToDiscover = serviceUuids {
            for (i, serviceUuid) in serviceUuidsToDiscover.enumerated().reversed() {
                if !services.contains(where: {$0.uuid == serviceUuid}) {
                    serviceUuids!.remove(at: i)
                }
            }
        }
        
        // Discover remaining uuids
        if discoverAll || serviceUuids != nil {
            peripheral.discoverServices(serviceUuids)
        }
        else {
            // Everthing was already discovered
            finishedExecutingCommand(error: nil)
        }
    }
    
    private func discoverCharacteristic(with command: BleCommand) {
        var characteristicUuids = command.parameters![0] as? [CBUUID]
        let discoverAll = characteristicUuids == nil
        let service = command.parameters![1] as! CBService
        
        // Remove services already discovered from the query
        if let characteristics = service.characteristics, let characteristicUuidsToDiscover = characteristicUuids {
            for (i, characteristicUuid) in characteristicUuidsToDiscover.enumerated().reversed() {
                if !characteristics.contains(where: {$0.uuid == characteristicUuid}) {
                    characteristicUuids!.remove(at: i)
                }
            }
        }
        
        // Discover remaining uuids
        if discoverAll || characteristicUuids != nil {
            peripheral.discoverCharacteristics(characteristicUuids, for: service)
        }
        else {
            // Everthing was already discovered
            finishedExecutingCommand(error: nil)
        }
    }
    
    private func setNotify(with command: BleCommand) {
        let characteristic = command.parameters![0] as! CBCharacteristic
        let enabled = command.parameters![1] as! Bool
        let handler = command.parameters![2] as? ((Error?) -> Void)
        let identifier = handlerIdentifier(from: characteristic)
        if enabled {
            notifyHandlers[identifier] = handler
        }
        else {
            notifyHandlers.removeValue(forKey: identifier)
        }
        peripheral.setNotifyValue(enabled, for: characteristic)
    }
    
    private func read(with command: BleCommand) {
        let characteristic = command.parameters!.first as! CBCharacteristic
        peripheral.readValue(for: characteristic)
    }
    
    private func write(with command: BleCommand) {
        let characteristic = command.parameters![0] as! CBCharacteristic
        let writeType = command.parameters![1] as! CBCharacteristicWriteType
        let data = command.parameters![2] as! Data
        
        peripheral.writeValue(data, for: characteristic, type: writeType)
    }
}

extension BlePeripheral: CBPeripheralDelegate {
    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
         DLog("peripheralDidUpdateName: \(name ?? "")")
    }
    
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        DLog("didModifyServices")
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        finishedExecutingCommand(error: error)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        finishedExecutingCommand(error: error)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        finishedExecutingCommand(error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        
        let identifier = handlerIdentifier(from: characteristic)
        
        /*
        if (BlePeripheral.kProfileCharacteristicUpdates) {
            let currentTime = CACurrentMediaTime()
            let elapsedTime = currentTime - profileStartTime
            DLog("elapsed: \(String(format: "%.1f", elapsedTime * 1000))")
            profileStartTime = currentTime
        }
 */
        //DLog("didUpdateValueFor \(characteristic.uuid.uuidString): \(String(data: characteristic.value ?? Data(), encoding: .utf8) ?? "<invalid>")")

        // Check if waiting to capture this read
        var isNotifyOmmited = false
        if captureReadHandlers.count > 0, let index = captureReadHandlers.index(where: {$0.identifier == identifier}) {

           // DLog("captureReadHandlers index: \(index) / \(captureReadHandlers.count)")

            // Remove capture handler
            let captureReadHandler = captureReadHandlers.remove(at: index)

          //  DLog("captureReadHandlers postRemove count: \(captureReadHandlers.count)")

            // Send result
            captureReadHandler.timeoutTimer?.invalidate()
            captureReadHandler.timeoutTimer = nil
            let value = characteristic.value
          //  DLog("updated value: \(String(data: value!, encoding: .utf8)!)")
            captureReadHandler.result(value, error)
            
            isNotifyOmmited = captureReadHandler.isNotifyOmitted
        }
            
        // Notify
        if !isNotifyOmmited {
            if let notifyHandler = notifyHandlers[identifier] {
                
                //let currentTime = CACurrentMediaTime()
                notifyHandler(error)
                //DLog("elapsed: \(String(format: "%.1f", (CACurrentMediaTime() - currentTime) * 1000))")
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let command = commandQueue.first(), !command.isCancelled, command.type == .writeCharacteristicAndWaitNofity {
            let characteristic = command.parameters![3] as! CBCharacteristic
            let readCompletion = command.parameters![4] as! CapturedReadCompletionHandler
            let timeout = command.parameters![5] as? Double
            let identifier = handlerIdentifier(from: characteristic)
            
            //DLog("read timeout started")
            let captureReadHandler = CaptureReadHandler(identifier: identifier, result: readCompletion, timeout: timeout)
            captureReadHandlers.append(captureReadHandler)
        }

        finishedExecutingCommand(error: error)
    }
}
