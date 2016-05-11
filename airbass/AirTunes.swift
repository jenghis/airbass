/*
 * Copyright 2016 Jenghis, LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Cocoa
import AudioToolbox

final class Track: NSObject {
    dynamic var name = ""
    dynamic var album = ""
    dynamic var artist = ""
    dynamic var position = -1.0
    dynamic var duration = -1.0
    dynamic var artwork = NSImage()
    dynamic var playing = false
}

final class AirTunes: NSObject, GCDAsyncSocketDelegate, GCDAsyncUdpSocketDelegate {

    // MARK: Internal Classes

    private class PlayerState {
        var queue: AudioQueueRef = nil
        var buffers = [AudioQueueBufferRef]()
        var packets = [Packet](count: 1024, repeatedValue: Packet())
        var packetsRead = Int64(0)
        var packetsWritten = Int64(0)
        var queueTime = UInt32(0)
        var sessionTime = UInt32(0)
    }

    private class Packet {
        var data = NSData()
        var index = UInt16(0)
        var timeStamp = UInt32(0)
    }

    // MARK: Instance Variables

    private var service = NSNetService()
    private var tcpSockets = [GCDAsyncSocket]()
    private var udpSockets = [GCDAsyncUdpSocket]()
    private var address = NSData()
    private var lastSequenceNumber = -1

    private var remote = AirTunesRemote()
    private var playerState = PlayerState()
    private var aesKey = NSData()
    private var aesIV = NSData()

    private let processQueue = dispatch_queue_create("processQueue", nil)
    private var callbackQueue = dispatch_queue_create("callbackQueue", nil)

    var track = Track()

    // MARK: Main Functions

    func start() {
        var txtRecord = [String: NSData]()
        let txtFields = ["et": "1", "sf": "0x4", "tp": "UDP", "vn": "3", "cn": "1", "md": "0,1,2"]

        txtFields.forEach({txtRecord[$0.0] = $0.1.dataUsingEncoding(NSUTF8StringEncoding)})

        do {
            let tcpQueue = dispatch_queue_create("tcpQueue", nil)
            let socket = GCDAsyncSocket(delegate: self, delegateQueue: tcpQueue)
            tcpSockets.append(socket)
            try socket.acceptOnPort(5001)
        } catch {}

        let name = getMacAddress().reduce("", combine: {$0 + String(format: "%02X", $1)}) + "@AirBass"

        service = NSNetService(domain: "", type: "_raop._tcp.", name: name, port: 5001)
        service.setTXTRecordData(NSNetService.dataFromTXTRecordDictionary(txtRecord))
        service.publish()

        // AirTunes output format doesn't change
        var format = AudioStreamBasicDescription()
        format.mSampleRate = 44100
        format.mFormatID = kAudioFormatAppleLossless
        format.mFramesPerPacket = 352
        format.mChannelsPerFrame = 2

        AudioQueueNewOutputWithDispatchQueue(&playerState.queue, &format, 0, callbackQueue) {
            (aq, buffer) in self.outputCallback(self.playerState, aq: aq, buffer: buffer)
        }

        // Magic cookie doesn't change
        var cookie = [UInt8]()
        cookie = [0, 0, 1, 96, 0, 16, 40, 10, 14, 2, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 172, 68]
        AudioQueueSetProperty(playerState.queue, kAudioQueueProperty_MagicCookie, &cookie, 24)

        // Three buffers is recommended
        while playerState.buffers.count < 3 {
            var buffer: AudioQueueBufferRef = nil
            // Buffer fits at least one packet of the max possible size
            AudioQueueAllocateBufferWithPacketDescriptions(playerState.queue, 1536, 48, &buffer)
            playerState.buffers.append(buffer)
        }
    }

    private func parseRtspData(data: NSData, fromSocket sock: GCDAsyncSocket!) {
        let request = String(data: data, encoding: NSUTF8StringEncoding) ?? String()
        var headerFields = [String: String]()
        var requestType = ""
        var response = ["RTSP/1.0 200 OK"]

        // Get header fields
        request.componentsSeparatedByString("\r\n").forEach() {
            let field = $0.componentsSeparatedByString(": ")

            // Get request type
            if field.count == 1 && requestType == "" {
                for character in field[0].characters {
                    if character == " " {
                        break
                    }

                    requestType.append(character)
                }
            }
            else if field.count == 2 {
                headerFields[field[0]] = field[1]
            }
        }

        // Handle session control flow
        switch requestType {
        case "OPTIONS":
            if let appleChallenge = headerFields["Apple-Challenge"] {
                let paddedChallenge = padBase64String(appleChallenge)
                let appleResponse = respondToChallenge(paddedChallenge, fromSocket: sock)
                response += ["Apple-Response: \(appleResponse)"]
            }
        case "SETUP":
            response += ["Transport: RTP/AVP/UDP;server_port=6010;control_port=6011"]
            response += ["Session: 1"]
            createSessionSockets()
            track.playing = true
        case "RECORD":
            fallthrough
        case "FLUSH":
            resetAudioQueue()
            if let rtpInfo = headerFields["RTP-Info"] {
                getCurrentSequenceNumber(rtpInfo)
            }
        case "TEARDOWN":
            resetTrackInfo()
        default:
            break
        }

        // Handle audio metadata
        if let contentType = headerFields["Content-Type"] {
            // Defaults to 0 if unwrapping fails
            let contentLength = UInt(headerFields["Content-Length"] ?? "0") ?? 0

            switch contentType {
            case "application/sdp":
                sock.readDataToLength(contentLength, withTimeout: 5, tag: 1)
            case "image/jpeg":
                sock.readDataToLength(contentLength, withTimeout: 5, tag: 2)
            case "text/parameters":
                sock.readDataToLength(contentLength, withTimeout: 5, tag: 3)
            case "application/x-dmap-tagged":
                sock.readDataToLength(contentLength, withTimeout: 5, tag: 4)
            default:
                break
            }
        }

        if let activeRemote = headerFields["Active-Remote"] {
            if let dacpID = headerFields["DACP-ID"] {
                remote.updateRemoteToken(activeRemote, id: dacpID)
            }
        }

        let sequence = headerFields["CSeq"] ?? "0"
        response += ["CSeq: \(sequence)"]
        response += ["\r\n"]

        #if DEBUG
            printDebugInfo()
        #endif

        let joinedResponse = response.joinWithSeparator("\r\n")
        if let responseData = joinedResponse.dataUsingEncoding(NSUTF8StringEncoding) {
            let separator = "\r\n\r\n".dataUsingEncoding(NSUTF8StringEncoding)
            sock.writeData(responseData, withTimeout: 5, tag: 0)
            sock.readDataToData(separator, withTimeout: 5, tag: 0)
        }
    }

    private func parseSdpData(data: NSData, fromSocket sock: GCDAsyncSocket!) {
        let session = String(data: data, encoding: NSUTF8StringEncoding) ?? String()
        let sessionFields = session.componentsSeparatedByString("\r\n")
        var attributes = [String: String]()

        sessionFields.forEach() {
            if $0.characters.first == "a" {
                let attribute = $0.substringFromIndex($0.startIndex.advancedBy(2))
                let components = attribute.componentsSeparatedByString(":")
                attributes[components[0]] = components[1]
            }
        }

        // Decrypt AES session key using the RSA private key
        if let key = attributes["rsaaeskey"] {
            let paddedKey = padBase64String(key)
            let options = NSDataBase64DecodingOptions.init(rawValue: 0)
            if let keyData = NSData(base64EncodedString: paddedKey, options: options) {
                aesKey = rsaTransformWithType(.Decrypt, input: keyData)
            }
        }

        if let iv = attributes["aesiv"] {
            let paddedIV = padBase64String(iv)
            let options = NSDataBase64DecodingOptions.init(rawValue: 0)
            if let ivData = NSData(base64EncodedString: paddedIV, options: options) {
                aesIV = ivData
            }
        }
    }

    private func parseDmapData(data: NSData) {
        var offset = 0

        while offset < data.length {
            let tagBytes = data.subdataWithRange(NSMakeRange(offset, 4))
            let tag = String(data: tagBytes, encoding: NSUTF8StringEncoding) ?? String()
            offset += 4

            if tag == "mlit" {
                offset += 4
                continue
            }

            var size: UInt32 = 0
            let sizeBytes = data.subdataWithRange(NSMakeRange(offset, 4))
            sizeBytes.getBytes(&size, length:4)
            size = size.byteSwapped
            offset += 4

            let value = data.subdataWithRange(NSMakeRange(offset, Int(size)))
            let stringValue = String(data: value, encoding: NSUTF8StringEncoding)
            var intValue = 0
            value.getBytes(&intValue, length: value.length)

            // See DAAP format
            switch tag {
            case "asal":
                track.album = stringValue ?? String()
            case "asar":
                track.artist = stringValue ?? String()
            case "minm":
                track.name = stringValue ?? String()
            case "caps":
                track.playing = (intValue == 1)
            default:
                break
            }

            offset += Int(size)
        }
    }

    private func parseParameterData(data: NSData) {
        let parameters = String(data: data, encoding: NSUTF8StringEncoding) ?? String()
        let separators = NSCharacterSet(charactersInString: "/: \r\n")
        let field = parameters.componentsSeparatedByCharactersInSet(separators)

        if field[0] == "progress" {
            // Position and duration are set to -1 using default values
            let startTime = Double(field[2]) ?? 1
            let currentTime = Double(field[3]) ?? 0
            let endTime = Double(field[4]) ?? 0

            // AirTunes uses a fixed 44.1kHz sampling rate
            track.position = round((currentTime - startTime) / 44100)
            track.duration = round((endTime - startTime) / 44100)
        }
    }

    private func getCurrentSequenceNumber(rtpInfo: String) {
        let separators = NSCharacterSet(charactersInString: "=;")
        let field = rtpInfo.componentsSeparatedByCharactersInSet(separators)
        var sequenceNumber = -1

        for i in 0..<field.count {
            if field[i] == "seq" {
                sequenceNumber = Int(field[i + 1]) ?? -1
            }
        }

        if sequenceNumber != -1 {
            dispatch_async(callbackQueue) {
                self.playerState.packetsRead = Int64(sequenceNumber)
                self.playerState.packetsWritten = Int64(sequenceNumber)
                self.playerState.sessionTime = 0
            }
        }
    }

    private func respondToChallenge(challenge: String, fromSocket sock: GCDAsyncSocket!) -> String {
        let responseData = NSMutableData()
        let encodedData = NSData(base64EncodedString: challenge, options: .init(rawValue: 0))
        responseData.appendData(encodedData!)

        // Append IP and MAC address to response
        let address = sock.localAddress
        let length = address.length
        let range = sock.isIPv6 ? NSMakeRange(length - 20, 16) : NSMakeRange(length - 12, 4)
        responseData.appendData(address.subdataWithRange(range))
        responseData.appendBytes(getMacAddress(), length: 6)

        if responseData.length < 32 {
            responseData.increaseLengthBy(32 - responseData.length)
        }

        // Disconnect any other sessions
        for i in 1..<tcpSockets.count {
            if tcpSockets[i].localPort == 5001 && tcpSockets[i] == sock {
                break
            }

            tcpSockets[i].disconnect()
        }

        // Sign with private key
        let signedResponse = rsaTransformWithType(.Sign, input: responseData)

        return signedResponse.base64EncodedStringWithOptions(.init(rawValue: 0))
    }

    private func createSessionSockets() {
        // Sockets already exist
        if udpSockets.count > 0 {
            return
        }

        // Dedicated UDP queue to reduce latency
        let udpQueue = dispatch_queue_create("udpQueue", nil)
        let serverPort = GCDAsyncUdpSocket(delegate: self, delegateQueue: udpQueue)
        let controlPort = GCDAsyncUdpSocket(delegate: self, delegateQueue: udpQueue)
        let timingPort = GCDAsyncUdpSocket(delegate: self, delegateQueue: udpQueue)

        do {
            try serverPort.bindToPort(6010)
            try controlPort.bindToPort(6011)
            try timingPort.bindToPort(6012)

            try serverPort.beginReceiving()
            try controlPort.beginReceiving()
            try timingPort.beginReceiving()
        } catch {}

        udpSockets = [serverPort, controlPort, timingPort]
    }

    private func processPacketType(data: NSData) {
        var type = UInt8(0)
        var timeStamp = UInt32(0)
        var sequenceNumber = UInt16(0)
        var payload = NSData()

        data.subdataWithRange(NSMakeRange(1, 1)).getBytes(&type, length: 1)

        // New audio packet
        if type == 96 || type == 224 {
            data.subdataWithRange(NSMakeRange(4, 4)).getBytes(&timeStamp, length: 4)
            data.subdataWithRange(NSMakeRange(2, 2)).getBytes(&sequenceNumber, length: 2)
            payload = data.subdataWithRange(NSMakeRange(12, data.length - 12))

            timeStamp = timeStamp.byteSwapped
            sequenceNumber = sequenceNumber.byteSwapped

            // Request any missing packets
            if lastSequenceNumber != -1 && Int(sequenceNumber &- 1) != lastSequenceNumber {
                // Retransmit request header
                var header: [UInt8] = [128, 213, 0, 1]
                let request = NSMutableData(bytes: &header, length: 4)
                let numberOfPackets = sequenceNumber &- UInt16(lastSequenceNumber) &- 1
                var sequenceNumberBytes = (UInt16(lastSequenceNumber) &+ 1).byteSwapped
                var numberOfPacketsBytes = numberOfPackets.byteSwapped

                request.appendBytes(&sequenceNumberBytes, length: 2)
                request.appendBytes(&numberOfPacketsBytes, length: 2)

                // Limit resend attempts
                if address.length > 0 && numberOfPackets < 128 {
                    let controlPort = udpSockets[1]
                    controlPort.sendData(request, toAddress: address, withTimeout: 5, tag: 0)
                }

                #if DEBUG
                print("Retransmit: \(sequenceNumberBytes.byteSwapped)",
                      "Packets: \(numberOfPackets)",
                      "Current: \(Int(sequenceNumber &- 1))",
                      "Last: \(lastSequenceNumber)"
                    )
                #endif
            }

            lastSequenceNumber = Int(sequenceNumber)
        }
        // Retransmitted packet
        else if type == 214 {
            // Ignore malformed packets
            if data.length < 16 {
                return
            }

            data.subdataWithRange(NSMakeRange(8, 4)).getBytes(&timeStamp, length: 4)
            data.subdataWithRange(NSMakeRange(6, 2)).getBytes(&sequenceNumber, length: 2)
            payload = data.subdataWithRange(NSMakeRange(16, data.length - 16))

            timeStamp = timeStamp.byteSwapped
            sequenceNumber = sequenceNumber.byteSwapped
        }
        // Ignore unknown packets
        else {
            return
        }

        let packet = Packet()
        packet.data = payload
        packet.timeStamp = timeStamp
        packet.index = sequenceNumber
        decryptPacketData(packet)
    }

    private func decryptPacketData(packet: Packet) {
        var cryptor: CCCryptorRef = nil
        let length = packet.data.length
        var output = [UInt8](count: length, repeatedValue: 0)
        var moved = 0

        CCCryptorCreate(UInt32(kCCDecrypt), 0, 0, aesKey.bytes, 16, aesIV.bytes, &cryptor)
        CCCryptorUpdate(cryptor, packet.data.bytes, length, &output, output.count, &moved)

        // Remaining data is plain-text
        let decrypted = NSMutableData(bytes: &output, length: moved)
        let remaining = NSMakeRange(decrypted.length, length - decrypted.length)
        decrypted.appendData(packet.data.subdataWithRange(remaining))
        CCCryptorRelease(cryptor)
        packet.data = decrypted

        // Only 'callbackQueue' should modify 'playerState'
        dispatch_async(callbackQueue, {self.prepareAudioQueue(packet)})
    }

    private func prepareAudioQueue(packet: Packet) {
        let maxIndex = playerState.packets.count - 1
        let index = Int(packet.index) & maxIndex
        let remainingBuffer = playerState.packetsWritten - playerState.packetsRead
        playerState.packets[index] = packet

        // Set to one frame before the initial time
        if playerState.sessionTime == 0 {
            playerState.sessionTime = packet.timeStamp - 352
        }

        // Wrap-around condition
        let upperBound = UInt32(255 << 12)
        let lowerBound = UInt32(255 << 24)
        let wrapsAround = packet.timeStamp < upperBound && playerState.sessionTime > lowerBound

        // Find number of new packets
        if packet.timeStamp > playerState.sessionTime || wrapsAround {
            let packetsToAdd = Int64((packet.timeStamp &- playerState.sessionTime) / 352)
            playerState.packetsWritten += packetsToAdd
            playerState.sessionTime = packet.timeStamp
        }

        // Buffer at least 128 packets before playback
        if remainingBuffer >= 128 {
            playerState.packetsRead = playerState.packetsWritten - 128
            playerState.queueTime = 0

            for _ in 0..<self.playerState.buffers.count {
                let buffer = self.playerState.buffers[0]
                self.outputCallback(self.playerState, aq: self.playerState.queue, buffer: buffer)
                self.playerState.buffers.removeFirst()
            }

            if track.playing {
                AudioQueueStart(playerState.queue, nil)
            }
        }
    }

    private func resetTrackInfo() {
        track.name = ""
        track.album = ""
        track.artist = ""
        track.position = -1.0
        track.duration = -1.0
        track.artwork = NSImage()
        track.playing = false
    }

    private func resetAudioQueue() {
        dispatch_async(processQueue) {
            self.lastSequenceNumber = -1
        }

        AudioQueueReset(playerState.queue)

        dispatch_async(callbackQueue) {
            self.playerState.queueTime = 0
        }
    }

    private func outputCallback(playerState: PlayerState, aq: AudioQueueRef, buffer: AudioQueueBufferRef) {
        let maxIndex = Int64(playerState.packets.count - 1)
        var numberOfPackets = 0
        var offset = 0
        var time = UInt32(0)

        while playerState.packetsRead < playerState.packetsWritten {
            let index = Int(playerState.packetsRead & maxIndex)
            let packet = playerState.packets[index]
            let length = packet.data.length

            // Check that playback is in sequential order
            if packet.index != UInt16(playerState.packetsRead & 65535) {
                #if DEBUG
                    print("Skip: \(packet.index)", "Index: \(playerState.packetsRead & 65535)")
                #endif

                playerState.packetsRead += 1
                continue
            }

            // Not enough buffer space
            if offset + length > 1536 {
                break
            }

            if playerState.queueTime == 0 {
                playerState.queueTime = packet.timeStamp
            }

            // Find playback time for first buffered packet
            if packet.timeStamp >= playerState.queueTime && time == 0 {
                time = packet.timeStamp - playerState.queueTime
            }

            // Write to buffer and packet description array
            packet.data.getBytes(buffer.memory.mAudioData + offset, length: length)
            buffer.memory.mPacketDescriptions[numberOfPackets].mStartOffset = Int64(offset)
            buffer.memory.mPacketDescriptions[numberOfPackets].mDataByteSize = UInt32(length)
            buffer.memory.mPacketDescriptions[numberOfPackets].mVariableFramesInPacket = 0

            numberOfPackets += 1
            offset += length
            playerState.packetsRead += 1
        }

        buffer.memory.mAudioDataByteSize = UInt32(offset)
        buffer.memory.mPacketDescriptionCount = UInt32(numberOfPackets)

        // Enqueue with specific playback time
        var error = Int32(0)
        var timeStamp = AudioTimeStamp()
        timeStamp.mSampleTime = Double(time)
        AudioQueueFlush(aq)
        error = AudioQueueEnqueueBufferWithParameters(aq, buffer, 0, nil, 0, 0, 0, nil, &timeStamp, nil)

        if error != 0 {
            // Revert to working state if enqueue is unsuccessful
            playerState.buffers.append(buffer)
            playerState.queueTime = 0

            #if DEBUG
                printDebugInfo()
                print("Enqueue error: \(error)")
            #endif

            // Avoid attempting to catch up
            dispatch_async(processQueue) {
                self.lastSequenceNumber = -1
            }

            AudioQueuePause(aq)
        }
    }

    // MARK: Remote Functions

    func play() {
        remote.sendCommand("playpause")
    }

    func next() {
        remote.sendCommand("nextitem")
    }

    func previous() {
        remote.sendCommand("previtem")
    }

    // MARK: Helper Functions

    private func printDebugInfo() {
        print(
            "Read: \(playerState.packetsRead)",
            "Write: \(playerState.packetsWritten)",
            "Diff: \(playerState.packetsWritten - playerState.packetsRead)",
            "Buffer: \(playerState.buffers.count)",
            "Index: \(playerState.packetsRead & 65535)"
        )
    }

    private func padBase64String(input: String) -> String {
        var paddedInput = input

        while paddedInput.characters.count % 4 != 0 {
            paddedInput += "="
        }

        return paddedInput
    }

    private func getMacAddress() -> [UInt8] {
        var macAddress = [UInt8](count: 6, repeatedValue: 0)
        let matching = [
            "IOProviderClass": "IOEthernetInterface",
            "IOPropertyMatch": ["IOPrimaryInterface": true]
        ]

        var services = io_iterator_t()
        if IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &services) != 0 {
            return macAddress
        }

        var parent = io_object_t()
        var service = IOIteratorNext(services)

        while service != 0 {
            if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == 0 {
                let addressAsData = IORegistryEntryCreateCFProperty(parent, "IOMACAddress",
                    kCFAllocatorDefault, 0).takeRetainedValue() as? NSData
                addressAsData?.getBytes(&macAddress, length: 6)
                service = IOIteratorNext(services)
            }
        }

        return macAddress
    }

    private enum SecTransformType {
        case Sign
        case Decrypt
    }

    private func rsaTransformWithType(type: SecTransformType, input: NSData) -> NSData {
        let parameters: [NSString: AnyObject] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate
        ]

        let key = SecKeyCreateFromData(parameters, getRsaPrivateKey(), nil)!
        var transform: SecTransform

        if type == .Sign {
            transform = SecSignTransformCreate(key, nil)!
            SecTransformSetAttribute(transform, kSecInputIsAttributeName, kSecInputIsRaw, nil)
        }
        else {
            transform = SecDecryptTransformCreate(key, nil)
            SecTransformSetAttribute(transform, kSecPaddingKey, kSecPaddingOAEPKey, nil)
        }

        SecTransformSetAttribute(transform, kSecTransformInputAttributeName, input, nil)

        return SecTransformExecute(transform, nil) as! NSData
    }

    private func getRsaPrivateKey() -> NSData {
        var privateKeyBytes: [UInt8] = [
            48, 130, 4, 165, 2, 1, 0, 2, 130, 1, 1, 0, 231, 215, 68, 242, 162, 226, 120, 139, 108,
            31, 85, 160, 142, 183, 5, 68, 168, 250, 121, 69, 170, 139, 230, 198, 44, 229, 245, 28,
            189, 212, 220, 104, 66, 254, 61, 16, 131, 221, 46, 222, 193, 191, 212, 37, 45, 192,
            46, 111, 57, 139, 223, 14, 97, 72, 234, 132, 133, 94, 46, 68, 45, 166, 214, 38, 100,
            246, 116, 161, 243, 4, 146, 154, 222, 79, 104, 147, 239, 45, 246, 231, 17, 168, 199,
            122, 13, 145, 201, 217, 128, 130, 46, 80, 209, 41, 34, 175, 234, 64, 234, 159, 14, 20,
            192, 247, 105, 56, 197, 243, 136, 47, 192, 50, 61, 217, 254, 85, 21, 95, 81, 187, 89,
            33, 194, 1, 98, 159, 215, 51, 82, 213, 226, 239, 170, 191, 155, 160, 72, 215, 184, 19,
            162, 182, 118, 127, 108, 60, 207, 30, 180, 206, 103, 61, 3, 123, 13, 46, 163, 12, 95,
            255, 235, 6, 248, 208, 138, 221, 228, 9, 87, 26, 156, 104, 159, 239, 16, 114, 136, 85,
            221, 140, 251, 154, 139, 239, 92, 137, 67, 239, 59, 95, 170, 21, 221, 230, 152, 190,
            221, 243, 89, 150, 3, 235, 62, 111, 97, 55, 43, 182, 40, 246, 85, 159, 89, 154, 120,
            191, 80, 6, 135, 170, 127, 73, 118, 192, 86, 45, 65, 41, 86, 248, 152, 158, 24, 166,
            53, 91, 216, 21, 151, 130, 94, 15, 200, 117, 52, 62, 199, 130, 17, 118, 37, 205, 191,
            152, 68, 123, 2, 3, 1, 0, 1, 2, 130, 1, 1, 0, 229, 240, 12, 114, 245, 119, 214, 4,
            185, 164, 206, 65, 34, 170, 132, 176, 23, 67, 236, 153, 90, 207, 204, 127, 74, 178,
            124, 11, 24, 127, 144, 102, 91, 227, 89, 223, 18, 89, 129, 141, 238, 237, 121, 211,
            177, 239, 132, 94, 77, 221, 218, 201, 161, 85, 55, 59, 94, 39, 13, 142, 19, 21, 0, 26,
            46, 82, 125, 84, 205, 249, 0, 10, 87, 104, 188, 152, 212, 68, 107, 55, 187, 189, 0,
            178, 157, 216, 181, 48, 98, 19, 59, 42, 110, 119, 244, 238, 50, 80, 86, 34, 144, 77,
            167, 32, 251, 28, 18, 192, 57, 150, 218, 113, 58, 5, 6, 9, 142, 219, 237, 236, 249,
            54, 208, 250, 156, 189, 89, 41, 171, 176, 237, 163, 87, 153, 80, 47, 152, 148, 220,
            184, 252, 86, 154, 137, 45, 23, 120, 3, 36, 162, 182, 195, 22, 110, 52, 103, 9, 19,
            75, 133, 64, 65, 184, 103, 112, 107, 88, 254, 242, 160, 219, 146, 43, 119, 98, 139,
            104, 230, 150, 147, 199, 175, 67, 191, 42, 115, 208, 183, 50, 55, 122, 11, 161, 123,
            68, 240, 81, 233, 191, 121, 132, 157, 203, 51, 50, 87, 31, 216, 167, 9, 51, 194, 214,
            11, 222, 196, 121, 147, 74, 61, 172, 164, 11, 182, 242, 243, 124, 10, 157, 7, 16,
            110, 173, 200, 179, 105, 160, 63, 47, 65, 200, 128, 9, 142, 138, 221, 70, 36, 13,
            172, 104, 204, 83, 84, 243, 97, 2, 129, 129, 0, 247, 224, 191, 90, 30, 103, 24, 49,
            154, 139, 98, 9, 195, 23, 20, 68, 4, 89, 249, 115, 133, 102, 19, 177, 122, 225, 80,
            139, 179, 230, 49, 110, 107, 127, 70, 45, 47, 125, 100, 65, 43, 132, 183, 107, 194,
            63, 43, 12, 53, 98, 69, 82, 121, 178, 67, 169, 247, 49, 111, 149, 128, 7, 179, 76, 97,
            247, 104, 226, 212, 78, 213, 255, 43, 39, 40, 23, 236, 50, 179, 228, 147, 146, 146,
            40, 250, 231, 142, 119, 76, 160, 247, 94, 189, 105, 213, 146, 2, 121, 143, 17, 110,
            54, 12, 100, 56, 179, 46, 27, 216, 185, 220, 30, 50, 50, 240, 211, 9, 24, 136, 60,
            196, 62, 248, 221, 162, 44, 54, 145, 2, 129, 129, 0, 239, 111, 255, 249, 148, 241,
            229, 100, 65, 170, 0, 53, 253, 25, 160, 200, 214, 240, 35, 120, 199, 5, 128, 217, 196,
            132, 32, 121, 29, 244, 7, 197, 145, 251, 110, 191, 202, 50, 44, 48, 134, 221, 144, 31,
            210, 250, 225, 174, 187, 100, 173, 246, 187, 121, 255, 128, 81, 190, 189, 12, 216, 32,
            171, 137, 135, 64, 6, 1, 167, 178, 254, 147, 144, 202, 204, 154, 202, 184, 237, 43,
            249, 29, 24, 109, 143, 105, 100, 61, 126, 254, 15, 93, 86, 223, 117, 119, 162, 208,
            53, 234, 84, 19, 252, 152, 216, 243, 249, 8, 218, 5, 154, 55, 157, 164, 177, 204, 56,
            241, 93, 86, 10, 131, 204, 49, 113, 83, 200, 75, 2, 129, 129, 0, 208, 235, 175, 188,
            64, 37, 186, 129, 140, 117, 112, 35, 52, 56, 78, 143, 105, 111, 128, 77, 122, 160,
            231, 118, 78, 80, 123, 183, 211, 223, 239, 199, 214, 120, 198, 104, 45, 63, 173, 113,
            52, 65, 190, 234, 231, 36, 160, 158, 192, 155, 220, 59, 192, 112, 156, 145, 51, 212,
            137, 236, 226, 165, 26, 221, 5, 49, 39, 73, 15, 146, 134, 209, 115, 200, 164, 5, 77,
            194, 10, 87, 92, 126, 76, 12, 152, 52, 244, 161, 222, 135, 73, 23, 163, 228, 0, 234,
            248, 133, 6, 45, 181, 203, 126, 52, 54, 137, 231, 17, 247, 95, 231, 131, 215, 225,
            145, 146, 253, 118, 156, 213, 66, 190, 164, 185, 1, 7, 236, 209, 2, 129, 128, 127, 64,
            24, 220, 125, 234, 41, 45, 165, 48, 66, 56, 111, 49, 5, 160, 119, 138, 220, 111, 61,
            230, 144, 218, 43, 116, 197, 5, 89, 131, 237, 245, 116, 102, 26, 47, 215, 183, 222,
            128, 83, 204, 192, 226, 8, 240, 200, 172, 98, 111, 89, 125, 61, 153, 210, 206, 81,
            163, 123, 57, 174, 75, 126, 158, 242, 192, 117, 240, 191, 61, 131, 202, 205, 50, 218,
            150, 145, 146, 194, 137, 146, 53, 130, 92, 7, 209, 205, 50, 89, 161, 144, 108, 220,
            212, 153, 203, 97, 62, 34, 201, 76, 177, 234, 151, 25, 6, 96, 157, 241, 176, 244, 139,
            6, 63, 23, 55, 32, 52, 54, 148, 153, 181, 253, 249, 112, 239, 68, 13, 2, 129, 129, 0,
            144, 78, 233, 32, 249, 68, 239, 90, 175, 124, 148, 32, 160, 15, 94, 155, 72, 8, 44,
            11, 132, 224, 251, 181, 221, 162, 162, 38, 119, 223, 183, 184, 72, 141, 178, 190, 230,
            76, 155, 221, 60, 172, 102, 250, 50, 14, 118, 247, 28, 226, 175, 34, 114, 187, 189,
            118, 202, 185, 78, 8, 74, 12, 65, 217, 176, 119, 29, 198, 51, 64, 193, 172, 207, 90,
            137, 218, 1, 180, 55, 152, 111, 38, 156, 240, 194, 22, 225, 94, 161, 74, 3, 140, 218,
            105, 42, 240, 235, 109, 176, 14, 120, 128, 43, 147, 37, 32, 77, 45, 32, 2, 138, 63,
            140, 177, 52, 104, 232, 15, 100, 24, 142, 16, 70, 186, 27, 228, 88, 166
        ]

        return NSData(bytes: &privateKeyBytes, length: privateKeyBytes.count)
    }

    // MARK: Delegate Functions

    func socket(sock: GCDAsyncSocket!, didAcceptNewSocket newSocket: GCDAsyncSocket!) {
        tcpSockets.append(newSocket)
        let separator = "\r\n\r\n".dataUsingEncoding(NSUTF8StringEncoding)
        newSocket.readDataToData(separator, withTimeout: 5, tag: 0)
    }

    func socket(sock: GCDAsyncSocket!, didReadData data: NSData!, withTag tag: Int) {
        switch tag {
        case 0:
            parseRtspData(data, fromSocket: sock)
        case 1:
            parseSdpData(data, fromSocket: sock)
        case 2:
            track.artwork = NSImage(data: data) ?? NSImage()
        case 3:
            parseParameterData(data)
        case 4:
            parseDmapData(data)
        default:
            break
        }
    }

    func socket(sock: GCDAsyncSocket!, shouldTimeoutReadWithTag tag: Int, elapsed: NSTimeInterval,
        bytesDone length: UInt) -> NSTimeInterval {
        if tag == 0 {
            // Stop playback on connection timeout
            remote.sendCommand("pause")
            resetTrackInfo()
            resetAudioQueue()
        }

        #if DEBUG
            print("Connection timed out")
        #endif

        return 0
    }

    func udpSocket(sock: GCDAsyncUdpSocket!, didReceiveData data: NSData!, fromAddress address: NSData!,
        withFilterContext filterContext: AnyObject!) {
        // Audio data port
        if sock.localPort() == 6010 {
            dispatch_async(processQueue, {self.processPacketType(data)})
        }
        // Control port
        if sock.localPort() == 6011 {
            if self.address != address {
                self.address = address
            }

            dispatch_async(processQueue, {self.processPacketType(data)})
        }
    }
}