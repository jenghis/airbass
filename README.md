AirBass
=======

[![Swift 3.0](https://img.shields.io/badge/Swift-3.0-orange.svg?style=flat)](https://developer.apple.com/swift/)
[![Platforms macOS](https://img.shields.io/badge/Platforms-macOS-lightgray.svg?style=flat)](http://www.apple.com/macos/)
[![License Apache](https://img.shields.io/badge/License-APACHE2-blue.svg?style=flat)](https://www.apache.org/licenses/LICENSE-2.0.html)

AirBass is an AirPlay server implemented in Swift. It enables wireless audio streaming from an iOS device to a Mac using Apple\'s AirPlay technology.

<img src="https://raw.githubusercontent.com/jenghis/airbass/master/screenshot.png" width="700">

Installation
------------
Pre-built binaries can be found on our release page:

[https://github.com/jenghis/airbass/releases](https://github.com/jenghis/airbass/releases)

If you prefer building from source, start by cloning the repo with the command:

~~~shell
git clone --recurse-submodules https://github.com/jenghis/airbass
~~~

Then open `AirBass.xcworkspace` in Xcode. Select "AirBass" as the scheme and build the app.

Usage
-----
To get started, connect an iOS device to the same Wi-Fi network as your Mac. Open Control Center from the iOS device by swiping up from the bottom of the screen. Swipe Control Center left to find the card with audio controls. In the audio output section, select the "AirBass" option. Audio from the device should begin streaming to your Mac.  

License
-------
This project is available under the Apache 2.0 license. See LICENSE for details.
