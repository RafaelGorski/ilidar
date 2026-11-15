//
//  DataStorage.swift
//  iLiDAR
//
//  Created by Bo Liang on 2024/12/5.
//

import Foundation
import AVFoundation
import UIKit

extension Notification.Name {
    static let serverDisconnected = Notification.Name("iLiDARServerDisconnected")
}

class DataStorage {
    static let shared = DataStorage()
    
    let socketManager = SocketManager()
    let compressionQuality: CGFloat = 0.4
    var readyToSend: Bool = false
    
    // 添加缓存机制
    private var lastTransmittedFrame: String = ""
    private var frameCache: [String: Data] = [:]
    private let maxCacheSize = 10
    
    private(set) var currentHostIP = ""
    private(set) var currentPort = 5678

    init() {
        socketManager.onDisconnect = { [weak self] in
            self?.readyToSend = false
            NotificationCenter.default.post(name: .serverDisconnected, object: nil)
        }
    }
    
    func disconnect() {
        socketManager.disconnect()
        readyToSend = false
    }
    
    
    func updateConnection(host_ip: String, port: Int, fingerprint: String, token: String,
                          completion: @escaping (Bool) -> Void) {
        // Disconnect existing connection
        socketManager.disconnect()
        readyToSend = false
        
        // Update current IP and port
        currentHostIP = host_ip
        currentPort = port
        
        var completionCalled = false
        
        let timer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
            guard let self = self, !completionCalled else { return }
            self.readyToSend = false
            completionCalled = true
            self.socketManager.disconnect()
            print("Connection to \(host_ip):\(port) timed out.")
            completion(false)
        }

        // Attempt to connect with the new settings
        socketManager.connectToServer(host_ip: host_ip, port: port, fingerprint: fingerprint, token: token) { success in
            guard !completionCalled else { return }
            timer.invalidate()
            completionCalled = true
            if success {
                self.readyToSend = true
                print("Ready to send data with new connection settings.")
                completion(true)
            } else {
                self.readyToSend = false
                print("Failed to connect to the server at \(host_ip):\(port).")
                completion(false)
            }
        }
    }


    
    func convertDepthData(depthData: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(depthData, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthData, .readOnly)
        }
        
        let width = CVPixelBufferGetWidth(depthData)
        let height = CVPixelBufferGetHeight(depthData)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthData)
        let float16Size = MemoryLayout<Float16>.size // expected to be 16 bits
        let rowBytes = width * float16Size
        assert(rowBytes <= bytesPerRow, "Unexpected pixel buffer layout.")
        let totalBytes = rowBytes * height
        
        var data = Data(count: totalBytes)
        // Get a pointer to the start of the data
        data.withUnsafeMutableBytes { mutableBytes in
            guard let basePointer = mutableBytes.bindMemory(to: UInt8.self).baseAddress else {
                print("Failed to bind memory to UInt8.")
                return
            }
            
            var currentOffset = 0
            guard let rowPointerBase = CVPixelBufferGetBaseAddressOfPlane(depthData, 0) else {
                print("Failed to get base address of plane 0.")
                return
            }
            
            // Iterate over each row
            for y in 0..<height {
                let rowPointer = rowPointerBase.advanced(by: y * bytesPerRow)
                let rowBytes = min(bytesPerRow, width * float16Size)
                memcpy(basePointer + currentOffset, rowPointer, rowBytes)
                currentOffset += width * float16Size
            }
        }
        return data
    }
    
    func transmitFrame(imageData: CVImageBuffer, depthData: CVPixelBuffer, fileName: String) {
        let connectionID = socketManager.currentConnectionID()
        if !readyToSend || connectionID == 0 {
            print("Fail to establish socket for data transmission.")
            return
        }
        
        // 使用后台队列进行数据转换，避免阻塞主线程
        DispatchQueue.global(qos: .userInitiated).async {
            // 创建共享的CIContext以提高效率
            let context = CIContext(options: [.useSoftwareRenderer: false])
            
            let ciImage = CIImage(cvImageBuffer: imageData)
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
                print("Error converting CVImageBuffer to JPEG data.")
                return
            }
            let uiImage = UIImage(cgImage: cgImage)
            // compress the figure for better transmission
            guard let jpegData = uiImage.jpegData(compressionQuality: self.compressionQuality) else {
                print("Error converting UIImage to JPEG data.")
                return
            }
            
            if let transmitDepth = self.convertDepthData(depthData: depthData) {
                self.socketManager.sendBIN(fileName: fileName + ".bin", data: transmitDepth, connectionID: connectionID)
                
            } else {
                print("Fail to convert depth data.")
            }
            self.socketManager.sendJPG(fileName: fileName + ".jpg", data: jpegData, connectionID: connectionID)
        }
    }
    
    // MARK: - Real-time Depth Visualization Support
    
    func transmitDepthForVisualization(depthData: CVPixelBuffer) {
        let connectionID = socketManager.currentConnectionID()
        if !readyToSend || connectionID == 0 {
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            guard let depthDataRaw = self.convertDepthData(depthData: depthData) else {
                print("Failed to convert depth data for visualization")
                return
            }
            
            // Create data packet: size (4 bytes) + depth data
            var packet = Data()
            
            // Add data size (4 bytes, big-endian)
            let dataSize = UInt32(depthDataRaw.count)
            let sizeBytes = withUnsafeBytes(of: dataSize.bigEndian) { Data($0) }
            packet.append(sizeBytes)
            
            // Add depth data
            packet.append(depthDataRaw)
            
            // Send the packet
            self.socketManager.sendRawData(packet, connectionID: connectionID)
        }
    }
    
    func transmitConfig(calibrationData: AVCameraCalibrationData, fileName: String) {
        let connectionID = socketManager.currentConnectionID()
        if !readyToSend || connectionID == 0 {
            print("Fail to establish socket for data transmission.")
            return
        }
        
        let intrinsicMatrix = calibrationData.intrinsicMatrix
        print(intrinsicMatrix)
        let fx = intrinsicMatrix.columns.0.x
        let fy = intrinsicMatrix.columns.1.y
        let cx = intrinsicMatrix.columns.2.x
        let cy = intrinsicMatrix.columns.2.y
        
        var csvContent = "fx,fy,cx,cy\n"
        csvContent += "\(fx),\(fy),\(cx),\(cy)\n"
        
        if let csvData = csvContent.data(using: .utf8) {
            socketManager.sendCSV(fileName: fileName  + ".csv", data: csvData, connectionID: connectionID)
        } else {
            print("Fail to convert CSV content to Data")
        }
    }
    
    func frameName(frameCounter: Int) -> String {
        // call this function to record the timestamp of each frame
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss_SS"
        let timestamp = dateFormatter.string(from: Date())
        
        return timestamp + "_" + String(format: "frame%08d", frameCounter)
    }
    
    func eventName() -> String {
        // only call this once when the camera starts
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        return timestamp
    }
    
}
