// Copyright 2017 Jenghis
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Cocoa
import AirTunes
import MediaKeys
import ABPlayerController

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, MediaKeysDelegate {
    var service: AirTunes!
    var mediaKeys: MediaKeys!
    var window: NSWindow!
    var viewController: ABPlayerController!

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        launchServer()
        listenForMediaKeys()
        createUserInterface()
        updateWindowPosition()
        loadPreferences()
    }

    func applicationWillTerminate(_ notification: Notification) {
        savePreferences()
    }

    func launchServer() {
        service = AirTunes(name: "AirBass")
        service.start()
    }

    func listenForMediaKeys() {
        mediaKeys = MediaKeys(delegate: self)
    }

    func createUserInterface() {
        viewController = ABPlayerController(service: service)
        window = ABWindow.makeWindow(contentViewController: viewController)
        window.makeKeyAndOrderFront(nil)
    }

    func updateWindowPosition() {
        var frame = window.frame
        frame.origin = NSPoint(x: 200, y: 400)
        window.setFrame(frame, display: true)
    }

    func savePreferences() {
        let defaults = UserDefaults.standard
        let lastPosition = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        defaults.set(NSStringFromPoint(lastPosition), forKey: "lastPosition")
        defaults.set(viewController.isDarkMode, forKey: "darkMode")
        defaults.set(viewController.isFloatingWindow, forKey: "floatingWindow")
    }

    func loadPreferences() {
        let defaults = UserDefaults.standard
        if let lastPosition = defaults.string(forKey: "lastPosition") {
            window.setFrameTopLeftPoint(NSPointFromString(lastPosition))
        }
        if let darkMode = defaults.object(forKey: "darkMode") {
            viewController.isDarkMode = darkMode as! Bool
        }
        if let floatingWindow = defaults.object(forKey: "floatingWindow") {
            viewController.isFloatingWindow = floatingWindow as! Bool
        }
    }

    func mediaKeys(_ mediaKeys: MediaKeys,
                   shouldInterceptKeyWithKeyCode keyCode: Int32) -> Bool {
        switch keyCode {
            case NX_KEYTYPE_PLAY:
                service.play()
                return true
            case NX_KEYTYPE_FAST:
                service.next()
                return true
            case NX_KEYTYPE_REWIND:
                service.previous()
                return true
            default:
                break
        }
        return false
    }
}
