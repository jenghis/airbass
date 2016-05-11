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

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, EventTapDelegate {

    // MARK: IB Outlets

    @IBOutlet var expandedView: NSView!
    @IBOutlet var collapsedView: NSView!
    @IBOutlet var artwork: NSImageView!
    @IBOutlet var thumbnail: NSImageView!
    @IBOutlet var playbackSlider: NSSliderCell!

    @IBOutlet var currentSong: NSTextField!
    @IBOutlet var currentArtistAlbum: NSTextField!
    @IBOutlet var currentTime: NSTextField!
    @IBOutlet var totalTime: NSTextField!
    @IBOutlet var dummyTime: NSTextField!

    @IBOutlet var playPauseButton: NSButton!
    @IBOutlet var nextButton: NSButton!
    @IBOutlet var previousButton: NSButton!
    @IBOutlet var expandCollapseButton: NSButton!
    @IBOutlet var quitButton: NSButton!

    @IBOutlet var thumbnailConstraint: NSLayoutConstraint!

    // MARK: Instance Variables

    let airTunes = AirTunes()
    var timer: NSTimer?
    var window: NSWindow!
    var fadeTimer: NSTimer?
    var fadeAnimation: NSViewAnimation?

    var eventTap: EventTap?
    var shouldIntercept = true
    var whitelistIdentifiers = Set<String>()
    var mediaKeyAppList = [NSBundle.mainBundle().bundleIdentifier!]

    dynamic var darkMode = 1
    dynamic var largeArtwork = 0
    dynamic var floatingWindow = 0

    // MARK: Main Functions

    func applicationDidFinishLaunching(aNotification: NSNotification) {
        airTunes.start()

        ["name", "album", "artist", "duration", "artwork", "playing"].forEach() {
            airTunes.track.addObserver(self, forKeyPath: $0, options: .New, context: nil)
        }

        // eventsOfInterest value represents system events
        eventTap = EventTap(delegate: self, eventsOfInterest: 16384)
        let nc = NSWorkspace.sharedWorkspace().notificationCenter
        let activate = NSWorkspaceDidActivateApplicationNotification
        let terminate = NSWorkspaceDidTerminateApplicationNotification

        // Apps that can take media key priority
        whitelistIdentifiers = [
            NSBundle.mainBundle().bundleIdentifier!,
            "com.spotify.client",
            "com.apple.iTunes",
            "com.apple.QuickTimePlayerX",
            "com.apple.quicktimeplayer",
            "com.apple.iWork.Keynote",
            "com.apple.iPhoto",
            "org.videolan.vlc",
            "com.apple.Aperture",
            "com.plexsquared.Plex",
            "com.soundcloud.desktop",
            "org.niltsh.MPlayerX",
            "fm.last.Last.fm",
            "fm.last.Scrobbler"
        ]

        // Keep track of last active app to determine when to intercept media keys
        nc.addObserver(self, selector: #selector(appDidActivate(_:)), name: activate, object: nil)
        nc.addObserver(self, selector: #selector(appDidTerminate(_:)), name: terminate, object: nil)

        var rect = expandedView.frame
        rect.origin = CGPoint(x: 400, y: 200)

        let background = NSVisualEffectView(frame: rect)
        background.maskImage = maskImage(cornerRadius: 5.0)
        background.material = .AppearanceBased
        background.state = .Active
        background.blendingMode = .BehindWindow
        background.addSubview(expandedView)
        background.addSubview(collapsedView)

        let mask = NSBorderlessWindowMask
        window = NSWindow(contentRect: rect, styleMask: mask, backing: .Buffered, defer: false)
        window.contentView = background
        window.backgroundColor = NSColor.clearColor()
        window.hasShadow = true
        window.movableByWindowBackground = true
        window.setFrame(rect, display: true)
        window.makeKeyAndOrderFront(nil)

        // Needed for resizing animation to work properly
        expandedView.autoresizingMask = .ViewNotSizable
        collapsedView.autoresizingMask = .ViewHeightSizable

        // Tracking to show/hide controls in collapsed view
        let options: NSTrackingAreaOptions = [.MouseEnteredAndExited, .ActiveAlways]
        let area = collapsedView.frame
        let trackingArea = NSTrackingArea(rect: area, options: options, owner: self, userInfo: nil)
        collapsedView.addTrackingArea(trackingArea)

        toggleDarkMode()
        toggleArtwork(false, interactive: false)
        updateView()
        restoreUserPreferences()
    }

    func applicationWillTerminate(notification: NSNotification) {
        // Save window position, dark mode, and always on top preferences
        saveUserPreferences()
    }

    func saveUserPreferences() {
        let userDefaults = NSUserDefaults.standardUserDefaults()

        var lastPosition = window.frame.origin
        if lastPosition != CGPoint(x: 400, y: 200) && largeArtwork == 1 {
            // Adjust y position for collapsed view
            lastPosition.y += 338
        }

        userDefaults.setObject(NSStringFromPoint(lastPosition), forKey: "lastPosition")
        userDefaults.setObject(darkMode, forKey: "darkMode")
        userDefaults.setObject(floatingWindow, forKey: "floatingWindow")

        userDefaults.synchronize()
    }

    func restoreUserPreferences() {
        let userDefaults = NSUserDefaults.standardUserDefaults()

        if let lastPosition = userDefaults.objectForKey("lastPosition") as? String {
            window.setFrameOrigin(NSPointFromString(lastPosition))
        }

        if let darkMode = userDefaults.objectForKey("darkMode") as? Int {
            if darkMode == 0 {
                self.darkMode = darkMode
                toggleDarkMode()
            }
        }

        if let floatingWindow = userDefaults.objectForKey("floatingWindow") as? Int {
            self.floatingWindow = floatingWindow
            toggleFloatingWindow()
        }
    }

    func updateView() {
        artwork.image = airTunes.track.artwork
        thumbnail.image = airTunes.track.artwork

        // Show missing artwork image if no cover art is available
        if artwork.image == nil || artwork.image?.size == NSZeroSize {
            if darkMode == 1 {
                artwork.image = NSImage(named: "ArtworkDark")
                thumbnail.image = NSImage(named: "ThumbnailDark")
            }
            else {
                artwork.image = NSImage(named: "Artwork")
                thumbnail.image = NSImage(named: "Thumbnail")
            }

            // Collapse view if there is no cover art and we're in expanded view
            if largeArtwork == 1 && expandCollapseButton.enabled {
                dispatch_async(dispatch_get_main_queue()) {
                    self.toggleArtwork(false, interactive: true)
                }
            }

            expandCollapseButton.enabled = false
        }
        else {
            expandCollapseButton.enabled = true
        }

        // Set the appropriate image for playPauseButton
        let playing = airTunes.track.playing
        let image = playing ? NSImage(named: "Pause") : NSImage(named: "Play")
        let darkImage = playing ? NSImage(named: "PauseDark") : NSImage(named: "PlayDark")
        playPauseButton.image = darkMode == 1 ? darkImage : image
        playPauseButton.alternateImage = darkMode == 1 ? image : darkImage

        if airTunes.track.artist != "" && airTunes.track.album != "" {
            // Formatting for when we have both album and artist info
            dispatch_async(dispatch_get_main_queue()) {
                let newValue = "\(self.airTunes.track.artist) — \(self.airTunes.track.album)"
                self.currentArtistAlbum.stringValue = newValue
            }
        }
        else {
            // Formatting for when we are missing metadata info
            dispatch_async(dispatch_get_main_queue()) {
                let newValue = "\(self.airTunes.track.artist)\(self.airTunes.track.album)"
                self.currentArtistAlbum.stringValue = newValue
            }
        }

        dispatch_async(dispatch_get_main_queue()) {
            self.currentSong.stringValue = self.airTunes.track.name
            let inRect = NSPointInRect(NSEvent.mouseLocation(), self.window.frame)
            self.toggleControls(inRect)
        }

        // Stop timer and show controls if playback stopped
        if !airTunes.track.playing && timer != nil {
            timer?.invalidate()
            timer = nil
            playbackSlider.doubleValue = 0.0
            dispatch_async(dispatch_get_main_queue(), {self.toggleControls(true)})
        }

        // Start timer if playback began
        if airTunes.track.playing && timer == nil {
            timer = NSTimer(timeInterval: 0.5, target: self, selector: #selector(incrementTime),
                            userInfo: nil, repeats: true)
            NSRunLoop.mainRunLoop().addTimer(timer!, forMode: NSRunLoopCommonModes)

            // Determine whether cursor is in window and toggle controls accordingly
            let inRect = NSPointInRect(NSEvent.mouseLocation(), self.window.frame)
            self.toggleControls(inRect)
        }

        updateSlider(true)
    }

    func updateSlider(forceUpdate: Bool = false) {
        if !window.visible && !forceUpdate {
            return
        }

        currentTime.stringValue = stringForTime(airTunes.track.position)
        let newValue = stringForTime(airTunes.track.duration)

        // Set an upper bound to text field size so that
        // the frame doesn't change unless we add more digits
        if totalTime.stringValue != newValue {
            totalTime.stringValue = newValue
            var dummyString = ""
            for i in newValue.characters {
                switch i {
                case ":":
                    dummyString += ":"
                case "-":
                    dummyString += "-"
                default:
                    dummyString += "8"
                }
            }
            
            dummyTime.stringValue = dummyString
        }

        if airTunes.track.duration > 0 {
            // Calculation to avoid subpixel rendering
            let width = Double(playbackSlider.controlView!.frame.size.width)
            let value = round(airTunes.track.position * width / airTunes.track.duration)
            playbackSlider.doubleValue = value / width
        }
        else {
            playbackSlider.doubleValue = 0
        }
    }

    func toggleFloatingWindow() {
        // Controlled with Cocoa bindings
        if floatingWindow == 1 {
            window.level = Int(CGWindowLevelForKey(.FloatingWindowLevelKey))
        }
        else {
            window.level = Int(CGWindowLevelForKey(.NormalWindowLevelKey))
        }
    }

    func toggleDarkMode() {
        // alternateImage holds the dark/light version of a button depending on current theme
        [playPauseButton, nextButton, previousButton, expandCollapseButton, quitButton].forEach() {
            swap(&$0.image, &$0.alternateImage)
        }

        // Controlled with Cocoa bindings
        if darkMode == 1 {
            window.appearance = NSAppearance(named: NSAppearanceNameVibrantDark)
        }
        else {
            window.appearance = NSAppearance(named: NSAppearanceNameVibrantLight)
        }

        updateView()
    }

    func toggleArtwork(toggleOn: Bool, interactive: Bool) {
        // Disable expand/collapse if we're in the
        // middle of an animation
        if fadeAnimation?.animating ?? false {
            return
        }

        largeArtwork = toggleOn ? 1 : 0

        let image = toggleOn ? NSImage(named: "Collapse") : NSImage(named: "Expand")
        let darkImage = toggleOn ? NSImage(named: "CollapseDark") : NSImage(named: "ExpandDark")
        expandCollapseButton.image = darkMode == 1 ? darkImage : image
        expandCollapseButton.alternateImage = darkMode == 1 ? image : darkImage

        // Necessary to prevent graphic glitching
        currentSong.hidden = true
        currentArtistAlbum.hidden = true
        currentSong.alphaValue = 0
        currentArtistAlbum.alphaValue = 0

        // Toggle between expanded and collapsed height
        let newHeight: CGFloat = toggleOn ? 382 : 44
        let oldHeight: CGFloat = toggleOn ? 44 : 382
        
        var frame = window.frame
        frame.size.height = newHeight
        frame.origin.y += (oldHeight - newHeight)

        if interactive {
            var viewAnimations = [[String: AnyObject]]()
            let effect = toggleOn ? NSViewAnimationFadeOutEffect : NSViewAnimationFadeInEffect

            let windowResize: [String: AnyObject] = [
                NSViewAnimationTargetKey: window,
                NSViewAnimationEndFrameKey: NSValue(rect: frame),
                ]

            let toggleThumbnail: [String: AnyObject] = [
                NSViewAnimationTargetKey: thumbnail,
                NSViewAnimationEffectKey: effect,
                ]

            viewAnimations += [windowResize, toggleThumbnail]
            fadeAnimation = NSViewAnimation(viewAnimations: viewAnimations)
            fadeAnimation?.duration = 0.3
            fadeAnimation?.startAnimation()
        }
        else {
            window.setFrame(frame, display: true, animate: interactive)
            thumbnail.hidden = toggleOn
        }

        // Thumbnail constraint adjusts slider width
        currentTime.hidden = !toggleOn
        thumbnailConstraint.active = !toggleOn

        dispatch_async(dispatch_get_main_queue(), {self.toggleControls(false)})
    }

    func toggleControls(toggleOn: Bool) {
        // Controls are always visible in expanded view
        if largeArtwork == 1 {
            playPauseButton.alphaValue = 1
            previousButton.alphaValue = 1
            nextButton.alphaValue = 1

            return
        }

        // Begin fade out after a 0.5 second delay
        if !toggleOn && currentSong.stringValue != "" {
            fadeTimer?.invalidate()
            fadeTimer = NSTimer(fireDate: NSDate(timeIntervalSinceNow: 0.5), interval: 0, target: self,
                                selector: #selector(fadeOutControls), userInfo: nil, repeats: false)
            NSRunLoop.mainRunLoop().addTimer(fadeTimer!, forMode: NSRunLoopCommonModes)
        }
        else {
            currentSong.hidden = true
            currentArtistAlbum.hidden = true
            currentSong.alphaValue = 0
            currentArtistAlbum.alphaValue = 0

            playPauseButton.alphaValue = 1
            previousButton.alphaValue = 1
            nextButton.alphaValue = 1
        }
    }

    func fadeOutControls() {
        // Don't hide if mouse is in frame
        if NSPointInRect(NSEvent.mouseLocation(), window.frame) {
            return
        }

        // Don't hide if no metadata to show
        if currentSong.stringValue == "" || !airTunes.track.playing {
            return
        }

        currentSong.hidden = false
        currentArtistAlbum.hidden = false

        NSAnimationContext.currentContext().duration = 0.5
        NSAnimationContext.beginGrouping()

        currentSong.animator().alphaValue = 1
        currentArtistAlbum.animator().alphaValue = 1

        playPauseButton.animator().alphaValue = 0
        previousButton.animator().alphaValue = 0
        nextButton.animator().alphaValue = 0

        NSAnimationContext.endGrouping()
    }

    func incrementTime() {
        // Playback timer has half second precision
        if airTunes.track.position < airTunes.track.duration {
            airTunes.track.position += 0.5
            updateSlider()
        }
    }

    func maskImage(cornerRadius radius: CGFloat) -> NSImage {
        let edgeLength = 2.0 * radius + 1.0
        let size = NSSize(width: edgeLength, height: edgeLength)
        let maskImage = NSImage(size: size, flipped: false) {rect in
            let bezierPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            NSColor.blackColor().set()
            bezierPath.fill()

            return true
        }

        maskImage.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        maskImage.resizingMode = .Stretch
        
        return maskImage
    }

    func stringForTime(time: Double) -> String {
        let i = Int(floor(time))

        if i < 0 {
            return "--:--"
        }

        let hours = i / 3600
        let minutes = (i / 60) % 60
        let seconds = i % 60

        if hours == 0 {
            return String(format: "%d:%02d", minutes, seconds)
        }
        else {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
    }

    func getBundleIdentifierFromNotification(notification: NSNotification) -> String? {
        if let userInfo = notification.userInfo, currentApp = userInfo[NSWorkspaceApplicationKey] as?
            NSRunningApplication, let bundleIdentifier = currentApp.bundleIdentifier {
            return bundleIdentifier
        }
        else {
            return nil
        }
    }

    func appDidActivate(notification: NSNotification) {
        if let bundleIdentifier = getBundleIdentifierFromNotification(notification) {
            if !whitelistIdentifiers.contains(bundleIdentifier) {
                return
            }

            for i in 0..<mediaKeyAppList.count {
                if mediaKeyAppList[i] == bundleIdentifier {
                    mediaKeyAppList.removeAtIndex(i)
                    break
                }
            }

            // Take media key priority if we are the most recently activated app on the whitelist
            mediaKeyAppList.insert(bundleIdentifier, atIndex: 0)
            shouldIntercept = (mediaKeyAppList.first == NSBundle.mainBundle().bundleIdentifier!)
        }
    }

    func appDidTerminate(notification: NSNotification) {
        if let bundleIdentifier = getBundleIdentifierFromNotification(notification) {
            if !whitelistIdentifiers.contains(bundleIdentifier) {
                return
            }

            for i in 0..<mediaKeyAppList.count {
                if mediaKeyAppList[i] == bundleIdentifier {
                    mediaKeyAppList.removeAtIndex(i)
                    break
                }
            }

            shouldIntercept = (mediaKeyAppList.first == NSBundle.mainBundle().bundleIdentifier!)
        }
    }

    func eventTap(tap: EventTap!, interceptEvent event: CGEvent!, type: UInt32) -> Bool {
        // Only intercept when we have media key priority
        if !shouldIntercept {
            return false
        }

        // Filter events for media key presses
        if let cocoaEvent = NSEvent(CGEvent: event) {
            let keyCode = ((cocoaEvent.data1 & 0xffff0000) >> 16)
            let keyFlags = (cocoaEvent.data1 & 0x0000ffff)
            let keyState = (((keyFlags & 0xff00) >> 8)) == 0xA

            if !keyState {
                return false
            }

            switch Int32(keyCode) {
            case NX_KEYTYPE_PLAY:
                airTunes.play()
                return true
            case NX_KEYTYPE_FAST:
                airTunes.next()
                return true
            case NX_KEYTYPE_REWIND:
                airTunes.previous()
                return true
            default:
                break
            }
        }
        
        return false
    }

    func mouseEntered(theEvent: NSEvent) {
        // Show controls when cursor enters window
        dispatch_async(dispatch_get_main_queue(), {self.toggleControls(true)})
    }

    func mouseExited(theEvent: NSEvent) {
        // Hide controls when cursor leaves window
        dispatch_async(dispatch_get_main_queue(), {self.toggleControls(false)})
    }

    override func observeValueForKeyPath(keyPath: String?, ofObject object: AnyObject?,
        change: [String : AnyObject]?, context: UnsafeMutablePointer<Void>) {
        updateView()
    }

    @IBAction func pressedExpandCollapseButton(sender: AnyObject) {
        if expandCollapseButton.enabled {
            toggleArtwork(!thumbnail.hidden, interactive: true)
        }
    }

    @IBAction func pressedPlayPauseButton(sender: AnyObject) {
        airTunes.play()
    }

    @IBAction func pressedNextButton(sender: AnyObject) {
        airTunes.next()
    }

    @IBAction func pressedPreviousButton(sender: AnyObject) {
        airTunes.previous()
    }
}

// MARK: Class Extensions

extension NSButton {
    public override func awakeFromNib() {
        // Add tracking area to receive mouse events
        let options: NSTrackingAreaOptions = [
            .MouseEnteredAndExited,
            .ActiveInActiveApp,
            .EnabledDuringMouseDrag
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    public override func mouseDown(theEvent: NSEvent) {
        // Perform our own highlight on mouseDown because
        // we use alternateImage to store the themed image
        if enabled {
            alphaValue = 0.8
        }
    }

    public override func mouseUp(theEvent: NSEvent) {
        if enabled && alphaValue == 0.8 {
            target?.performSelector(action, withObject: self)
            alphaValue = 1
        }
    }

    override public func mouseExited(theEvent: NSEvent) {
        if enabled && alphaValue == 0.8 {
            alphaValue = 1
        }
    }
}

extension NSImageView {
    public override var mouseDownCanMoveWindow: Bool {
        return true
    }

    public override func mouseUp(theEvent: NSEvent) {
        // Perform action on double click
        if theEvent.clickCount == 2 {
            if action != nil {
                target?.performSelector(action, withObject: self)
            }
        }

        super.mouseUp(theEvent)
    }
}

class SliderCell: NSSliderCell {
    override func drawBarInside(aRect: NSRect, flipped: Bool) {
        var rect = aRect
        rect.size.height = 4

        // Remaining time segment
        if controlView?.window?.appearance?.name == NSAppearanceNameVibrantLight {
            NSColor(red: 122/255, green: 122/255, blue: 122/255, alpha: 0.5).setFill()
        }
        else {
            NSColor(red: 74/255, green: 74/255, blue: 74/255, alpha: 0.5).setFill()
        }

        NSBezierPath(rect: rect).fill()

        var leftRect = rect
        let value = CGFloat((doubleValue - minValue) / (maxValue - minValue))
        leftRect.size.width = CGFloat(value * (controlView!.frame.size.width))

        // Elapsed time segment
        if controlView?.window?.appearance?.name == NSAppearanceNameVibrantLight {
            NSColor(red: 98/255, green: 98/255, blue: 98/255, alpha: 0.7).setFill()
        }
        else {
            NSColor(red: 141/255, green: 141/255, blue: 141/255, alpha: 0.7).setFill()
        }

        NSBezierPath(rect: leftRect).fill()
    }

    override func drawKnob(knobRect: NSRect) {
        // No knob on slider
        return
    }
}