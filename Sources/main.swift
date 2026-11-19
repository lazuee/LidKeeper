import Cocoa
import CoreGraphics

// Power Management assertions are declared in pm_helper.h, which build.sh
// feeds to swiftc via -import-objc-header. That keeps the Swift call sites and
// the C prototypes in a single source of truth instead of duplicating the
// symbols (and their return types) in @_silgen_name declarations.

// MARK: - Virtual Display Manager via ObjC Runtime
// CGVirtualDisplay, CGVirtualDisplayDescriptor, CGVirtualDisplaySettings
// are private CoreGraphics classes. Access them via ObjC runtime instead of
// requiring a C/Dylib bridge.
//
// This tricks macOS into thinking an external monitor is connected, which
// triggers native clamshell mode: lid closes -> built-in display turns off,
// system stays awake for the "external" display.

private func objcClass(_ name: String) -> NSObject.Type? {
    NSClassFromString(name) as? NSObject.Type
}

private func objcCall(_ obj: NSObject, _ sel: String, _ arg: AnyObject) {
    obj.perform(NSSelectorFromString(sel), with: arg)
}

private func objcUInt32(_ obj: NSObject, _ sel: String, _ val: UInt32) {
    typealias Fn = @convention(c) (AnyObject, Selector, UInt32) -> Void
    let m = class_getInstanceMethod(type(of: obj), NSSelectorFromString(sel))!
    unsafeBitCast(method_getImplementation(m), to: Fn.self)(obj, NSSelectorFromString(sel), val)
}

private func objcSize(_ obj: NSObject, _ sel: String, _ val: CGSize) {
    typealias Fn = @convention(c) (AnyObject, Selector, CGSize) -> Void
    let m = class_getInstanceMethod(type(of: obj), NSSelectorFromString(sel))!
    unsafeBitCast(method_getImplementation(m), to: Fn.self)(obj, NSSelectorFromString(sel), val)
}

class VirtualDisplayManager {
    private var display: NSObject?
    private let queue = DispatchQueue(label: "com.lidkeeper.vd", qos: .userInteractive)
    private var nextSerial: UInt32 = 1

    var isActive: Bool { display != nil }

    var displayID: CGDirectDisplayID? {
        guard let d = display else { return nil }
        let sel = NSSelectorFromString("displayID")
        guard d.responds(to: sel) else { return nil }
        typealias GetID = @convention(c) (AnyObject, Selector) -> UInt32
        let m = class_getInstanceMethod(type(of: d), sel)!
        return unsafeBitCast(method_getImplementation(m), to: GetID.self)(d, sel)
    }

    func create() -> Bool {
        guard display == nil else { return true }

        guard let descClass = objcClass("CGVirtualDisplayDescriptor"),
              let displayClass = objcClass("CGVirtualDisplay"),
              let settingsClass = objcClass("CGVirtualDisplaySettings"),
              let modeClass = objcClass("CGVirtualDisplayMode")
        else {
            NSLog("[LidKeeper] CGVirtualDisplay API not available")
            return false
        }

        // Build descriptor
        let desc = descClass.perform(NSSelectorFromString("new"))?
            .takeUnretainedValue() as! NSObject
        objcCall(desc, "setName:", "LidKeeper" as NSString)
        objcUInt32(desc, "setMaxPixelsWide:", 1920)
        objcUInt32(desc, "setMaxPixelsHigh:", 1080)
        objcSize(desc, "setSizeInMillimeters:", CGSize(width: 530, height: 300))
        objcUInt32(desc, "setVendorID:", 0x1337)
        objcUInt32(desc, "setProductID:", 0x0001)
        // macOS keys virtual displays by vendor+product+serial. The previous
        // display can still be registered at the moment the next one is
        // created, and a duplicate identity is rejected, so hand out a new
        // serial per create().
        objcUInt32(desc, "setSerialNum:", nextSerial)
        nextSerial += 1
        objcCall(desc, "setDispatchQueue:", queue)

        // Create virtual display
        let initSel = NSSelectorFromString("initWithDescriptor:")
        guard displayClass.instancesRespond(to: initSel) else {
            NSLog("[LidKeeper] initWithDescriptor: unavailable")
            return false
        }

        let allocated = displayClass.perform(NSSelectorFromString("alloc"))?
            .takeUnretainedValue() as! NSObject
        // takeRetainedValue, not takeUnretainedValue: `initWithDescriptor:`
        // returns +1. Leaving that reference unclaimed meant a destroyed
        // display was never deallocated, so it stayed registered with the
        // window server and every toggle added a "LidKeeper (n)" entry to
        // System Settings → Displays.
        guard let vd = allocated.perform(initSel, with: desc)?
            .takeRetainedValue() as? NSObject
        else {
            NSLog("[LidKeeper] CGVirtualDisplay init failed")
            return false
        }

        // Apply settings
        let mode = createMode(modeClass, width: 1920, height: 1080, refreshRate: 60.0)
        if let mode {
            let settings = settingsClass.perform(NSSelectorFromString("new"))?
                .takeUnretainedValue() as! NSObject
            settings.perform(NSSelectorFromString("setModes:"), with: [mode])
            settings.setValue(2, forKey: "hiDPI")
            vd.perform(NSSelectorFromString("applySettings:"), with: settings)
        }

        display = vd
        NSLog("[LidKeeper] Virtual display created")

        // Mirror to main after a short delay (needs display to settle).
        // Capture this exact display object: if the user toggles off/on within
        // the delay, a newer `create()` supersedes us and `self.display` no
        // longer refers to `vd`, so the stale closure must not run.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let current = self.display, current === vd else { return }
            self.mirrorToMain(vd)
        }

        return true
    }

    private func mirrorToMain(_ obj: NSObject) {
        guard let id = displayID else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { return }
        CGConfigureDisplayMirrorOfDisplay(cfg, id, CGMainDisplayID())
        CGCompleteDisplayConfiguration(cfg, .forSession)
    }

    func destroy() {
        if let d = display, let id = displayID {
            // Un-mirror first: while mirrored the display is inactive, so CG has
            // to stop using it as a mirror target before it can be torn down.
            var config: CGDisplayConfigRef?
            if CGBeginDisplayConfiguration(&config) == .success, let cfg = config {
                CGConfigureDisplayMirrorOfDisplay(cfg, id, kCGNullDirectDisplay)
                CGCompleteDisplayConfiguration(cfg, .forSession)
            }
            // Clear the modes so the window server stops tracking it, so the
            // entry leaves System Settings → Displays rather than lingering.
            if let settingsClass = objcClass("CGVirtualDisplaySettings"),
               let settings = settingsClass.perform(NSSelectorFromString("new"))?
                   .takeUnretainedValue() as! NSObject?
            {
                settings.perform(NSSelectorFromString("setModes:"), with: [NSObject]() as NSArray)
                d.perform(NSSelectorFromString("applySettings:"), with: settings)
            }
        }
        display = nil
        NSLog("[LidKeeper] Virtual display destroyed")
    }

    private func createMode(_ cls: NSObject.Type, width: Int, height: Int, refreshRate: Double) -> NSObject? {
        let sel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard cls.instancesRespond(to: sel) else { return nil }
        typealias InitFn = @convention(c) (AnyObject, Selector, Int, Int, Double) -> AnyObject?
        let obj = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as! NSObject
        let m = class_getInstanceMethod(cls, sel)!
        return unsafeBitCast(method_getImplementation(m), to: InitFn.self)(obj, sel, width, height, refreshRate) as? NSObject
    }
}

// MARK: - AppDelegate
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var isEnabled = false {
        didSet { refreshMenuBar() }
    }
    private let vdm = VirtualDisplayManager()
    private var pmAssertionID: UInt32 = 0
    private let pmAssertionTimeout: TimeInterval = 15
    private var pmRetryTimer: Timer?
    private var toggleMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_: Notification) {
        setupMenuBar()
        enable()
    }

    func applicationWillTerminate(_: Notification) {
        disable()
    }

    private func setupMenuBar() {
        // Sized to the title; 32pt clipped "LK" against its edges.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        toggleMenuItem = NSMenuItem(title: "Turn On", action: #selector(toggleEnabled), keyEquivalent: "")
        menu.addItem(toggleMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LidKeeper", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func refreshMenuBar() {
        // The menu has no status row: state shows only in this icon, so it is a
        // state in itself rather than decoration. A template image rather than
        // coloured text, so macOS tints it to match the bar and the neighbouring
        // items.
        let state: LidState
        if !isEnabled {
            state = .off
        } else if pmAssertionID == 0 {
            state = .warning
        } else {
            state = .on
        }
        statusItem.button?.image = lidIcon(state)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.title = ""
        statusItem.button?.toolTip = state.tooltip
        toggleMenuItem.title = isEnabled ? "Turn Off" : "Turn On"
    }

    private enum LidState {
        case on, off, warning

        var tooltip: String {
            switch self {
            case .on: return "LidKeeper: active"
            case .off: return "LidKeeper: disabled"
            case .warning: return "LidKeeper: display active, sleep assertion failed"
            }
        }
    }

    /// A laptop seen from the front, drawn as a template so macOS tints it like
    /// the neighbouring menu-bar items and it survives light and dark bars.
    /// State is carried by shape alone, since a template has no colour: open lid
    /// = keeping the Mac awake, closed slab = letting it sleep, exclamation in
    /// the screen = assertion failed.
    private func lidIcon(_ state: LidState) -> NSImage {
        let size = NSSize(width: 18, height: 17)
        let open = state != .off
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let line: CGFloat = 1.4

            // Screen: an upright hollow rect when open, a low filled slab when
            // shut — same weight either way, so the two read as one object.
            let screen = open
                ? NSRect(x: 3.4, y: 4.8, width: 11.2, height: 9.2)
                : NSRect(x: 2.8, y: 6.2, width: 12.4, height: 5.4)
            let screenPath = NSBezierPath(roundedRect: screen, xRadius: 1.8, yRadius: 1.8)
            screenPath.lineWidth = line
            if state == .off {
                screenPath.fill()
            } else {
                // On and warning both stay hollow, so the exclamation below has
                // something to sit in and the glyph keeps one visual weight.
                screenPath.stroke()
            }

            // Base, so the upright screen reads as a laptop lid and not a window.
            let base = NSBezierPath()
            base.move(to: NSPoint(x: 1.6, y: 3.1))
            base.line(to: NSPoint(x: 16.4, y: 3.1))
            base.lineWidth = line + 0.1
            base.lineCapStyle = .round
            base.stroke()

            if state == .warning {
                // Solid exclamation inside the hollow screen.
                NSBezierPath(roundedRect: NSRect(x: 7.9, y: 8.2, width: 2.0, height: 3.8),
                             xRadius: 1.0, yRadius: 1.0).fill()
                NSBezierPath(ovalIn: NSRect(x: 7.9, y: 6.4, width: 2.0, height: 1.1)).fill()
            }
            return true
        }
        // Template: macOS owns the colour, so it matches the bar in either mode.
        image.isTemplate = true
        return image
    }

    @objc private func toggleEnabled() {
        isEnabled ? disable() : enable()
    }

    @objc private func quitApp() {
        disable()
        NSApplication.shared.terminate(nil)
    }

    /// Acquires the NoIdleSleep assertion, retrying while the display stays up.
    /// A failure here is not cosmetic: without the assertion the network stack
    /// is allowed to sleep on lid close, which is the entire point of the app.
    private func acquireAssertion() {
        guard isEnabled, pmAssertionID == 0 else { return }
        let id = "LidKeeper active".withCString { pm_no_idle_sleep($0) }
        if id != 0 {
            pmAssertionID = id
            NSLog("[LidKeeper] NoIdleSleep assertion created: \(id)")
            stopRetrying()
        } else {
            NSLog("[LidKeeper] WARNING: NoIdleSleep assertion failed; retrying in \(pmAssertionTimeout)s")
            scheduleRetry()
        }
        refreshMenuBar()
    }

    private func scheduleRetry() {
        guard pmRetryTimer == nil else { return }
        pmRetryTimer = Timer.scheduledTimer(withTimeInterval: pmAssertionTimeout, repeats: true) { [weak self] _ in
            self?.acquireAssertion()
        }
    }

    private func stopRetrying() {
        pmRetryTimer?.invalidate()
        pmRetryTimer = nil
    }

    private func enable() {
        guard vdm.create() else {
            showAlert("Error", "Failed to create virtual display.\nThis app requires macOS 14+ with CGVirtualDisplay support.")
            return
        }
        isEnabled = true
        acquireAssertion()
    }

    private func disable() {
        stopRetrying()
        if pmAssertionID != 0 {
            let ret = pm_release_assertion(pmAssertionID)
            NSLog("[LidKeeper] NoIdleSleep assertion released: \(ret == 0 ? "OK" : "FAIL")")
            pmAssertionID = 0
        }
        vdm.destroy()
        isEnabled = false
    }

    private func showAlert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }
}

// MARK: - Entry Point
let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
