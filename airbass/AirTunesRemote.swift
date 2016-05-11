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

final class AirTunesRemote: NSObject, NSNetServiceDelegate, NSNetServiceBrowserDelegate, GCDAsyncSocketDelegate {
    private var remoteToken = ""
    private var remoteID = ""
    private var remoteHost = ""
    private var remotePort = 0

    private var enabled = false
    private var request = [String]()
    private var browser = NSNetServiceBrowser()
    private var services = [NSNetService]()

    private let queue = dispatch_queue_create("remoteQueue", nil)
    private let socket = GCDAsyncSocket()

    override init() {
        super.init()
        browser.delegate = self
        socket.delegate = self
        socket.delegateQueue = queue
    }

    func updateRemoteToken(token: String, id: String) {
        if remoteToken != token {
            remoteToken = token
            remoteID = id

            // Pad ID to be 16 characters long
            while remoteID.characters.count < 16 {
                remoteID = "0\(remoteID)"
            }

            enabled = false
            socket.disconnect()
            browser.searchForServicesOfType("_dacp._tcp", inDomain: "local.")
        }
    }

    func sendCommand(command: String) {
        // Token updated but service hasn't
        // been resolved yet
        if !enabled {
            browser.stop()
            browser.searchForServicesOfType("_dacp._tcp", inDomain: "local.")
            return
        }

        request = ["GET /ctrl-int/1/\(command) HTTP/1.1"]
        request += ["Active-Remote: \(remoteToken)"]
        request += ["\r\n"]

        if socket.isConnected {
            let joinedRequest = request.joinWithSeparator("\r\n")
            if let requestData = joinedRequest.dataUsingEncoding(NSUTF8StringEncoding) {
                socket.writeData(requestData, withTimeout: 5, tag: 0)
            }
        }
        else {
            do {
                // Retry connection
                try socket.connectToHost(remoteHost, onPort: UInt16(remotePort))
            } catch {}
        }
    }

    func netServiceDidResolveAddress(sender: NSNetService) {
        if let hostName = sender.hostName {
            enabled = true
            remoteHost = hostName
            remotePort = sender.port
        }
    }

    func netServiceBrowser(browser: NSNetServiceBrowser, didFindService service: NSNetService, moreComing: Bool) {
        if service.name == "iTunes_Ctrl_\(remoteID)" {
            services.append(service)
            service.delegate = self
            service.resolveWithTimeout(5)
            browser.stop()
        }

        if !moreComing {
            browser.stop()
        }
    }

    func netServiceBrowser(browser: NSNetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        browser.stop()
    }

    func socket(sock: GCDAsyncSocket!, didConnectToHost host: String!, port: UInt16) {
        // Retry request when we successfully connect
        let joinedRequest = request.joinWithSeparator("\r\n")
        if let requestData = joinedRequest.dataUsingEncoding(NSUTF8StringEncoding) {
            socket.writeData(requestData, withTimeout: 5, tag: 0)
        }
    }
}