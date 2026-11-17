import SceneKit
import SwiftUI

// MARK: - Shared helpers

enum SceneKitHelpers {
    static func points(_ vertices: [SCNVector3], color: NSColor, size: CGFloat) -> SCNGeometry {
        let source = SCNGeometrySource(vertices: vertices)
        let element = SCNGeometryElement(indices: (0..<Int32(vertices.count)).map { $0 }, primitiveType: .point)
        element.pointSize = size
        element.minimumPointScreenSpaceRadius = size * 0.5
        element.maximumPointScreenSpaceRadius = size
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.firstMaterial = flat(color)
        return geometry
    }

    static func polyline(_ vertices: [SCNVector3], color: NSColor, closed: Bool = false) -> SCNGeometry {
        var indices: [Int32] = []
        for i in 0..<(vertices.count - 1) { indices += [Int32(i), Int32(i + 1)] }
        if closed, vertices.count > 2 { indices += [Int32(vertices.count - 1), 0] }
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .line)]
        )
        geometry.firstMaterial = flat(color)
        return geometry
    }

    static func flat(_ color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = color
        m.isDoubleSided = true
        return m
    }

    static func glow(_ color: NSColor) -> SCNMaterial {
        let m = flat(color)
        m.blendMode = .add
        m.writesToDepthBuffer = false
        return m
    }

    /// Unit vector for a compass azimuth and elevation in a scene where +Y is up and -Z is north.
    static func skyDirection(azimuth: Double, elevation: Double) -> simd_float3 {
        let az = Float(azimuth * .pi / 180), el = Float(elevation * .pi / 180)
        return simd_float3(cos(el) * sin(az), sin(el), -cos(el) * cos(az))
    }

    static func label(_ text: String, color: NSColor, size: CGFloat) -> SCNNode {
        let font = NSFont.systemFont(ofSize: 44, weight: .bold)
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let bounds = string.size()
        let image = NSImage(size: NSSize(width: bounds.width + 8, height: bounds.height + 8), flipped: false) { _ in
            string.draw(at: NSPoint(x: 4, y: 4))
            return true
        }
        let plane = SCNPlane(width: size * image.size.width / image.size.height, height: size)
        plane.firstMaterial = flat(.white)
        plane.firstMaterial?.diffuse.contents = image
        let node = SCNNode(geometry: plane)
        node.constraints = [SCNBillboardConstraint()]
        return node
    }

    static func makeView(scene: SCNScene, camera: SCNNode) -> OrbitView {
        let view = OrbitView()
        view.scene = scene
        view.pointOfView = camera
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling2X
        view.isPlaying = true
        view.preferredFramesPerSecond = 30
        view.rendersContinuously = false
        return view
    }
}

// MARK: - Orbit control

/// SCNView with its own orbit handling. The stock camera controller drifts, rolls and lets the
/// scene tumble; this one keeps the horizon level, clamps the tilt, and coasts to a stop.
/// Nothing moves unless the user moves it. Double-click returns to the starting view.
final class OrbitView: SCNView {
    var zoomEnabled = true
    private var target = simd_float3(0, 0, 0)
    private var yaw: Float = 0
    private var pitch: Float = 0.3
    private var distance: Float = 3
    private var pitchRange: ClosedRange<Float> = -1...1
    private var distanceRange: ClosedRange<Float> = 2...6
    private var home: (yaw: Float, pitch: Float, distance: Float) = (0, 0.3, 3)
    private var velocity = simd_float2(0, 0)
    private var goingHome = false
    private var coast: Timer?

    func configure(target: simd_float3, yaw: Float, pitch: Float, distance: Float,
                   pitchRange: ClosedRange<Float>, distanceRange: ClosedRange<Float>) {
        self.target = target
        self.yaw = yaw
        self.pitch = pitch
        self.distance = distance
        self.pitchRange = pitchRange
        self.distanceRange = distanceRange
        home = (yaw, pitch, distance)
        apply()
    }

    private func apply() {
        pitch = min(max(pitch, pitchRange.lowerBound), pitchRange.upperBound)
        distance = min(max(distance, distanceRange.lowerBound), distanceRange.upperBound)
        guard let camera = pointOfView else { return }
        let offset = simd_float3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * distance
        camera.simdPosition = target + offset
        camera.simdLook(at: target, up: [0, 1, 0], localFront: [0, 0, -1])
    }

    // Dragging the scene must never drag the window.
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    /// Called with the pointer's place in the view as it moves, and nil when it leaves.
    var onHover: ((CGPoint?) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        stopCoasting()
        if event.clickCount == 2 {
            goingHome = true
            startCoasting()
            return
        }
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        // Grab-and-turn: the scene follows the pointer.
        let dx = Float(event.deltaX) * 0.0075, dy = Float(event.deltaY) * 0.0075
        yaw -= dx
        pitch += dy
        velocity = simd_float2(-dx, dy)
        apply()
    }

    override func mouseUp(with event: NSEvent) {
        guard event.clickCount < 2 else { return }
        NSCursor.pop()
        if simd_length(velocity) > 0.004 { startCoasting() } else { velocity = .zero }
    }

    override func scrollWheel(with event: NSEvent) {
        guard zoomEnabled else {
            nextResponder?.scrollWheel(with: event)
            return
        }
        let delta = Float(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.004 : event.scrollingDeltaY * 0.04)
        distance *= exp(-delta)
        apply()
    }

    override func magnify(with event: NSEvent) {
        guard zoomEnabled else { return }
        distance *= 1 - Float(event.magnification)
        apply()
    }

    private func startCoasting() {
        coast?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        coast = timer
    }

    private func stopCoasting() {
        coast?.invalidate()
        coast = nil
        velocity = .zero
        goingHome = false
    }

    private func step() {
        if goingHome {
            // Take the short way round on yaw.
            var dyaw = (home.yaw - yaw).truncatingRemainder(dividingBy: 2 * .pi)
            if dyaw > .pi { dyaw -= 2 * .pi }
            if dyaw < -.pi { dyaw += 2 * .pi }
            yaw += dyaw * 0.16
            pitch += (home.pitch - pitch) * 0.16
            distance += (home.distance - distance) * 0.16
            apply()
            if abs(dyaw) < 0.002, abs(home.pitch - pitch) < 0.002, abs(home.distance - distance) < 0.004 { stopCoasting() }
            return
        }
        yaw += velocity.x
        pitch += velocity.y
        velocity *= 0.92
        apply()
        if simd_length(velocity) < 0.0004 { stopCoasting() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopCoasting() }
    }
}

// MARK: - Globe

/// Dotted Earth centered on the dish, with the constellation shell and the dish's beam.
/// Satellite positions are illustrative: the shell geometry is real (53° planes), the timing and altitude are not.
@MainActor
final class GlobeScene {
    let scene = SCNScene()
    let camera = SCNNode()
    private let earth = SCNNode()
    private let marker = SCNNode()
    private let beam = SCNNode()
    private var placed: String?
    private static let shell: Float = 1.16
    /// The stand-in constellation, shown until real orbits are loaded.
    private var standIn: [SCNNode] = []
    private let constellation = SCNNode()

    init() {
        let cam = SCNCamera()
        cam.fieldOfView = 34
        cam.zNear = 0.1
        cam.zFar = 50
        camera.camera = cam
        scene.rootNode.addChildNode(camera)

        let sway = SCNNode()
        scene.rootNode.addChildNode(sway)
        sway.addChildNode(earth)

        buildEarth()
        buildConstellation()
        buildStars()
        earth.addChildNode(marker)
        earth.addChildNode(beam)
    }

    private func buildEarth() {
        let sphere = SCNSphere(radius: 0.994)
        sphere.segmentCount = 96
        let surface = SCNMaterial()
        surface.lightingModel = .constant
        surface.diffuse.contents = NSColor(red: 0.015, green: 0.02, blue: 0.035, alpha: 1)
        // Rim light: brightens where the surface turns away from the camera.
        surface.shaderModifiers = [.fragment: """
        float rim = 1.0 - max(dot(normalize(_surface.view), normalize(_surface.normal)), 0.0);
        _output.color.rgb += vec3(0.22, 0.48, 1.0) * pow(rim, 4.2) * 0.65;
        """]
        sphere.firstMaterial = surface
        earth.addChildNode(SCNNode(geometry: sphere))

        let halo = SCNSphere(radius: 1.2)
        halo.segmentCount = 64
        let haze = SCNMaterial()
        haze.lightingModel = .constant
        haze.diffuse.contents = NSColor.black
        haze.cullMode = .front
        haze.blendMode = .add
        haze.writesToDepthBuffer = false
        haze.shaderModifiers = [.fragment: """
        float facing = abs(dot(normalize(_surface.view), normalize(_surface.normal)));
        float a = pow(facing, 5.0) * 0.55;
        _output.color = vec4(vec3(0.16, 0.40, 1.0) * a, a);
        """]
        halo.firstMaterial = haze
        earth.addChildNode(SCNNode(geometry: halo))

        // One dot per land cell on an equal-area-ish grid, so the poles don't clump.
        guard let mask = Data(base64Encoded: GlobeData.landBase64) else { return }
        var dots: [SCNVector3] = []
        var lat = -88.0
        while lat <= 88 {
            let step = 1.6 / max(cos(lat * .pi / 180), 0.08)
            var lon = -180.0
            while lon < 180 {
                let x = min(GlobeData.width - 1, Int(lon + 180)), y = min(GlobeData.height - 1, Int(90 - lat))
                let bit = y * GlobeData.width + x
                if mask[bit / 8] & (1 << UInt8(bit % 8)) != 0 { dots.append(SCNVector3(Self.position(lat: lat, lon: lon, radius: 1))) }
                lon += step
            }
            lat += 1.6
        }
        earth.addChildNode(SCNNode(geometry: SceneKitHelpers.points(dots, color: NSColor(white: 1, alpha: 0.82), size: 2.6)))
    }

    private func buildConstellation() {
        let planes = 22, perPlane = 16
        for p in 0..<planes {
            let plane = SCNNode()
            let raan = Float(p) / Float(planes) * 2 * .pi
            plane.simdOrientation = simd_quatf(angle: raan, axis: [0, 1, 0]) * simd_quatf(angle: 53 * .pi / 180, axis: [0, 0, 1])
            earth.addChildNode(plane)
            standIn.append(plane)

            // Faint orbit track so the shell reads as planes, not noise.
            let track = stride(from: 0.0, to: 360.0, by: 3).map { deg -> SCNVector3 in
                let a = Float(deg * .pi / 180)
                return SCNVector3(Self.shell * cos(a), 0, Self.shell * sin(a))
            }
            plane.addChildNode(SCNNode(geometry: SceneKitHelpers.polyline(track, color: NSColor(red: 0.45, green: 0.68, blue: 1, alpha: 0.10), closed: true)))

            let ring = SCNNode()
            var sats: [SCNVector3] = []
            for s in 0..<perPlane {
                let a = (Float(s) + Float(p % 2) * 0.5) / Float(perPlane) * 2 * .pi
                sats.append(SCNVector3(Self.shell * cos(a), 0, Self.shell * sin(a)))
            }
            ring.geometry = SceneKitHelpers.points(sats, color: NSColor(red: 0.80, green: 0.92, blue: 1, alpha: 1), size: 3.6)
            ring.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 150)))
            plane.addChildNode(ring)
        }
    }

    /// Draws the real constellation. Positions are Earth-fixed, in Earth radii.
    func update(shell positions: [SIMD3<Float>]) {
        guard !positions.isEmpty else { return }
        if constellation.parent == nil { earth.addChildNode(constellation) }
        standIn.forEach { $0.isHidden = true }
        let points = positions.map { p -> SCNVector3 in
            // Earth-fixed axes to the globe's: x toward 90° east, y toward the north pole, z toward 0° longitude.
            // Height above the surface is doubled so the shell stands clear of the globe at this size.
            let radius = simd_length(p)
            let lifted = 1 + (radius - 1) * 2
            return SCNVector3(simd_float3(p.y, p.z, p.x) / radius * lifted)
        }
        // Smaller and bluer than the land dots, so ten thousand of them don't drown the continents.
        constellation.geometry = SceneKitHelpers.points(points, color: NSColor(red: 0.50, green: 0.72, blue: 1, alpha: 0.6), size: 1.3)
    }

    private func buildStars() {
        var generator = SystemRandomNumberGenerator()
        var stars: [SCNVector3] = []
        for _ in 0..<420 {
            let u = Float.random(in: -1...1, using: &generator), t = Float.random(in: 0..<(2 * .pi), using: &generator)
            let r = (1 - u * u).squareRoot()
            stars.append(SCNVector3(r * cos(t) * 18, u * 18, r * sin(t) * 18))
        }
        scene.rootNode.addChildNode(SCNNode(geometry: SceneKitHelpers.points(stars, color: NSColor(white: 1, alpha: 0.35), size: 1.4)))
    }

    static func position(lat: Double, lon: Double, radius: Float) -> simd_float3 {
        let la = Float(lat * .pi / 180), lo = Float(lon * .pi / 180)
        return simd_float3(cos(la) * sin(lo), sin(la), cos(la) * cos(lo)) * radius
    }

    func update(country: String?, azimuth: Double?, elevation: Double?, color: NSColor, online: Bool) {
        guard let country, let (lat, lon) = GlobeData.centroids[country.uppercased()] else {
            marker.isHidden = true
            beam.isHidden = true
            return
        }
        let key = "\(country)-\(Int(azimuth ?? 0))-\(Int(elevation ?? 0))-\(online)-\(color.hashValue)"
        guard key != placed else { return }
        placed = key

        // Turn the globe so the dish sits just below the middle of the view.
        let la = Float(lat * .pi / 180) * 0.82, lo = Float(lon * .pi / 180)
        earth.simdOrientation = simd_quatf(angle: la, axis: [1, 0, 0]) * simd_quatf(angle: -lo, axis: [0, 1, 0])

        let p = Self.position(lat: lat, lon: lon, radius: 1.002)
        let up = simd_normalize(p)

        marker.isHidden = false
        marker.childNodes.forEach { $0.removeFromParentNode() }
        marker.simdPosition = p
        marker.simdOrientation = simd_quatf(from: [0, 1, 0], to: up)
        let core = SCNSphere(radius: 0.013)
        core.firstMaterial = SceneKitHelpers.flat(color)
        marker.addChildNode(SCNNode(geometry: core))
        for delay in [0.0, 1.1] {
            let ring = SCNTorus(ringRadius: 0.03, pipeRadius: 0.0022)
            ring.firstMaterial = SceneKitHelpers.glow(color)
            let node = SCNNode(geometry: ring)
            node.opacity = 0
            let pulse = SCNAction.sequence([
                .group([.scale(to: 0.6, duration: 0), .fadeOpacity(to: 0.95, duration: 0)]),
                .group([.scale(to: 4.2, duration: 2.2), .fadeOut(duration: 2.2)]),
            ])
            node.runAction(.sequence([.wait(duration: delay), .repeatForever(pulse)]))
            marker.addChildNode(node)
        }

        beam.childNodes.forEach { $0.removeFromParentNode() }
        beam.isHidden = !online
        guard online, let azimuth, let elevation else { return }
        // Local east/north/up at the dish, then the boresight in that frame.
        let east = simd_normalize(simd_cross(simd_float3(0, 1, 0), up))
        let north = simd_cross(up, east)
        let az = Float(azimuth * .pi / 180), el = Float(max(elevation, 25) * .pi / 180)
        let dir = simd_normalize(cos(el) * (sin(az) * east + cos(az) * north) + sin(el) * up)
        // Distance along the boresight until it reaches the shell.
        let b = simd_dot(p, dir)
        let length = -b + (b * b - simd_length_squared(p) + Self.shell * Self.shell).squareRoot()

        let shaft = SCNCylinder(radius: 0.0035, height: CGFloat(length))
        shaft.firstMaterial = SceneKitHelpers.glow(color.withAlphaComponent(0.9))
        let shaftNode = SCNNode(geometry: shaft)
        shaftNode.simdPosition = p + dir * length / 2
        shaftNode.simdOrientation = simd_quatf(from: [0, 1, 0], to: dir)
        beam.addChildNode(shaftNode)

        let target = SCNSphere(radius: 0.02)
        target.firstMaterial = SceneKitHelpers.glow(color)
        let targetNode = SCNNode(geometry: target)
        targetNode.simdPosition = p + dir * length
        targetNode.runAction(.repeatForever(.sequence([.scale(to: 1.5, duration: 0.9), .scale(to: 0.9, duration: 0.9)])))
        beam.addChildNode(targetNode)
    }
}

struct GlobeView: NSViewRepresentable {
    var country: String?
    var azimuth: Double?
    var elevation: Double?
    var color: Color
    var online: Bool
    var shell: [SIMD3<Float>] = []

    func makeCoordinator() -> GlobeScene { GlobeScene() }

    func makeNSView(context: Context) -> OrbitView {
        let view = SceneKitHelpers.makeView(scene: context.coordinator.scene, camera: context.coordinator.camera)
        view.configure(target: [0, 0.06, 0], yaw: 0, pitch: 0.06, distance: 3.5,
                       pitchRange: -1.1...1.1, distanceRange: 3.5...3.5)
        // Leave scrolling to the page: the globe sits inside a scroll view.
        view.zoomEnabled = false
        return view
    }

    func updateNSView(_ view: OrbitView, context: Context) {
        context.coordinator.update(country: country, azimuth: azimuth, elevation: elevation, color: NSColor(color), online: online)
        context.coordinator.update(shell: shell)
    }
}

// MARK: - Sky dome

/// The obstruction map wrapped onto the sky hemisphere above a model of the dish. Drag to orbit.
@MainActor
final class DomeScene {
    let scene = SCNScene()
    let camera = SCNNode()
    private let turntable = SCNNode()
    private let domeMaterial = SCNMaterial()
    private let dish = SCNNode()
    private let beam = SCNNode()
    private var maxTheta = 80.0
    private var domeNode: SCNNode?
    private let satellites = SCNNode()
    private var satellitePool: [SCNNode] = []
    private let tails = SCNNode()
    private let link = SCNNode()
    private let pulse = SCNNode()
    private var linkEnd: simd_float3?
    private var shown: [VisibleSatellite] = []
    private var bestID: Int?
    private var hoveredID: Int?
    private var hoverLabel: SCNNode?
    private var bestLabel: SCNNode?
    private var bestName: String?

    init() {
        let cam = SCNCamera()
        cam.fieldOfView = 38
        cam.zNear = 0.05
        cam.zFar = 50
        camera.camera = cam
        scene.rootNode.addChildNode(camera)
        scene.rootNode.addChildNode(turntable)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 500
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)
        let key = SCNLight()
        key.type = .directional
        key.intensity = 900
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-1.0, 0.6, 0)
        scene.rootNode.addChildNode(keyNode)

        buildGround()
        buildGrid()
        buildDish()
        rebuildDome()
        turntable.addChildNode(satellites)
        turntable.addChildNode(tails)
        turntable.addChildNode(link)

        // A bead that runs up the dashed line, so it reads as a live link and not a ruler.
        let bead = SCNSphere(radius: 0.012)
        bead.segmentCount = 10
        bead.firstMaterial = SceneKitHelpers.glow(.white)
        pulse.geometry = bead
        pulse.isHidden = true
        pulse.renderingOrder = 23
        turntable.addChildNode(pulse)
        let from = simd_float3(0, 0.1, 0)
        pulse.runAction(.repeatForever(.customAction(duration: 1.3) { [weak self] node, elapsed in
            guard let end = self?.linkEnd else { return }
            let f = Float(elapsed / 1.3)
            node.simdPosition = from + (end - from) * f
            node.opacity = CGFloat(sin(f * .pi))
        }))
    }

    /// Puts a bead on the dome for each satellite, with a short line toward where it's heading.
    func update(sky: SkyOverlay) {
        while satellitePool.count < sky.satellites.count {
            let bead = SCNSphere(radius: 0.011)
            bead.segmentCount = 10
            bead.firstMaterial = SceneKitHelpers.flat(.white)
            let node = SCNNode(geometry: bead)
            node.renderingOrder = 20
            satellites.addChildNode(node)
            satellitePool.append(node)
        }
        shown = sky.satellites
        bestID = sky.best
        if let hoveredID, !shown.contains(where: { $0.id == hoveredID }) { setHovered(nil) }
        var segments: [SCNVector3] = []
        var best: (simd_float3, String)?
        for (i, node) in satellitePool.enumerated() {
            guard i < sky.satellites.count else { node.isHidden = true; continue }
            let sat = sky.satellites[i]
            let inRange = sat.elevation >= SkyWatch.serviceElevation
            let p = SceneKitHelpers.skyDirection(azimuth: sat.azimuth, elevation: sat.elevation) * 1.012
            node.isHidden = false
            node.simdPosition = p
            node.simdScale = simd_float3(repeating: sat.id == sky.best ? 2 : sat.id == hoveredID ? 1.8 : inRange ? 1 : 0.6)
            if sat.id == hoveredID { hoverLabel?.simdPosition = p * 1.12 }
            node.opacity = inRange ? 1 : 0.45
            if let next = sky.ahead[sat.id] {
                let q = SceneKitHelpers.skyDirection(azimuth: next.azimuth, elevation: next.elevation) * 1.012
                let step = q - p
                if simd_length(step) > 0.0005 {
                    segments.append(SCNVector3(p))
                    segments.append(SCNVector3(p + simd_normalize(step) * 0.035))
                }
            }
            if sat.id == sky.best { best = (p, sat.name) }
        }
        if segments.isEmpty {
            tails.geometry = nil
        } else {
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: segments)],
                                       elements: [SCNGeometryElement(indices: (0..<Int32(segments.count)).map { $0 }, primitiveType: .line)])
            geometry.firstMaterial = SceneKitHelpers.flat(NSColor(white: 1, alpha: 0.55))
            tails.geometry = geometry
        }
        if best?.1 != bestName {
            bestLabel?.removeFromParentNode()
            bestLabel = best.map { SceneKitHelpers.label($0.1, color: .white, size: 0.07) }
            bestLabel.map(turntable.addChildNode)
            bestName = best?.1
        }
        if let best { bestLabel?.simdPosition = best.0 * 1.12 }

        applyLink(best)
    }

    /// Names the satellite under the pointer. `point` is in the view's own coordinates.
    func hover(at point: CGPoint?, in view: SCNView) {
        guard let point else { setHovered(nil); return }
        var found: Int?
        var closest: CGFloat = 13
        for (i, node) in satellitePool.enumerated() where i < shown.count && !node.isHidden {
            let projected = view.projectPoint(node.worldPosition)
            // Behind the camera.
            guard projected.z < 1 else { continue }
            let d = hypot(CGFloat(projected.x) - point.x, CGFloat(projected.y) - point.y)
            if d < closest { closest = d; found = shown[i].id }
        }
        setHovered(found)
    }

    private func setHovered(_ id: Int?) {
        guard id != hoveredID else { return }
        hoveredID = id
        hoverLabel?.removeFromParentNode()
        hoverLabel = nil
        for (i, node) in satellitePool.enumerated() where i < shown.count {
            let sat = shown[i]
            let inRange = sat.elevation >= SkyWatch.serviceElevation
            node.simdScale = simd_float3(repeating: sat.id == bestID ? 2 : sat.id == id ? 1.8 : inRange ? 1 : 0.6)
            // The best placed one already carries its name.
            if sat.id == id, sat.id != bestID {
                let label = SceneKitHelpers.label(String(format: "%@ · %.0f° up", sat.name, sat.elevation), color: .white, size: 0.065)
                label.simdPosition = node.simdPosition * 1.11
                label.renderingOrder = 30
                turntable.addChildNode(label)
                hoverLabel = label
            }
        }
    }

    private func applyLink(_ best: (simd_float3, String)?) {
        linkEnd = best?.0
        pulse.isHidden = best == nil
        // A dashed line from the dish to the satellite it's most likely talking to.
        if let best {
            let from = simd_float3(0, 0.1, 0)
            let dashes = 22
            var points: [SCNVector3] = []
            for i in 0..<dashes {
                let a = Float(i) / Float(dashes), b = (Float(i) + 0.55) / Float(dashes)
                points.append(SCNVector3(from + (best.0 - from) * a))
                points.append(SCNVector3(from + (best.0 - from) * b))
            }
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: points)],
                                       elements: [SCNGeometryElement(indices: (0..<Int32(points.count)).map { $0 }, primitiveType: .line)])
            geometry.firstMaterial = SceneKitHelpers.flat(NSColor(white: 1, alpha: 0.8))
            link.geometry = geometry
            link.renderingOrder = 21
        } else {
            link.geometry = nil
        }
    }

    private func buildGround() {
        let disc = SCNCylinder(radius: 1, height: 0.004)
        disc.radialSegmentCount = 96
        disc.firstMaterial = SceneKitHelpers.flat(NSColor(white: 1, alpha: 0.045))
        disc.firstMaterial?.writesToDepthBuffer = false
        let node = SCNNode(geometry: disc)
        node.position.y = -0.004
        turntable.addChildNode(node)

        for (text, az) in [("N", 0.0), ("E", 90.0), ("S", 180.0), ("W", 270.0)] {
            let color = text == "N" ? NSColor(Palette.bad) : NSColor(white: 1, alpha: 0.6)
            let label = SceneKitHelpers.label(text, color: color, size: 0.11)
            label.simdPosition = SceneKitHelpers.skyDirection(azimuth: az, elevation: 0) * 1.13 + simd_float3(0, 0.03, 0)
            turntable.addChildNode(label)
        }
    }

    private func buildGrid() {
        let faint = NSColor(white: 1, alpha: 0.13)
        for elevation in [0.0, 30.0, 60.0] {
            let ring = stride(from: 0.0, to: 360.0, by: 3).map {
                SCNVector3(SceneKitHelpers.skyDirection(azimuth: $0, elevation: elevation))
            }
            turntable.addChildNode(SCNNode(geometry: SceneKitHelpers.polyline(ring, color: elevation == 0 ? NSColor(white: 1, alpha: 0.3) : faint, closed: true)))
        }
        for azimuth in stride(from: 0.0, to: 360.0, by: 45) {
            let arc = stride(from: 0.0, through: 90.0, by: 3).map {
                SCNVector3(SceneKitHelpers.skyDirection(azimuth: azimuth, elevation: $0))
            }
            turntable.addChildNode(SCNNode(geometry: SceneKitHelpers.polyline(arc, color: faint)))
        }
    }

    private func buildDish() {
        let stand = SCNCylinder(radius: 0.012, height: 0.1)
        stand.firstMaterial?.diffuse.contents = NSColor(white: 0.55, alpha: 1)
        let standNode = SCNNode(geometry: stand)
        standNode.position.y = 0.05
        turntable.addChildNode(standNode)

        // The Mini is a flat slab, so a rounded box reads right. Its top face looks along the boresight.
        let panel = SCNBox(width: 0.2, height: 0.014, length: 0.26, chamferRadius: 0.006)
        let face = SCNMaterial()
        face.lightingModel = .physicallyBased
        face.diffuse.contents = NSColor(white: 0.92, alpha: 1)
        face.roughness.contents = 0.45
        panel.materials = [face]
        dish.geometry = panel
        dish.position.y = 0.1
        turntable.addChildNode(dish)

        beam.position.y = 0.1
        turntable.addChildNode(beam)
    }

    /// Hemisphere mesh whose texture coordinates point straight into the dish's polar map image.
    private func rebuildDome() {
        domeNode?.removeFromParentNode()
        var vertices: [SCNVector3] = []
        var uvs: [CGPoint] = []
        var indices: [Int32] = []
        let azSteps = 72, elSteps = 30
        for e in 0...elSteps {
            let elevation = Double(e) / Double(elSteps) * 90
            // Radius in the polar image: zenith at the center, max theta at the edge.
            let r = (90 - elevation) / maxTheta
            for a in 0...azSteps {
                let azimuth = Double(a) / Double(azSteps) * 360
                vertices.append(SCNVector3(SceneKitHelpers.skyDirection(azimuth: azimuth, elevation: elevation)))
                let rad = azimuth * .pi / 180
                uvs.append(CGPoint(x: 0.5 + r * sin(rad) / 2, y: 0.5 - r * cos(rad) / 2))
            }
        }
        let row = Int32(azSteps + 1)
        for e in 0..<Int32(elSteps) {
            for a in 0..<Int32(azSteps) {
                let i = e * row + a
                indices += [i, i + 1, i + row, i + 1, i + row + 1, i + row]
            }
        }
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(textureCoordinates: uvs)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )
        domeMaterial.lightingModel = .constant
        domeMaterial.isDoubleSided = true
        domeMaterial.blendMode = .alpha
        domeMaterial.writesToDepthBuffer = false
        domeMaterial.diffuse.magnificationFilter = .nearest
        domeMaterial.diffuse.minificationFilter = .linear
        domeMaterial.diffuse.wrapS = .clampToBorder
        domeMaterial.diffuse.wrapT = .clampToBorder
        domeMaterial.diffuse.borderColor = NSColor.clear
        if domeMaterial.diffuse.contents == nil { domeMaterial.diffuse.contents = NSColor.clear }
        geometry.firstMaterial = domeMaterial
        let node = SCNNode(geometry: geometry)
        node.renderingOrder = 10
        turntable.addChildNode(node)
        domeNode = node
    }

    func update(map: ObstructionMap?, alignment: Alignment?) {
        if let map {
            if abs(map.maxTheta - maxTheta) > 0.5 {
                maxTheta = map.maxTheta
                rebuildDome()
            }
            domeMaterial.diffuse.contents = ObstructionMapView.render(map, dome: true)
        }

        guard let az = alignment?.azimuth, let el = alignment?.elevation else {
            beam.isHidden = true
            return
        }
        let dir = SceneKitHelpers.skyDirection(azimuth: az, elevation: el)
        // Face normal along the boresight, long edge kept pointing "up the slope".
        dish.simdOrientation = simd_quatf(from: [0, 1, 0], to: dir)

        beam.isHidden = false
        beam.childNodes.forEach { $0.removeFromParentNode() }
        let cone = SCNCone(topRadius: 0.17, bottomRadius: 0.01, height: 0.98)
        cone.radialSegmentCount = 48
        cone.firstMaterial = SceneKitHelpers.glow(NSColor(Palette.accent).withAlphaComponent(0.07))
        let coneNode = SCNNode(geometry: cone)
        coneNode.simdPosition = dir * 0.49
        coneNode.simdOrientation = simd_quatf(from: [0, 1, 0], to: dir)
        beam.addChildNode(coneNode)

        // A ring where the dish's face is aimed. A ring, not a ball, so it can't be mistaken for a satellite.
        let ring = SCNTorus(ringRadius: 0.05, pipeRadius: 0.006)
        ring.ringSegmentCount = 48
        ring.firstMaterial = SceneKitHelpers.flat(NSColor(Palette.power))
        ring.firstMaterial?.readsFromDepthBuffer = false
        let ringNode = SCNNode(geometry: ring)
        ringNode.renderingOrder = 22
        ringNode.simdPosition = dir * 1.0
        ringNode.simdOrientation = simd_quatf(from: [0, 1, 0], to: dir)
        beam.addChildNode(ringNode)
    }
}

struct DomeView: NSViewRepresentable {
    var map: ObstructionMap?
    var alignment: Alignment?
    var sky = SkyOverlay()

    func makeCoordinator() -> DomeScene { DomeScene() }

    func makeNSView(context: Context) -> OrbitView {
        let view = SceneKitHelpers.makeView(scene: context.coordinator.scene, camera: context.coordinator.camera)
        let scene = context.coordinator
        view.onHover = { [weak view] point in
            guard let view else { return }
            scene.hover(at: point, in: view)
        }
        // Pulled back far enough that the whole horizon ring, and the satellites on it, sit clear of
        // the title above and the time-lapse bar below.
        view.configure(target: [0, 0.22, 0], yaw: 0.35, pitch: 0.5, distance: 4.0,
                       pitchRange: 0.06...1.5, distanceRange: 1.6...6.5)
        return view
    }

    func updateNSView(_ view: OrbitView, context: Context) {
        context.coordinator.update(map: map, alignment: alignment)
        context.coordinator.update(sky: sky)
    }
}
