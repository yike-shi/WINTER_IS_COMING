// WinterIsComing — snow on your Mac desktop.
// Snow falls in front of your open windows and settles along their top edges the way Snowhush does: it clings
// around the rounded corners, holds a natural slope, spills off the ends when it gets deep, rides the window as
// you move it, slides when you jerk it and drops away when you minimize it. Sweep the cursor through the falling
// snow and it swirls out of the way. Hover over the snow to roll snowballs, push them into each other, drag them
// with the mouse and stack three of them into a snowman. See README.md for the full list.
// Build: swiftc -O WinterIsComing.swift -o WinterIsComing
// Run:   ./WinterIsComing   (a ❄︎ icon appears in the menu bar: pause / snow amount / quit)

import Cocoa
import SpriteKit

// MARK: - Settings (feel free to tweak)

enum Cfg {
    static var targetFlakes = 260            // number of flakes falling at the same time
    static let colW: CGFloat = 3             // width of one column of the snow height map (px)
    static let windowPileMax: CGFloat = 16   // max snow height on top of a window
    static let groundPileMax: CGFloat = 34   // max snow height at the bottom of the screen
    static let gravity: CGFloat = 900        // gravity for snow sliding off
    static let pollInterval = 1.0 / 30.0     // how often window positions are checked (s)
    static let maxClumps = 900               // max number of falling snow clumps at once
    static let dockPileMax: CGFloat = 18     // max snow height on the Dock
    static let dockPad: CGFloat = 4          // extra width of the Dock pile on each side of the icon area
    static let dockTopOffset: CGFloat = -1   // lower it if the snow floats above the Dock, raise it if it sinks in
    static let fallSpeed: CGFloat = 1.5      // falling speed multiplier (1 = original, bigger = faster)
    static let snowOverWindows = true        // snow falls in front of windows, so you see it land on their top edges
    static let flakesInFront = true          // when snowOverWindows is off: some of the smallest flakes still fall in front
    static let inFrontFraction: CGFloat = 0.4 // share of the smallest layer that falls in front (0...1)
    static let cursorWakeRadius: CGFloat = 80     // how far a moving cursor stirs the falling snow (px)
    static let cursorWakeMinSpeed: CGFloat = 20   // a cursor slower than this leaves the air still
    static let cursorWakeMaxSpeed: CGFloat = 500  // cap on the air's speed, so a flick doesn't fling flakes away
    static let ballStartRadius: CGFloat = 3  // a new snowball starts this small
    static let ballMaxRadius: CGFloat = 28   // and stops growing at this size
    static let maxBalls = 20                 // oldest resting snowballs are removed beyond this
    static let dockGain: CGFloat = 3.0       // snow landing on the Dock counts this many times more, so it builds up

    // Window snow, ported from Snowhush's SnowLayer / carry model
    static let windowDepth: CGFloat = 14         // how deep snow grows on a window before more slides off
    static let windowRepose: CGFloat = 0.8       // steepest slope the snow holds, as rise over run
    static let windowRounding: CGFloat = 0.15    // how quickly crests and notches round out
    static let windowCling: CGFloat = 1.4        // snow clings down a rounded corner up to this slope
    static let windowCornerRadius: CGFloat = 18  // macOS window corner radius the bed follows
    static let windowCornerExponent: CGFloat = 2.5
    static let snowGravity: CGFloat = 2500       // gravity felt by the snow riding a window
    static let snowAdhesion: CGFloat = 3500      // how hard the snow sticks to the window
    static let snowGrip: CGFloat = 3.0           // static friction: how hard the window must be jerked to make it slide
    static let snowSlip: CGFloat = 2.0           // sliding friction once it lets go
    static let snowBreakLift: CGFloat = 10       // how far it lifts before the whole heap lets go
    static let snowShaking: CGFloat = 4.0        // vibration that shakes grains off the heap
    static let trackTime: CGFloat = 0.06         // how closely the snow follows its window
    static let jumpSpeed: CGFloat = 6000         // faster than this, the window jumped out from under its snow
}

// MARK: - Find the Dock (needs Accessibility permission)

@MainActor final class DockTracker {
    private var trusted = false
    private var warned = false
    var lastError = ""

    init() {
        // On first run macOS shows a prompt asking you to grant the permission
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(opts)
    }

    /// Frame of the Dock icon area (global macOS coordinates, origin top-left); nil if unavailable
    func frame() -> CGRect? {
        if !trusted {
            trusted = AXIsProcessTrusted()
            if !trusted {
                if !warned {
                    warned = true
                    print("❄︎ For snow on the Dock: System Settings → Privacy & Security → Accessibility, enable Terminal (or whichever app you run this from), then restart.")
                }
                lastError = "no Accessibility permission"
                return nil
            }
        }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            lastError = "Dock process not found"
            return nil
        }
        let axApp = AXUIElementCreateApplication(dock.processIdentifier)
        var childrenRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXChildrenAttribute as CFString, &childrenRef)
        guard err == .success, let children = childrenRef as? [AXUIElement] else {
            lastError = "could not read Dock children (AXError \(err.rawValue))"
            return nil
        }
        var roles: [String] = []
        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            let role = (roleRef as? String) ?? "?"
            roles.append(role)
            guard role == kAXListRole else { continue }
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let pv = posRef, let sv = sizeRef,
                  CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { continue }
            var pos = CGPoint.zero
            var sz = CGSize.zero
            AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
            AXValueGetValue(sv as! AXValue, .cgSize, &sz)
            return CGRect(origin: pos, size: sz)
        }
        lastError = "no AXList among Dock children (roles: \(roles))"
        return nil
    }
}

// Three depth layers: far = small, faint, slow; near = big, bright, fast
struct Layer {
    let size: ClosedRange<CGFloat>
    let speed: ClosedRange<CGFloat>
    let alpha: ClosedRange<CGFloat>
    let sway: ClosedRange<CGFloat>
    let wind: CGFloat
    let z: CGFloat
}

let layers: [Layer] = [
    Layer(size: 1.8...3.0, speed: 22...38,  alpha: 0.30...0.50, sway: 5...10,  wind: 0.5, z: 1),
    Layer(size: 3.0...4.8, speed: 40...65,  alpha: 0.60...0.80, sway: 9...16,  wind: 0.8, z: 2),
    Layer(size: 4.8...7.5, speed: 70...105, alpha: 0.85...1.00, sway: 14...24, wind: 1.1, z: 7),
]

@inline(__always) func rnd(_ a: CGFloat, _ b: CGFloat) -> CGFloat { CGFloat.random(in: a...b) }

// Soft round flake texture: solid center, fading edge
@MainActor func makeFlakeTexture() -> SKTexture {
    let s: CGFloat = 64
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        let colors = [
            CGColor(red: 1, green: 1, blue: 1, alpha: 1.0),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.6),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
        ] as CFArray
        let locs: [CGFloat] = [0, 0.45, 1]
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locs) else { return false }
        let c = CGPoint(x: s / 2, y: s / 2)
        ctx.drawRadialGradient(grad, startCenter: c, startRadius: 0, endCenter: c, endRadius: s / 2, options: [])
        return true
    }
    return SKTexture(image: img)
}

// Snowball body: lit from the top-left, bluish shade at the bottom-right (this part never rotates)
@MainActor func makeSnowballTexture() -> SKTexture {
    let s: CGFloat = 128
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        ctx.addEllipse(in: CGRect(x: 1, y: 1, width: s - 2, height: s - 2))
        ctx.clip()
        let colors = [
            CGColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1),
            CGColor(red: 0.94, green: 0.96, blue: 1.00, alpha: 1),
            CGColor(red: 0.68, green: 0.75, blue: 0.88, alpha: 1),
        ] as CFArray
        let locs: [CGFloat] = [0, 0.55, 1]
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locs) else { return false }
        ctx.drawRadialGradient(grad,
                               startCenter: CGPoint(x: s * 0.38, y: s * 0.64), startRadius: 0,
                               endCenter: CGPoint(x: s * 0.5, y: s * 0.5), endRadius: s * 0.55,
                               options: [.drawsAfterEndLocation])
        return true
    }
    return SKTexture(image: img)
}

// Little grey-blue specks on top of the body; this layer rotates so you can see the ball roll
@MainActor func makeSpeckTexture() -> SKTexture {
    let s: CGFloat = 128
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        ctx.addEllipse(in: CGRect(x: 6, y: 6, width: s - 12, height: s - 12))
        ctx.clip()
        for _ in 0..<30 {
            let d = rnd(3, 8)
            ctx.setFillColor(CGColor(red: 0.66, green: 0.73, blue: 0.87, alpha: rnd(0.25, 0.55)))
            ctx.fillEllipse(in: CGRect(x: rnd(6, s - 14), y: rnd(6, s - 14), width: d, height: d))
        }
        return true
    }
    return SKTexture(image: img)
}

// MARK: - Snowball

@MainActor final class Snowball {
    let node = SKNode()
    let body: SKSpriteNode
    let specks: SKSpriteNode
    var x: CGFloat = 0
    var y: CGFloat = 0
    var r: CGFloat = Cfg.ballStartRadius
    weak var pile: Pile?         // the surface it rests on (nil while falling, dragged or stacked)
    weak var below: Snowball?    // the ball it is stacked on (snowman), if any
    var falling = false
    var dragging = false
    var vel = CGVector.zero
    var decor: SKNode?           // snowman face / scarf / buttons drawn on this ball

    init(body bodyTex: SKTexture, specks speckTex: SKTexture) {
        body = SKSpriteNode(texture: bodyTex)
        specks = SKSpriteNode(texture: speckTex)
        specks.zPosition = 0.1
        specks.zRotation = rnd(0, 6.28)
        node.zPosition = 6.5
        node.addChild(body)
        node.addChild(specks)
    }

    func layout() {
        node.position = CGPoint(x: x, y: y)
        let d = CGSize(width: r * 2, height: r * 2)
        body.size = d
        specks.size = d
    }

    func drop(vel v: CGVector) {
        falling = true
        dragging = false
        pile = nil
        below = nil
        vel = v
        node.isHidden = false    // it may have been hidden behind a window (or on a surface that vanished)
    }
}

// MARK: - Flake

@MainActor final class Flake {
    let node: SKSpriteNode
    var vel = CGVector.zero
    var size: CGFloat = 4
    var swayAmp: CGFloat = 0
    var swayFreq: CGFloat = 1
    var phase: CGFloat = 0
    var windFactor: CGFloat = 1
    var inFront = false          // true = falls in front of windows (ignores them), lands on Dock / ground
    var isClump = false          // true = clump sliding off a surface (affected by gravity)
    var push = CGVector.zero     // air dragged along by the cursor; decays after the cursor passes
    var ignoreID = -1            // don't land right back on the surface it came from
    var ignoreUntil: CGFloat = 0

    init(texture: SKTexture) { node = SKSpriteNode(texture: texture) }
}

// MARK: - Snow pile (a height map drawn as a smooth white mound)

@MainActor final class Pile {
    var minX: CGFloat
    var topY: CGFloat
    var width: CGFloat
    let maxH: CGFloat
    var h: [CGFloat]
    var caps: [CGFloat]          // max height per column, tapering at both ends so it looks rounded
    var occ: [Bool]              // whether this column is hidden behind a window in front
    let body = SKShapeNode()
    let shade = SKShapeNode()
    var dirty = false

    // MARK: Window ledge (Snowhush's SnowLayer, on a smaller scale)
    /// A window's snow is a layer that clings to its top edge: the bed dips around the window's rounded corners,
    /// capacity is how deep it grows, and the window moving carries the layer, which slides or flies off.
    let isWindow: Bool
    var bed: [CGFloat] = []          // underside of the snow, relative to the window's top edge
    var capacity: [CGFloat] = []     // depth at which fresh snow stops building up
    var right: CGFloat = 0           // the window's right edge, to tell a resize from a move
    var track = CGPoint.zero         // smoothed path of the window, whose acceleration the snow feels
    var trackVel = CGVector.zero
    var jolt = CGVector.zero
    var offset = CGVector.zero       // how far the snow has slid along or lifted off its window
    var offsetVel = CGVector.zero
    var agitation: CGFloat = 0
    var movedAt: CGFloat = -10
    var swingDir = CGVector.zero
    var swingPeak: CGFloat = 0
    var prevSwingPeak: CGFloat = 0
    var parity = false
    var spillL: CGFloat = 0
    var spillR: CGFloat = 0
    /// Snow that came off this ledge, for the scene to turn into falling clumps.
    var pending: [(height: CGFloat, at: CGPoint, vel: CGVector)] = []

    init(minX: CGFloat, topY: CGFloat, width: CGFloat, maxH: CGFloat, parent: SKNode, isWindow: Bool = false) {
        self.minX = minX
        self.topY = topY
        self.width = width
        self.maxH = maxH
        self.isWindow = isWindow
        let n = max(1, Int((width / Cfg.colW).rounded(.up)))
        h = Array(repeating: 0, count: n)
        occ = Array(repeating: false, count: n)
        caps = (0..<n).map { i in
            let edgeDist = min(CGFloat(i) + 0.5, CGFloat(n - i) - 0.5) * Cfg.colW
            let t = min(1, edgeDist / (maxH * 2.2))
            return maxH * t.squareRoot()
        }
        if isWindow {
            right = minX + width
            track = CGPoint(x: minX, y: topY)
            updateShape()
            caps = capacity
        }
        body.fillColor = NSColor(calibratedWhite: 1, alpha: 0.97)
        body.strokeColor = .clear
        body.lineWidth = 0
        body.zPosition = 5
        // light blue-grey layer underneath, like a shadow
        shade.fillColor = NSColor(calibratedRed: 0.70, green: 0.78, blue: 0.92, alpha: 0.9)
        shade.strokeColor = .clear
        shade.lineWidth = 0
        shade.zPosition = 4
        shade.position = CGPoint(x: 0, y: -1.5)
        parent.addChild(shade)
        parent.addChild(body)
    }

    var count: Int { h.count }
    var total: CGFloat { h.reduce(0, +) }
    var baseX: CGFloat { minX + offset.dx }
    var baseY: CGFloat { topY + offset.dy }

    func col(at x: CGFloat) -> Int? {
        let c = Int((x - baseX) / Cfg.colW)
        return (c >= 0 && c < count) ? c : nil
    }
    func colX(_ c: Int) -> CGFloat { baseX + (CGFloat(c) + 0.5) * Cfg.colW }
    /// The underside of the snow at a column: the window's top edge, dipping down around its rounded corners.
    func floor(_ c: Int) -> CGFloat { baseY + (isWindow ? bed[c] : 0) }
    func surface(_ c: Int) -> CGFloat { floor(c) + h[c] }

    /// Snowhush's window ledge: capacity and a bed that follows the window's rounded corners.
    func updateShape() {
        let n = count
        let radius = Cfg.windowCornerRadius
        bed = (0..<n).map { i in
            guard radius > 0 else { return 0 }
            let x = (CGFloat(i) + 0.5) * Cfg.colW
            let inset = min(x, width - x)
            if inset >= radius { return 0 }
            let u = Double(1 - inset / radius)
            let e = Double(Cfg.windowCornerExponent)
            let curve = 1 - pow(1 - pow(u, e), 1 / e)
            return -radius * CGFloat(max(0, curve))
        }
        let p0 = rnd(0, 6.28), p1 = rnd(0, 6.28)
        capacity = (0..<n).map { i in
            let x = CGFloat(i) * Cfg.colW
            let drift = 0.12 * sin(x * 0.0105 + p0) + 0.07 * sin(x * 0.037 + p1)
            return Cfg.windowDepth * (0.95 + drift)
        }
    }

    func add(at c: Int, amount: CGFloat) {
        if isWindow {
            // Snowhush's deposit: a narrow bell of snow centred on the flake, filling less as a column nears capacity.
            let kernel: [(Int, CGFloat)] = [(-2, 0.0625), (-1, 0.25), (0, 0.375), (1, 0.25), (2, 0.0625)]
            for (o, w) in kernel {
                let i = c + o
                guard i >= 0, i < count, !occ[i], capacity[i] > 0 else { continue }
                let fill = max(0, 1 - h[i] / capacity[i])
                h[i] += amount * w * fill
            }
        } else {
            let spread: [(Int, CGFloat)] = [(0, 1), (-1, 0.75), (1, 0.75), (-2, 0.45), (2, 0.45), (-3, 0.2), (3, 0.2)]
            for (o, w) in spread {
                let i = c + o
                guard i >= 0, i < count, !occ[i] else { continue }
                h[i] = min(caps[i], h[i] + amount * w)
            }
        }
        dirty = true
    }

    // let snow slump sideways where the slope is too steep
    func relax() -> Bool {
        isWindow ? relaxWindow() : relaxSimple()
    }

    func relaxSimple() -> Bool {
        guard count > 1 else { return false }
        var moved = false
        for i in 0..<(count - 1) where !occ[i] && !occ[i + 1] {
            let d = h[i] - h[i + 1]
            if abs(d) > 1.0 {
                let m = (abs(d) - 1.0) * 0.3 * (d > 0 ? 1 : -1)
                h[i] = max(0, min(caps[i], h[i] - m))
                h[i + 1] = max(0, min(caps[i + 1], h[i + 1] + m))
                if abs(m) > 0.02 { moved = true }
            }
        }
        return moved
    }

    /// Snowhush's relax: slopes steeper than the angle of repose slump, rounded crests even out, snow clings as
    /// far down a rounded corner as `windowCling` allows, and whatever slides past an end spills off it.
    func relaxWindow() -> Bool {
        let n = count
        guard n > 1 else { return false }
        let limit = Cfg.windowRepose * Cfg.colW
        let steepest = Cfg.windowCling * Cfg.colW
        let forwardFirst = parity
        parity = !parity
        var moved = false
        var spilledL: CGFloat = 0
        var spilledR: CGFloat = 0
        let rounding = Cfg.windowRounding

        for pass in 0..<6 {
            var shifted = false
            let forward = (pass % 2 == 0) == forwardFirst
            for k in 0..<(n - 1) {
                let i = forward ? k : n - 2 - k
                if occ[i] || occ[i + 1] { continue }
                let difference = (bed[i] + h[i]) - (bed[i + 1] + h[i + 1])
                let fall = bed[i] - bed[i + 1]
                let ahead = limit + min(max(fall, 0), steepest)
                let behind = limit + min(max(-fall, 0), steepest)
                if difference > ahead + 0.01 {
                    let transfer = min((difference - ahead) * 0.5, h[i])
                    h[i] -= transfer
                    h[i + 1] += transfer
                    if transfer > 0.001 { moved = true; shifted = true }
                } else if difference < -behind - 0.01 {
                    let transfer = min((-difference - behind) * 0.5, h[i + 1])
                    h[i + 1] -= transfer
                    h[i] += transfer
                    if transfer > 0.001 { moved = true; shifted = true }
                }
            }
            if !occ[0] && h[0] > limit + 0.01 {
                let transfer = (h[0] - limit) * 0.5
                h[0] -= transfer
                spilledL += transfer
                moved = true
                shifted = true
            }
            if !occ[n - 1] && h[n - 1] > limit + 0.01 {
                let transfer = (h[n - 1] - limit) * 0.5
                h[n - 1] -= transfer
                spilledR += transfer
                moved = true
                shifted = true
            }
            if !shifted { break }
        }
        // Round crests and notches toward their neighbours' average, leaving even slopes alone.
        if n > 3 {
            for i in 1..<(n - 2) {
                if occ[i - 1] || occ[i] || occ[i + 1] || occ[i + 2] { continue }
                let s0 = bed[i - 1] + h[i - 1]
                let s1 = bed[i] + h[i]
                let s2 = bed[i + 1] + h[i + 1]
                let s3 = bed[i + 2] + h[i + 2]
                let kink = (s1 - s2) - 0.5 * ((s0 - s1) + (s2 - s3))
                if abs(kink) <= 0.02 { continue }
                let transfer = kink > 0 ? min(kink * rounding, h[i]) : max(kink * rounding, -h[i + 1])
                if transfer > 0 {
                    h[i] -= transfer
                    h[i + 1] += transfer
                } else {
                    h[i + 1] += transfer
                    h[i] -= transfer
                }
                if abs(transfer) > 0.003 { moved = true }
            }
        }
        spillL += spilledL * Cfg.colW
        spillR += spilledR * Cfg.colW
        return moved
    }

    func clear() {
        for i in 0..<count { h[i] = 0 }
        spillL = 0
        spillR = 0
        pending.removeAll()
        dirty = true
    }

    /// The snow's drawn surface, smoothed across its neighbours the way Snowhush's shader smooths its height field.
    func smoothedSurface(_ c: Int) -> CGFloat {
        let l = max(0, c - 1), r = min(count - 1, c + 1)
        let smoothed = 0.25 * h[l] + 0.5 * h[c] + 0.25 * h[r]
        return floor(c) + smoothed
    }

    func redraw() {
        guard dirty else { return }
        dirty = relax()
        if total < 0.5 {
            body.path = nil
            shade.path = nil
            return
        }
        let p = CGMutablePath()
        if isWindow {
            // The snow is the band between its bed (which dips around the window's corners) and its surface.
            p.move(to: CGPoint(x: baseX, y: floor(0)))
            for c in 0..<count { p.addLine(to: CGPoint(x: colX(c), y: floor(c))) }
            p.addLine(to: CGPoint(x: baseX + width, y: floor(count - 1)))
            p.addLine(to: CGPoint(x: baseX + width, y: max(floor(count - 1), smoothedSurface(count - 1))))
            for c in stride(from: count - 1, through: 0, by: -1) {
                p.addLine(to: CGPoint(x: colX(c), y: smoothedSurface(c)))
            }
            p.addLine(to: CGPoint(x: baseX, y: max(floor(0), smoothedSurface(0))))
        } else {
            p.move(to: CGPoint(x: minX, y: topY))
            for c in 0..<count { p.addLine(to: CGPoint(x: colX(c), y: topY + h[c])) }
            p.addLine(to: CGPoint(x: minX + width, y: topY))
        }
        p.closeSubpath()
        body.path = p
        shade.path = p
    }

    // MARK: Window motion (ported from Snowhush's move_ledge / carry)

    /// The window moved or was resized: the snow rides it, feels the jolt, and slides or flies off when it can't
    /// keep up. `now` is the scene clock.
    func moveWindow(left: CGFloat, right newRight: CGFloat, top: CGFloat, dt: CGFloat, now: CGFloat) {
        guard isWindow else { return }
        let oldLeft = minX, oldTop = topY
        let oldRight = self.right > 0 ? self.right : oldLeft + width
        let shift = abs(left - oldLeft) <= abs(newRight - oldRight) ? left - oldLeft : newRight - oldRight
        let displacement = CGVector(dx: shift, dy: top - oldTop)
        let newWidth = max(Cfg.colW, newRight - left)
        let columns = max(1, Int((newWidth / Cfg.colW).rounded(.up)))
        let resized = columns != count || abs(left - oldLeft - shift) > 0.5 || abs(newWidth - width) > 0.01
        if displacement.dx == 0 && displacement.dy == 0 && !resized {
            self.right = newRight
            return
        }
        let elapsed = max(dt, 1.0 / 120)
        let wasResting = now - movedAt > 0.3 && dt > 0.05
        movedAt = now
        let jump = (displacement.dx * displacement.dx + displacement.dy * displacement.dy).squareRoot() / elapsed
        let jumped = jump > Cfg.jumpSpeed
        if jumped {
            // The window vanished from under the snow and reappeared elsewhere: nothing carried it along.
            pending.append((height: -1, at: .zero, vel: .zero))
            offset = .zero
            offsetVel = .zero
            trackVel = .zero
        }
        if resized {
            let by = Int(((oldLeft + shift - left) / Cfg.colW).rounded())
            width = newWidth
            resizeColumns(to: columns, by: by)
        }
        minX = left
        topY = top
        track.x += left - oldLeft - shift      // a resize doesn't move the window under its snow
        if jumped {
            track = CGPoint(x: left, y: top)
        } else if wasResting {
            // Join the motion at its current pace, with the lag a steady follow would have, instead of as a jolt.
            trackVel = CGVector(dx: displacement.dx / elapsed, dy: displacement.dy / elapsed)
            track = CGPoint(x: left - trackVel.dx * Cfg.trackTime, y: top - trackVel.dy * Cfg.trackTime)
        }
        self.right = newRight
        dirty = true
    }

    func resizeColumns(to newCount: Int, by: Int) {
        if newCount != count || by != 0 {
            var fresh = [CGFloat](repeating: 0, count: newCount)
            for i in 0..<count {
                let j = i + by
                if j >= 0 && j < newCount {
                    fresh[j] += h[i]
                } else if h[i] > 0.05 {
                    pending.append((height: h[i], at: CGPoint(x: colX(i), y: floor(i)), vel: trackVel))
                }
            }
            h = fresh
            occ = Array(repeating: false, count: newCount)
        }
        updateShape()
        caps = capacity
        dirty = true
    }

    /// Carries the snow as a body riding the window: gravity plus the window's inertia, friction holding it, and
    /// it flying free when the window drops away faster than gravity or stops short after rising.
    func carry(dt: CGFloat, joltScale: CGFloat) {
        guard isWindow, dt > 0, dt < 0.5 else { return }
        let previousVelocity = trackVel
        smoothDamp(&track, &trackVel, CGPoint(x: minX, y: topY), Cfg.trackTime, dt)
        var acceleration = CGVector(dx: (trackVel.dx - previousVelocity.dx) / dt,
                                    dy: (trackVel.dy - previousVelocity.dy) / dt)
        jolt = acceleration
        acceleration.dy *= joltScale

        // Agitation is vibration: two consecutive back-and-forth swings, not a single start or stop.
        agitation *= CGFloat(exp(Double(-dt / 0.3)))
        let magnitude = (acceleration.dx * acceleration.dx + acceleration.dy * acceleration.dy).squareRoot()
        if magnitude > 1 && (acceleration.dx * swingDir.dx + acceleration.dy * swingDir.dy) < 0 {
            agitation = max(agitation, min(prevSwingPeak, swingPeak) / Cfg.snowGravity)
            prevSwingPeak = swingPeak
            swingPeak = magnitude
            swingDir = CGVector(dx: acceleration.dx / magnitude, dy: acceleration.dy / magnitude)
        } else {
            swingPeak = max(swingPeak, magnitude)
            if magnitude > 1 && swingDir.dx == 0 && swingDir.dy == 0 {
                swingDir = CGVector(dx: acceleration.dx / magnitude, dy: acceleration.dy / magnitude)
            }
        }

        if total <= 0.05 {
            offset = .zero
            offsetVel = .zero
            return
        }

        var lift = offset.dy
        var liftVelocity = offsetVel.dy
        let fall = -Cfg.snowGravity - acceleration.dy
        if lift > 0 || fall > Cfg.snowAdhesion {
            liftVelocity += fall * dt
            lift += liftVelocity * dt
            if lift <= 0 {
                lift = 0
                liftVelocity = 0
            }
        }

        let pressure = lift > 0 ? 0 : max(0, Cfg.snowGravity + Cfg.snowAdhesion + acceleration.dy)
        let drive = -acceleration.dx
        var slideVelocity = offsetVel.dx
        if !(slideVelocity == 0 && abs(drive) <= Cfg.snowGrip * pressure) {
            let direction: CGFloat = slideVelocity != 0 ? (slideVelocity > 0 ? 1 : -1) : (drive > 0 ? 1 : -1)
            let next = slideVelocity + (drive - direction * Cfg.snowSlip * pressure) * dt
            slideVelocity = (pressure > 0 && next * direction <= 0) ? 0 : next
        }

        var slide = offset.dx + slideVelocity * dt
        let carried = CGVector(dx: trackVel.dx + slideVelocity, dy: trackVel.dy + liftVelocity)
        while abs(slide) >= Cfg.colW {
            let direction: CGFloat = slide > 0 ? 1 : -1
            let (dropped, at) = slideColumn(direction > 0 ? 1 : -1)
            slide -= direction * Cfg.colW
            if dropped > 0.01 {
                pending.append((height: dropped, at: at, vel: carried))
            }
        }

        offset = CGVector(dx: slide, dy: lift)
        offsetVel = CGVector(dx: slideVelocity, dy: liftVelocity)
        if lift != 0 || slide != 0 { dirty = true }

        if lift > Cfg.snowBreakLift {
            pending.append((height: -1, at: .zero, vel: carried))
            offset = .zero
            offsetVel = .zero
        } else if agitation > Cfg.snowShaking {
            // A granular bed shaken well past gravity throws grains off its surface.
            let rate = min(0.8, 0.06 * (agitation - Cfg.snowShaking))
            let picks = Int(CGFloat(count) * rate * dt * 2 + CGFloat.random(in: 0...1))
            for _ in 0..<picks {
                let c = Int.random(in: 0..<count)
                let amount = h[c] * 0.35
                guard amount > 0.05 else { continue }
                h[c] -= amount
                pending.append((height: amount, at: CGPoint(x: colX(c), y: surface(c)), vel: carried))
                dirty = true
            }
        }
    }

    /// Shifts the height map one column and returns what slid off the far end.
    func slideColumn(_ direction: Int) -> (CGFloat, CGPoint) {
        guard count > 1 else { return (0, .zero) }
        if direction > 0 {
            let last = count - 1
            let dropped = h[last]
            let at = CGPoint(x: colX(last) + Cfg.colW, y: floor(last))
            h.removeLast()
            h.insert(0, at: 0)
            occ.removeLast()
            occ.insert(false, at: 0)
            return (dropped, at)
        }
        let dropped = h[0]
        let at = CGPoint(x: colX(0) - Cfg.colW, y: floor(0))
        h.removeFirst()
        h.append(0)
        occ.removeFirst()
        occ.append(false)
        return (dropped, at)
    }

    /// Critically damped follow (Snowhush's smooth_damp), stable at any time step.
    func smoothDamp(_ current: inout CGPoint, _ velocity: inout CGVector, _ target: CGPoint, _ time: CGFloat, _ dt: CGFloat) {
        let omega = 2 / max(time, 0.001)
        let x = omega * dt
        let decay = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
        let change = CGVector(dx: current.x - target.x, dy: current.y - target.y)
        let temp = CGVector(dx: (velocity.dx + change.dx * omega) * dt,
                            dy: (velocity.dy + change.dy * omega) * dt)
        velocity.dx = (velocity.dx - temp.dx * omega) * decay
        velocity.dy = (velocity.dy - temp.dy * omega) * decay
        current.x = target.x + (change.dx + temp.dx) * decay
        current.y = target.y + (change.dy + temp.dy) * decay
    }

    func remove() {
        body.removeFromParent()
        shade.removeFromParent()
    }
}

// MARK: - Scene

final class SnowScene: SKScene {
    var flakes: [Flake] = []
    var pool: [Flake] = []
    var piles: [Int: Pile] = [:]                 // window number -> snow on top of it
    var lastRect: [Int: CGRect] = [:]
    var order: [(id: Int, rect: CGRect)] = []    // windows from front to back
    var ground: Pile?
    var tex: SKTexture?
    var lastT: TimeInterval = 0
    var pollAcc: CGFloat = 0
    var t: CGFloat = 0
    let myPID = getpid()
    let world = SKNode()
    let dockTracker = DockTracker()
    var dockPile: Pile?
    var dockRect: CGRect?
    var dockAcc: CGFloat = 1
    var lastDockStatus = ""
    var balls: [Snowball] = []
    weak var activeBall: Snowball?
    var lastMouse = NSEvent.mouseLocation
    var cursorPos = NSEvent.mouseLocation   // where the cursor is now, in scene coordinates
    var cursorVel = CGVector.zero           // how fast it moves; its wake stirs the falling snow
    var cursorSeen = false
    var ballTex: SKTexture?
    var dragBall: Snowball?
    var dragTarget = CGPoint.zero
    var dragOffset = CGPoint.zero
    var dragVel = CGVector.zero
    var speckTex: SKTexture?
    static let dockID = -2

    override func didMove(to view: SKView) {
        backgroundColor = .clear
        tex = makeFlakeTexture()
        ballTex = makeSnowballTexture()
        speckTex = makeSpeckTexture()
        addChild(world)
        resetGround()
        for _ in 0..<Cfg.targetFlakes { spawnFlake(y: rnd(0, size.height)) }
    }

    override func didChangeSize(_ oldSize: CGSize) {
        guard tex != nil else { return }
        resetGround()
    }

    func resetGround() {
        for b in balls where b.pile === ground { b.drop(vel: .zero) }
        ground?.remove()
        ground = Pile(minX: 0, topY: 0, width: size.width, maxH: Cfg.groundPileMax, parent: world)
    }

    func clearAll() {
        for p in piles.values { p.clear(); p.redraw() }
        dockPile?.clear()
        dockPile?.redraw()
        ground?.clear()
        ground?.redraw()
        for b in balls { b.node.removeFromParent() }
        balls.removeAll()
    }

    // MARK: Flake pool

    func obtain() -> Flake {
        let f = pool.popLast() ?? Flake(texture: tex!)
        world.addChild(f.node)
        flakes.append(f)
        return f
    }

    func recycle(at i: Int) {
        let f = flakes[i]
        f.node.removeFromParent()
        flakes.swapAt(i, flakes.count - 1)
        flakes.removeLast()
        pool.append(f)
    }

    func spawnFlake(y: CGFloat? = nil) {
        let f = obtain()
        let r = CGFloat.random(in: 0...1)
        let li = r < 0.40 ? 0 : (r < 0.68 ? 1 : 2)   // 40% far, 28% middle, 32% near
        let L = layers[li]
        f.inFront = Cfg.flakesInFront && li == 0 && CGFloat.random(in: 0...1) < Cfg.inFrontFraction
        f.isClump = false
        f.ignoreID = -1
        f.push = .zero
        f.size = CGFloat.random(in: L.size)
        f.vel = CGVector(dx: 0, dy: -CGFloat.random(in: L.speed) * Cfg.fallSpeed)
        f.swayAmp = CGFloat.random(in: L.sway)
        f.swayFreq = rnd(0.6, 1.6)
        f.phase = rnd(0, 6.28)
        f.windFactor = L.wind
        f.node.alpha = CGFloat.random(in: L.alpha)
        f.node.size = CGSize(width: f.size * 2.2, height: f.size * 2.2)
        f.node.zPosition = L.z
        f.node.position = CGPoint(x: rnd(-40, size.width + 40), y: y ?? size.height + rnd(2, 30))
    }

    func spawnClump(at p: CGPoint, vel: CGVector, sourceID: Int) {
        let f = obtain()
        f.isClump = true
        f.inFront = false
        f.push = .zero
        f.size = rnd(2.5, 5)
        f.vel = vel
        f.ignoreID = sourceID
        f.ignoreUntil = t + 0.35
        f.node.alpha = 0.95
        f.node.size = CGSize(width: f.size * 2.2, height: f.size * 2.2)
        f.node.zPosition = 6
        f.node.position = p
    }

    // Turn a pile into falling clumps; vel is the window's velocity, so faster drags fling snow farther
    func release(_ p: Pile, vel: CGVector, id: Int) {
        let fling = CGVector(dx: max(-900, min(900, vel.dx * 0.5)),
                             dy: max(-300, min(500, vel.dy * 0.4)))
        // Snowballs sitting on this surface get flung off too
        for b in balls where b.pile === p {
            b.drop(vel: CGVector(dx: fling.dx + rnd(-30, 30), dy: fling.dy + rnd(20, 80)))
        }
        let total = p.total
        guard total > 0.5 else { p.clear(); return }
        let budget = CGFloat(max(0, Cfg.maxClumps - flakes.count + Cfg.targetFlakes))
        let k = min(1, budget / max(1, total / 3.5))
        for c in 0..<p.count where p.h[c] > 0.6 {
            var amount = p.h[c] / 3.5 * k
            while amount > 0 {
                if amount < 1 && CGFloat.random(in: 0...1) > amount { break }
                spawnClump(at: CGPoint(x: p.colX(c) + rnd(-1.5, 1.5), y: p.floor(c) + rnd(0, p.h[c])),
                           vel: CGVector(dx: fling.dx + rnd(-40, 40), dy: fling.dy + rnd(10, 80)),
                           sourceID: id)
                amount -= 1
            }
        }
        p.clear()
    }

    // MARK: Per-frame update

    override func update(_ currentTime: TimeInterval) {
        if lastT == 0 { lastT = currentTime }
        let dt = CGFloat(min(currentTime - lastT, 1.0 / 20.0))
        lastT = currentTime
        t += dt
        pollAcc += dt
        if Double(pollAcc) >= Cfg.pollInterval {
            pollWindows(dt: pollAcc)
            pollAcc = 0
        }
        trackCursor(dt)
        stepFlakes(dt)
        updateMouseCapture()
        if let b = dragBall { stepDrag(b, dt) } else { updateRolling() }
        stepBalls(dt)
    }

    // MARK: Dragging & snowmen

    /// The overlay normally lets every click through. Only while the mouse is over a snowball (or dragging one)
    /// does it catch clicks, so you can grab the ball without clicking the window underneath.
    func updateMouseCapture() {
        guard let w = view?.window else { return }
        let capture = dragBall != nil || ballAt(NSEvent.mouseLocation) != nil
        if w.ignoresMouseEvents == capture { w.ignoresMouseEvents = !capture }
    }

    /// The visible, resting snowball under a point (top of a stack first)
    func ballAt(_ m: CGPoint) -> Snowball? {
        var best: Snowball?
        for b in balls where !b.falling && !b.node.isHidden {
            let dx = m.x - b.x, dy = m.y - b.y
            if dx * dx + dy * dy <= (b.r + 2) * (b.r + 2), best == nil || b.y > best!.y { best = b }
        }
        return best
    }

    func above(_ b: Snowball) -> Snowball? { balls.first { $0.below === b } }

    func base(of b: Snowball) -> Snowball {
        var x = b
        while let y = x.below { x = y }
        return x
    }

    /// Balls in a stack from the bottom up
    func stack(from base: Snowball) -> [Snowball] {
        var out = [base]
        while let a = above(out.last!), out.count < 10 { out.append(a) }
        return out
    }

    override func mouseDown(with event: NSEvent) {
        let m = event.location(in: self)
        guard let b = ballAt(m) else { return }
        // Anything stacked on top of the grabbed ball tumbles off
        var a = above(b)
        while let x = a {
            a = above(x)
            x.drop(vel: CGVector(dx: rnd(-50, 50), dy: rnd(40, 100)))
        }
        removeDecor(stackOf: b)
        b.pile = nil
        b.below = nil
        b.dragging = true
        b.node.zPosition = 8                 // in front while dragging
        dragBall = b
        activeBall = nil
        dragOffset = CGPoint(x: b.x - m.x, y: b.y - m.y)
        dragTarget = m
        dragVel = .zero
    }

    override func mouseDragged(with event: NSEvent) {
        dragTarget = event.location(in: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard let b = dragBall else { return }
        dragBall = nil
        b.dragging = false
        if let target = stackTarget(for: b) {
            b.below = target
            b.vel = .zero
            let st = stack(from: base(of: b))
            for (i, x) in st.enumerated() { x.node.zPosition = 6.5 + CGFloat(i) * 0.3 }
            if st.count == 3 { makeSnowman(st) }
        } else {
            b.node.zPosition = 6.5
            // Let go: it falls (with a bit of the throw) and lands on whatever is below
            b.drop(vel: CGVector(dx: max(-600, min(600, dragVel.dx * 0.5)),
                                 dy: max(-400, min(400, dragVel.dy * 0.5))))
        }
    }

    func stepDrag(_ b: Snowball, _ dt: CGFloat) {
        let target = CGPoint(x: dragTarget.x + dragOffset.x, y: dragTarget.y + dragOffset.y)
        if dt > 0 {
            let v = CGVector(dx: (target.x - b.x) / dt, dy: (target.y - b.y) / dt)
            dragVel = CGVector(dx: dragVel.dx * 0.7 + v.dx * 0.3, dy: dragVel.dy * 0.7 + v.dy * 0.3)
        }
        b.specks.zRotation -= (target.x - b.x) / b.r
        b.x = target.x
        b.y = target.y
        lastMouse = NSEvent.mouseLocation
    }

    /// A ball dropped just above another ball (that isn't already a full snowman) gets stacked on it
    func stackTarget(for b: Snowball) -> Snowball? {
        var best: Snowball?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for c in balls where c !== b && !c.falling && !c.dragging && !c.node.isHidden {
            guard above(c) == nil, stack(from: base(of: c)).count < 3 else { continue }
            let dx = abs(b.x - c.x), dy = b.y - c.y
            guard dx < c.r * 0.9 + b.r * 0.3, dy > 0, dy < c.r + b.r + 30 else { continue }
            if dx < bestDist { best = c; bestDist = dx }
        }
        return best
    }

    func removeDecor(stackOf b: Snowball) {
        for x in stack(from: base(of: b)) {
            x.decor?.removeFromParent()
            x.decor = nil
        }
    }

    /// Three stacked balls become a snowman: face and scarf on the head, buttons and stick arms on the body
    func makeSnowman(_ st: [Snowball]) {
        let body = st[1], head = st[2]
        removeDecor(stackOf: head)
        let R = head.r

        let h = SKNode()
        h.zPosition = 0.5
        for sx in [-1.0, 1.0] as [CGFloat] {
            let eye = SKShapeNode(circleOfRadius: max(1, R * 0.09))
            eye.fillColor = NSColor(calibratedWhite: 0.08, alpha: 1)
            eye.strokeColor = .clear
            eye.position = CGPoint(x: sx * R * 0.3, y: R * 0.22)
            h.addChild(eye)
        }
        let nose = CGMutablePath()
        nose.move(to: CGPoint(x: R * 0.02, y: R * 0.06))
        nose.addLine(to: CGPoint(x: R * 0.75, y: -R * 0.04))
        nose.addLine(to: CGPoint(x: R * 0.02, y: -R * 0.12))
        nose.closeSubpath()
        let carrot = SKShapeNode(path: nose)
        carrot.fillColor = NSColor(calibratedRed: 0.96, green: 0.52, blue: 0.13, alpha: 1)
        carrot.strokeColor = .clear
        h.addChild(carrot)
        for k in 0..<5 {
            let a = CGFloat.pi * (1.2 + 0.15 * CGFloat(k))
            let dot = SKShapeNode(circleOfRadius: max(0.7, R * 0.05))
            dot.fillColor = NSColor(calibratedWhite: 0.1, alpha: 1)
            dot.strokeColor = .clear
            dot.position = CGPoint(x: cos(a) * R * 0.42, y: sin(a) * R * 0.42 - R * 0.05)
            h.addChild(dot)
        }
        let red = NSColor(calibratedRed: 0.82, green: 0.16, blue: 0.18, alpha: 1)
        let scarf = SKShapeNode(rect: CGRect(x: -R * 0.85, y: -R * 0.98, width: R * 1.7, height: R * 0.3),
                                cornerRadius: R * 0.12)
        scarf.fillColor = red
        scarf.strokeColor = .clear
        h.addChild(scarf)
        let tail = SKShapeNode(rect: CGRect(x: R * 0.3, y: -R * 1.55, width: R * 0.28, height: R * 0.7),
                               cornerRadius: R * 0.08)
        tail.fillColor = red
        tail.strokeColor = .clear
        tail.zRotation = -0.15
        h.addChild(tail)
        head.node.addChild(h)
        head.decor = h

        let B = body.r
        let bd = SKNode()
        bd.zPosition = 0.5
        for k in 0..<3 {
            let btn = SKShapeNode(circleOfRadius: max(0.8, B * 0.07))
            btn.fillColor = NSColor(calibratedWhite: 0.08, alpha: 1)
            btn.strokeColor = .clear
            btn.position = CGPoint(x: 0, y: B * (0.35 - 0.33 * CGFloat(k)))
            bd.addChild(btn)
        }
        let brown = NSColor(calibratedRed: 0.42, green: 0.28, blue: 0.16, alpha: 1)
        for sx in [-1.0, 1.0] as [CGFloat] {
            let arm = CGMutablePath()
            arm.move(to: CGPoint(x: sx * B * 0.85, y: B * 0.15))
            arm.addLine(to: CGPoint(x: sx * B * 1.75, y: B * 0.65))
            arm.move(to: CGPoint(x: sx * B * 1.4, y: B * 0.45))
            arm.addLine(to: CGPoint(x: sx * B * 1.55, y: B * 0.85))
            let stick = SKShapeNode(path: arm)
            stick.strokeColor = brown
            stick.lineWidth = max(1.2, B * 0.09)
            stick.lineCap = .round
            bd.addChild(stick)
        }
        body.node.addChild(bd)
        body.decor = bd
    }

    // MARK: Snowballs

    /// Is the mouse inside the snow band of this pile (a bit below the edge up to a bit above the snow)?
    func mouseOver(_ p: Pile, _ m: CGPoint) -> Bool {
        guard let c = p.col(at: m.x), !p.occ[c] else { return false }
        return m.y >= p.floor(c) - 6 && m.y <= p.surface(c) + 14
    }

    /// Which snow surface is the mouse hovering over? Dock first, then windows front to back, then the ground.
    func surfaceUnderMouse(_ m: CGPoint) -> Pile? {
        // Hovering over a snowball counts as hovering over the snow it sits on. Without this, a big ball
        // stops rolling as soon as the cursor rises above the thin snow band, which makes pushing jerky.
        for b in balls where !b.falling && !b.dragging && !b.node.isHidden && b.below == nil {
            guard let p = b.pile, let c = p.col(at: m.x), abs(m.x - b.x) < b.r + 8 else { continue }
            if m.y >= p.floor(c) - 6 && m.y <= p.surface(c) + 2 * b.r + 8 { return p }
        }
        if let d = dockPile, mouseOver(d, m) { return d }
        if let dr = dockRect, dr.contains(m) { return nil }
        for item in order {
            if let p = piles[item.id], mouseOver(p, m) { return p }
            if item.rect.contains(m) { return nil }      // over a window's content
        }
        if let g = ground, mouseOver(g, m) { return g }
        return nil
    }

    func updateRolling() {
        let m = NSEvent.mouseLocation     // same coordinates as the scene (origin bottom-left of main screen)
        let dx = m.x - lastMouse.x
        lastMouse = m
        guard let p = surfaceUnderMouse(m) else { activeBall = nil; return }
        guard abs(dx) > 0.2 else { return }

        // Keep rolling the current ball, pick up a resting one under the mouse, or start a new one
        if let b = activeBall, b.pile === p, above(b) == nil, abs(b.x - (m.x - dx)) < b.r + 25 {   // ball was at the previous mouse x
            // keep it
        } else if let b = balls.first(where: { !$0.falling && $0.pile === p && abs($0.x - m.x) < $0.r + 10 }) {
            guard above(b) == nil else { activeBall = nil; return }   // don't roll the bottom of a snowman
            activeBall = b
        } else if let c = p.col(at: m.x), p.h[c] > 1.5 {
            let b = Snowball(body: ballTex!, specks: speckTex!)
            b.x = m.x
            b.pile = p
            b.y = p.surface(c) + b.r - 1.5
            b.layout()
            world.addChild(b.node)
            balls.append(b)
            activeBall = b
            trimBalls()
        } else {
            activeBall = nil
            return
        }
        guard let b = activeBall else { return }

        // Move the ball to the mouse, staying on the surface
        let lo = p.baseX + b.r, hi = p.baseX + p.width - b.r
        let newX = lo < hi ? min(max(m.x, lo), hi) : b.x
        let moved = newX - b.x
        guard abs(moved) > 0.01 else { return }
        let oldX = b.x
        roll(b, on: p, to: newX)
        push(from: b, oldX: oldX, dir: moved > 0 ? 1 : -1, on: p)
    }

    /// Roll a ball to newX: it picks up snow from the columns it passes over and grows
    func roll(_ b: Snowball, on p: Pile, to newX: CGFloat) {
        let moved = newX - b.x
        guard abs(moved) > 0.01 else { return }
        if b.r < Cfg.ballMaxRadius {
            var collected: CGFloat = 0
            let from = min(b.x, newX) - b.r * 0.8
            let to = max(b.x, newX) + b.r * 0.8
            let frac = min(0.6, 0.6 * abs(moved) / (1.6 * b.r))
            if let c0 = p.col(at: max(from, p.baseX)), let c1 = p.col(at: min(to, p.baseX + p.width - 0.1)), c0 <= c1 {
                for c in c0...c1 where !p.occ[c] {
                    let take = p.h[c] * frac
                    p.h[c] -= take
                    collected += take
                }
                p.dirty = true
            }
            // Ball area grows by the snow area it picked up
            let area = CGFloat.pi * b.r * b.r + collected * Cfg.colW * 0.8
            b.r = min(Cfg.ballMaxRadius, (area / .pi).squareRoot())
        }
        b.x = newX
        b.specks.zRotation -= moved / b.r     // roll
    }

    /// The moving ball pushes any ball it touches in front of it; that ball can push the next one, and so on.
    /// A ball pushed past the end of a surface falls off.
    func push(from b: Snowball, oldX: CGFloat, dir: CGFloat, on p: Pile) {
        // Look for balls ahead of where the pusher *was*: after a fast mouse move it may already have
        // jumped past a ball, and that ball must still be pushed instead of being passed through.
        let ahead = balls
            .filter { $0 !== b && !$0.falling && !$0.dragging && $0.pile === p && ($0.x - oldX) * dir > 0 }
            .sorted { abs($0.x - oldX) < abs($1.x - oldX) }
        var pusher = b
        for o in ahead {
            let need = pusher.x + dir * (pusher.r + o.r)     // where o must be to just touch the pusher
            guard (need - o.x) * dir > 0 else { break }       // not touching: the chain stops here
            let lo = p.baseX + o.r, hi = p.baseX + p.width - o.r
            if need < lo || need > hi {
                o.x = need
                o.drop(vel: CGVector(dx: dir * 140, dy: 40))  // pushed off the edge
            } else {
                roll(o, on: p, to: need)
            }
            pusher = o
        }
    }

    func trimBalls() {
        while balls.count > Cfg.maxBalls,
              let i = balls.firstIndex(where: { !$0.falling && !$0.dragging && $0.decor == nil && $0 !== activeBall }) {
            balls[i].node.removeFromParent()
            balls.remove(at: i)
        }
    }

    func stepBalls(_ dt: CGFloat) {
        var i = balls.count - 1
        while i >= 0 {
            let b = balls[i]
            var gone = false
            if b.falling {
                if b.decor != nil { b.decor?.removeFromParent(); b.decor = nil }
                b.node.zPosition = 6.5
                let prevBottom = b.y - b.r
                b.vel.dy -= Cfg.gravity * dt
                b.x += b.vel.dx * dt
                b.y += b.vel.dy * dt
                b.specks.zRotation -= b.vel.dx * dt / b.r
                if b.vel.dy < 0, let p = landingSurface(x: b.x, from: prevBottom, to: b.y - b.r) {
                    splat(b, on: p)                  // falling snowballs burst into a heap of snow
                    gone = true
                } else if b.y < -b.r * 2 || b.x < -100 || b.x > size.width + 100 {
                    gone = true
                }
            } else if b.dragging {
                // position is set by stepDrag
            } else if let under = b.below {
                if under.falling || under.dragging {
                    b.drop(vel: CGVector(dx: under.vel.dx + rnd(-40, 40), dy: max(under.vel.dy, 0) + rnd(30, 80)))
                } else {
                    b.x = under.x
                    b.y = under.y + under.r + b.r * 0.82   // sits slightly sunk into the ball below
                    b.node.isHidden = under.node.isHidden
                }
            } else if let p = b.pile {
                if let c = p.col(at: b.x) {
                    b.node.isHidden = p.occ[c]     // hidden behind a window in front
                    b.y = p.surface(c) + b.r - 1.5  // sits slightly sunk into the snow
                } else {
                    // The window shrank (or moved) out from under it: let it fall off the nearest end
                    // onto whatever is below, instead of leaving it hidden in mid-air.
                    let dir: CGFloat = b.x < p.baseX ? -1 : 1
                    b.drop(vel: CGVector(dx: dir * 120, dy: 20))
                }
            } else {
                b.drop(vel: .zero)                 // lost its support (e.g. the ball below was removed)
            }
            if gone {
                b.node.removeFromParent()
                balls.remove(at: i)
            } else {
                b.layout()
            }
            i -= 1
        }
    }

    /// First surface a falling ball hits between two heights: the Dock, then window tops (front to back),
    /// then the bottom of the screen. Returns nil if it hits nothing this frame.
    func landingSurface(x: CGFloat, from top: CGFloat, to bottom: CGFloat) -> Pile? {
        func crosses(_ p: Pile) -> Bool {
            guard let c = p.col(at: x), !p.occ[c] else { return false }
            let s = p.surface(c)
            return top >= s && bottom < s
        }
        if let d = dockPile, crosses(d) { return d }
        for item in order {
            if let p = piles[item.id], crosses(p) { return p }
        }
        // The ground catches everything that reaches the bottom, even where a window covers it
        if let g = ground, let c = g.col(at: x), bottom < g.surface(c) { return g }
        return nil
    }

    /// A falling ball bursts where it lands: its snow becomes a mound on that surface, plus a puff of powder
    func splat(_ b: Snowball, on p: Pile) {
        if let c0 = p.col(at: b.x) {
            let snow = CGFloat.pi * b.r * b.r * 0.7 / Cfg.colW     // ball area -> total column height
            let half = max(2, Int(b.r * 1.4 / Cfg.colW))
            var sum: CGFloat = 0
            for o in -half...half { sum += 1 - abs(CGFloat(o)) / CGFloat(half + 1) }
            for o in -half...half {
                let i = c0 + o
                guard i >= 0, i < p.count, !p.occ[i] else { continue }
                let w = (1 - abs(CGFloat(o)) / CGFloat(half + 1)) / sum
                p.h[i] = min(p.caps[i], p.h[i] + snow * w)
            }
            p.dirty = true
        }
        for _ in 0..<min(14, Int(b.r * 0.6) + 2) {
            spawnClump(at: CGPoint(x: b.x + rnd(-b.r, b.r), y: b.y - b.r * 0.5 + rnd(0, b.r * 0.5)),
                       vel: CGVector(dx: b.vel.dx * 0.2 + rnd(-90, 90), dy: rnd(60, 180)),
                       sourceID: -3)
        }
    }

    /// A falling ball comes to rest on a surface and can be rolled again from there (currently unused)
    func land(_ b: Snowball, on p: Pile) {
        b.falling = false
        b.vel = .zero
        b.pile = p
        let lo = p.baseX + b.r, hi = p.baseX + p.width - b.r
        if lo < hi { b.x = min(max(b.x, lo), hi) }
        if let c = p.col(at: b.x) { b.y = p.surface(c) + b.r - 1.5 }
    }

    /// A falling snowball bursts into loose snow when it hits the ground
    func poof(_ b: Snowball) {
        let n = min(40, Int(b.r * 1.6))
        for _ in 0..<n {
            spawnClump(at: CGPoint(x: b.x + rnd(-b.r, b.r), y: b.y + rnd(-b.r * 0.5, b.r * 0.5)),
                       vel: CGVector(dx: b.vel.dx * 0.3 + rnd(-90, 90), dy: rnd(40, 170)),
                       sourceID: -3)
        }
    }

    // Read all window frames (macOS origin is top-left, SpriteKit is bottom-left, so flip y)
    func pollWindows(dt: CGFloat) {
        let H = size.height
        var newOrder: [(id: Int, rect: CGRect)] = []
        if let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for w in info {
                guard let layerN = w[kCGWindowLayer as String] as? NSNumber, layerN.intValue == 0,
                      let pidN = w[kCGWindowOwnerPID as String] as? NSNumber, pidN.int32Value != myPID,
                      let numN = w[kCGWindowNumber as String] as? NSNumber,
                      let bd = w[kCGWindowBounds as String] as? NSDictionary,
                      let b = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
                let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
                if alpha < 0.05 || b.width < 80 || b.height < 40 { continue }
                newOrder.append((id: numN.intValue,
                                 rect: CGRect(x: b.minX, y: H - b.maxY, width: b.width, height: b.height)))
            }
        }

        // Closed / minimized windows: their snow just falls
        let alive = Set(newOrder.map { $0.id })
        for (id, pile) in piles where !alive.contains(id) {
            release(pile, vel: .zero, id: id)
            pile.remove()
            piles[id] = nil
            lastRect[id] = nil
        }

        for item in newOrder {
            let id = item.id, r = item.rect
            if let pile = piles[id] {
                pile.moveWindow(left: r.minX, right: r.maxX, top: r.maxY, dt: dt, now: t)
            } else {
                piles[id] = Pile(minX: r.minX, topY: r.maxY, width: r.width,
                                 maxH: Cfg.windowPileMax, parent: world, isWindow: true)
            }
            lastRect[id] = r
        }
        order = newOrder

        // The Dock rarely changes; checking every 0.5 s is enough
        dockAcc += dt
        if dockAcc >= 0.5 {
            dockAcc = 0
            updateDock()
        }

        computeOcclusion()
        let joltScale = min(max(1440 / max(size.height, 1), 0.5), 2.0) * 2.0
        for (id, p) in piles {
            p.carry(dt: dt, joltScale: joltScale)
            p.redraw()
            drainLedge(p, id: id)
        }
        dockPile?.redraw()
        ground?.redraw()
    }

    /// Turns what slid off a window ledge (or all of it, when the window jumped or lifted away) into falling snow.
    func drainLedge(_ p: Pile, id: Int) {
        // Snow that slumped past an end of the window falls from that edge.
        if p.spillL > 1.5 {
            let pieces = max(1, Int((p.spillL / 10).rounded(.up)))
            for _ in 0..<pieces {
                spawnClump(at: CGPoint(x: p.baseX + rnd(0, 2), y: p.surface(0)),
                           vel: CGVector(dx: p.trackVel.dx - 6 + rnd(-30, 30), dy: p.trackVel.dy - 15 + rnd(10, 60)),
                           sourceID: id)
            }
            p.spillL = 0
        }
        if p.spillR > 1.5 {
            let pieces = max(1, Int((p.spillR / 10).rounded(.up)))
            for _ in 0..<pieces {
                spawnClump(at: CGPoint(x: p.baseX + p.width - rnd(0, 2), y: p.surface(p.count - 1)),
                           vel: CGVector(dx: p.trackVel.dx + 6 + rnd(-30, 30), dy: p.trackVel.dy - 15 + rnd(10, 60)),
                           sourceID: id)
            }
            p.spillR = 0
        }
        guard !p.pending.isEmpty else { return }
        for event in p.pending {
            if event.height < 0 {
                release(p, vel: event.vel, id: id)          // the whole heap lets go
            } else {
                let pieces = max(1, Int((event.height / 3.5).rounded()))
                for _ in 0..<pieces {
                    spawnClump(at: CGPoint(x: event.at.x + rnd(-1.5, 1.5),
                                           y: event.at.y + rnd(0, max(0.1, event.height))),
                               vel: CGVector(dx: event.vel.dx * 0.5 + rnd(-40, 40),
                                             dy: event.vel.dy * 0.4 + rnd(10, 80)),
                               sourceID: id)
                }
            }
        }
        p.pending.removeAll()
    }

    func updateDock() {
        var r: CGRect? = nil
        var status: String
        if let f = dockTracker.frame() {
            var s = CGRect(x: f.minX - Cfg.dockPad, y: size.height - f.maxY,
                           width: f.width + 2 * Cfg.dockPad, height: f.height)
            // The AX frame can reach a bit above the visible Dock shelf. When the Dock is always
            // shown, the space macOS reserves for it (bottom of visibleFrame) is a better top edge.
            if let screen = NSScreen.screens.first {
                let reserved = screen.visibleFrame.minY - screen.frame.minY
                if reserved > 10 && reserved < s.maxY { s.size.height = reserved - s.minY }
            }
            // Only handle a Dock that sits at the bottom of the screen and is currently on screen.
            // With auto-hide, a hidden Dock is reported below the screen edge, so it fails this check.
            if s.width > s.height && s.minY < 40 && s.maxY > 8 {
                r = s
                status = "found at x=\(Int(s.minX)) width=\(Int(s.width)) top=\(Int(s.maxY)) (AX top \(Int(size.height - f.minY)), screen \(Int(size.width))x\(Int(size.height)))"
            } else {
                status = "ignored (not at bottom or hidden), AX frame = \(f)"
            }
        } else {
            status = "not found: \(dockTracker.lastError)"
        }
        // Log only when the status changes, so the terminal doesn't get flooded
        let key = status.components(separatedBy: " at ").first ?? status
        if key != lastDockStatus {
            print("❄︎ Dock " + status)
            lastDockStatus = key
        }
        if let old = dockRect, let r = r,
           abs(old.minX - r.minX) < 0.5, abs(old.width - r.width) < 0.5, abs(old.maxY - r.maxY) < 0.5 {
            return
        }
        // Dock resized (new app opened, magnification): drop its snow and start again
        if let p = dockPile {
            release(p, vel: .zero, id: SnowScene.dockID)
            p.remove()
            dockPile = nil
        }
        dockRect = r
        if let r = r {
            dockPile = Pile(minX: r.minX, topY: r.maxY + Cfg.dockTopOffset, width: r.width,
                            maxH: Cfg.dockPileMax, parent: world)
        }
    }

    // Parts of a window top hidden behind a front window get no snow and aren't drawn
    func computeOcclusion() {
        for (i, item) in order.enumerated() {
            guard let p = piles[item.id] else { continue }
            for c in 0..<p.count {
                let pt = CGPoint(x: p.colX(c), y: p.baseY + (p.isWindow ? p.bed[c] : 0) + 1)
                var o = pt.x < 0 || pt.x > size.width || pt.y > size.height
                if !o {
                    for j in 0..<i where order[j].rect.contains(pt) { o = true; break }
                }
                if o != p.occ[c] {
                    p.occ[c] = o
                    if o { p.h[c] = 0 }
                    p.dirty = true
                }
            }
        }
        if let g = ground {
            for c in 0..<g.count {
                let pt = CGPoint(x: g.colX(c), y: 1)
                var o = false
                for item in order where item.rect.contains(pt) { o = true; break }
                if o != g.occ[c] {
                    g.occ[c] = o
                    if o { g.h[c] = 0 }
                    g.dirty = true
                }
            }
        }
    }

    // MARK: Cursor wake

    /// The cursor drags a little air with it. Remember where it is and how fast it goes, so the falling flakes
    /// it sweeps through can be stirred by its wake (ported from Snowhush's track_cursor / cursor_wake).
    func trackCursor(_ dt: CGFloat) {
        let m = NSEvent.mouseLocation
        guard cursorSeen else {
            cursorSeen = true
            cursorPos = m
            return
        }
        let delta = CGVector(dx: m.x - cursorPos.x, dy: m.y - cursorPos.y)
        cursorPos = m
        guard dt > 0 else { return }
        var v = CGVector(dx: delta.dx / dt, dy: delta.dy / dt)
        let speed = (v.dx * v.dx + v.dy * v.dy).squareRoot()
        if speed > 3000 {                    // a jump across the screen isn't a hand movement
            v.dx *= 3000 / speed
            v.dy *= 3000 / speed
        }
        // Smooth it, so one twitchy frame doesn't send the snow flying
        cursorVel = CGVector(dx: cursorVel.dx + (v.dx - cursorVel.dx) * 0.5,
                             dy: cursorVel.dy + (v.dy - cursorVel.dy) * 0.5)
    }

    func stepFlakes(_ dt: CGFloat) {
        // A few sines at different frequencies add up to gusty wind
        let wind = 14 * sin(t * 0.11) + 9 * sin(t * 0.37 + 1.3) + 6 * sin(t * 0.9 + 0.4)
        // The air a moving cursor drags along, which carries off the flakes it sweeps through
        var wake: CGVector?
        let wakeSpeed = (cursorVel.dx * cursorVel.dx + cursorVel.dy * cursorVel.dy).squareRoot()
        if wakeSpeed > Cfg.cursorWakeMinSpeed {
            let s = min(1, Cfg.cursorWakeMaxSpeed / wakeSpeed)
            wake = CGVector(dx: cursorVel.dx * s, dy: cursorVel.dy * s)
        }
        var normal = 0
        var i = flakes.count - 1
        while i >= 0 {
            let f = flakes[i]
            var p = f.node.position
            let prevY = p.y

            // Stir flakes near the cursor toward its wake: the nearer the flake, the stronger the pull.
            if let w = wake {
                let dx = p.x - cursorPos.x, dy = p.y - cursorPos.y
                let d2 = dx * dx + dy * dy
                let r = Cfg.cursorWakeRadius
                if d2 < r * r {
                    let falloff = 1 - d2.squareRoot() / r
                    let k = min(1, falloff * falloff * 4 * dt)
                    f.push.dx += (w.dx - f.push.dx) * k
                    f.push.dy += (w.dy - f.push.dy) * k
                }
            }

            if f.isClump {
                f.vel.dy -= Cfg.gravity * dt
                f.vel.dx *= max(0, 1 - 1.2 * dt)
                p.x += (f.vel.dx + f.push.dx) * dt
                p.y += (f.vel.dy + f.push.dy) * dt
            } else {
                let sway = sin(t * f.swayFreq + f.phase) * f.swayAmp
                p.x += (wind * f.windFactor + sway + f.push.dx) * dt
                p.y += (f.vel.dy + f.push.dy) * dt
                if p.x < -40 { p.x += size.width + 80 } else if p.x > size.width + 40 { p.x -= size.width + 80 }
            }
            // The air calms again once the cursor is gone
            let drag = max(0, 1 - 2.4 * dt)
            f.push.dx *= drag
            f.push.dy *= drag

            var gone = false
            if p.y < prevY {
                // The Dock is always in front of every window, so check it first
                if let d = dockPile, let c = d.col(at: p.x),
                   !(f.isClump && f.ignoreID == SnowScene.dockID && t < f.ignoreUntil) {
                    let s = d.surface(c)
                    if prevY >= s && p.y < s {
                        d.add(at: c, amount: (f.isClump ? 1.6 : f.size * 0.16) * Cfg.dockGain)
                        gone = true
                    }
                }
                // Then check window tops, front to back
                if !gone && (Cfg.snowOverWindows || !f.inFront) { for item in order {
                    guard let pile = piles[item.id] else { continue }
                    if f.isClump && item.id == f.ignoreID && t < f.ignoreUntil { continue }
                    guard let c = pile.col(at: p.x), !pile.occ[c] else { continue }
                    let s = pile.surface(c)
                    if prevY >= s && p.y < s {
                        pile.add(at: c, amount: f.isClump ? 2.4 : f.size * 0.40)
                        gone = true
                        break
                    }
                } }
                // Finally the bottom of the screen
                if !gone, let g = ground, let c = g.col(at: p.x), p.y < g.surface(c) {
                    if !g.occ[c] { g.add(at: c, amount: f.isClump ? 1.6 : f.size * 0.12) }
                    gone = true
                }
            }
            if !gone {
                // Snow falls in front of open windows (like Snowhush), so you can watch it land on their top
                // edges. With snowOverWindows off, flakes that fall "behind" a window disappear instead.
                if !Cfg.snowOverWindows && !f.inFront {
                    for item in order where item.rect.contains(p) { gone = true; break }
                }
                if p.y < -20 { gone = true }
                if f.isClump && (p.x < -80 || p.x > size.width + 80) { gone = true }
            }

            if gone {
                recycle(at: i)
            } else {
                f.node.position = p
                if !f.isClump { normal += 1 }
            }
            i -= 1
        }

        // Top up flakes (max 6 per frame so they don't appear in a row)
        let deficit = min(6, Cfg.targetFlakes - normal)
        if deficit > 0 { for _ in 0..<deficit { spawnFlake() } }
    }
}

// MARK: - Transparent full-screen window + menu bar icon

/// Lets the very first click reach the scene even though this app is never the active app
final class OverlaySKView: SKView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class OverlayWindow: NSPanel {
    // Stop macOS from pushing the window below the menu bar
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: OverlayWindow!
    var scene: SnowScene!
    var statusItem: NSStatusItem!
    var pauseItem: NSMenuItem!
    var amountItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.screens.first else { return }
        // A non-activating panel can take a click (to grab a snowball) without stealing focus from your apps
        window = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true          // clicks pass straight through
        window.level = .floating                  // above normal windows, below the Dock and menu bar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = OverlaySKView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.allowsTransparency = true
        view.preferredFramesPerSecond = 60
        view.ignoresSiblingOrder = true
        scene = SnowScene(size: screen.frame.size)
        scene.scaleMode = .resizeFill
        view.presentScene(scene)
        window.contentView = view
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()

        setupMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Stop rendering while the display sleeps or the screen is locked; otherwise SpriteKit
        // logs "no drawables available" because nothing is being shown.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(self, selector: #selector(suspendRendering), name: name, object: nil)
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(self, selector: #selector(resumeRendering), name: name, object: nil)
        }
    }

    @objc func suspendRendering() {
        (window.contentView as? SKView)?.isPaused = true
    }

    @objc func resumeRendering() {
        // Stay paused if the user paused snow from the menu
        guard !scene.isPaused else { return }
        (window.contentView as? SKView)?.isPaused = false
    }

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "❄︎"
        let menu = NSMenu()

        pauseItem = NSMenuItem(title: "Pause Snow", action: #selector(togglePause), keyEquivalent: "p")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let amount = NSMenuItem(title: "Snow Amount", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, n) in [("Light", 120), ("Medium", 260), ("Heavy", 500)] {
            let it = NSMenuItem(title: title, action: #selector(setAmount(_:)), keyEquivalent: "")
            it.target = self
            it.tag = n
            it.state = (n == Cfg.targetFlakes) ? .on : .off
            sub.addItem(it)
            amountItems.append(it)
        }
        amount.submenu = sub
        menu.addItem(amount)

        let clear = NSMenuItem(title: "Clear Snow", action: #selector(clearSnow), keyEquivalent: "c")
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func togglePause() {
        scene.isPaused.toggle()
        if scene.isPaused {
            window.orderOut(nil)
            pauseItem.title = "Resume Snow"
        } else {
            window.orderFrontRegardless()
            pauseItem.title = "Pause Snow"
        }
    }

    @objc func setAmount(_ sender: NSMenuItem) {
        Cfg.targetFlakes = sender.tag
        for it in amountItems { it.state = (it === sender) ? .on : .off }
    }

    @objc func clearSnow() { scene.clearAll() }

    @objc func screensChanged() {
        guard let screen = NSScreen.screens.first else { return }
        window.setFrame(screen.frame, display: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon
app.run()
