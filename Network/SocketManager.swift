//
//  SocketManager.swift
//  iLiDAR
//
//  Created by Bo Liang on 2024/12/8.
//



import Foundation

enum DataType: UInt8 {
    case jpg = 0x01
    case bin = 0x02
    case csv = 0x03
}

/*
 Data packet: [Header][Payload]
 
 In [Header]:
 [Filename length] 1 byte UInt8
 [Filename] Variable length
 [Data type] 1 byte UInt8
 [Data size] 4 bytes UInt32 big-endian
 [Sequence number] 4 bytes UInt32 big-endian
 [Is last chunk] 1 byte UInt8
 
 In [Payload] is Binary data
 */

struct DataPacket {
    let dataType: DataType
    let fileName: String
    let data: Data
    let sequenceNumber: UInt32
    let isLast: Bool
    
    func toData() -> Data {
        var packet = Data()
        
        if let fileNameData = fileName.data(using: .utf8) {
            let fileNameLength = UInt8(fileName.count)
            packet.append(fileNameLength)
            packet.append(fileNameData)
        } else {
            packet.append(UInt8(0)) // fail to encode fileName, send length 0
        }
        
        packet.append(dataType.rawValue)
        
        var dataSize = UInt32(data.count).bigEndian
        packet.append(Data(bytes: &dataSize, count: 4))
        
        var seqNum = sequenceNumber.bigEndian
        packet.append(Data(bytes: &seqNum, count: 4))
        
        if isLast {
            packet.append(UInt8(1))
        } else {
            packet.append(UInt8(0))
        }        
        
        packet.append(data)
        return packet
    }
}


class SocketManager {
    let socketHandler = CocoaAsyncSocketHandler()
    var onDisconnect: (() -> Void)?

    init() {
        // Configure response handling closure
        socketHandler.getResponseBlock = { response in
            print("Received server response: \(response)")
        }
        socketHandler.disconnectCallback = { [weak self] in
            DispatchQueue.main.async {
                self?.onDisconnect?()
            }
        }
    }
    
    func connectToServer(host_ip: String, port: Int, fingerprint: String, token: String,
                         completion: @escaping (Bool) -> Void) {
        // Set the completion block on the Objective-C side
        socketHandler.connectionCallback = { success in
            DispatchQueue.main.async {
                completion(success)
            }
        }
        
        socketHandler.setupSocketHost(host_ip, port: port, fingerprint: fingerprint, token: token)
    }
    
    func disconnect() {
        socketHandler.disconnect()
    }
    
    func currentConnectionID() -> UInt64 {
        return socketHandler.currentConnectionID()
    }

    func sendData(dataType: DataType, fileName: String, data: Data, connectionID: UInt64, chunkSize: Int = 1024) {
        let totalSize = data.count
        var offset = 0
        var sequenceNumber: UInt32 = 0
        
        while offset < totalSize {
            let thisChunkSize = min(chunkSize, totalSize - offset)
            let chunk = data.subdata(in: offset..<offset + thisChunkSize)
            let isLast = (offset + thisChunkSize) >= totalSize
            let packet = DataPacket (dataType: dataType, fileName: fileName, data: chunk, sequenceNumber: sequenceNumber, isLast: isLast)
            let packetData = packet.toData()
            guard socketHandler.sendMyData(packetData, connectionID: connectionID) else {
                print("Connection changed before transfer completed.")
                return
            }
            offset += thisChunkSize
            sequenceNumber += 1
        }
        
    }
    
    func sendJPG(fileName: String, data: Data, connectionID: UInt64, chunkSize: Int = 1024) {
        sendData(dataType: .jpg, fileName: fileName, data: data, connectionID: connectionID, chunkSize: chunkSize)
    }
    
    func sendBIN(fileName: String, data: Data, connectionID: UInt64, chunkSize: Int = 1024) {
        sendData(dataType: .bin, fileName: fileName, data: data, connectionID: connectionID, chunkSize: chunkSize)
    }
    
    func sendCSV(fileName: String, data: Data, connectionID: UInt64, chunkSize: Int = 1024) {
        sendData(dataType: .csv, fileName: fileName, data: data, connectionID: connectionID, chunkSize: chunkSize)
    }
    
    // MARK: - Real-time Visualization Support
    
    func sendRawData(_ data: Data, connectionID: UInt64) {
        // Send raw data without packet structure for real-time visualization
        if !socketHandler.sendMyData(data, connectionID: connectionID) {
            print("Connection changed before visualization data could be sent.")
        }
    }
}
