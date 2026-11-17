import Foundation
import simd

// Satellite positions for the sky view: TLE parsing, near-earth SGP4
// (Vallado, "Revisiting Spacetrack Report #3", WGS-72), topocentric look
// angles, and a cached Starlink catalog from CelesTrak.

/// One satellite's two-line element set.
struct TLE: Sendable, Hashable {
    var name: String
    var noradID: Int
    var epoch: Date

    /// B* drag term, 1/earth radii.
    var bstar: Double
    /// Radians.
    var inclination: Double
    var raan: Double
    var argPerigee: Double
    var meanAnomaly: Double
    var eccentricity: Double
    /// Kozai mean motion, revolutions per day.
    var meanMotion: Double

    init?(name: String, line1: String, line2: String) {
        let l1 = Array(line1.utf8), l2 = Array(line2.utf8)
        guard l1.count >= 63, l2.count >= 63, l1[0] == UInt8(ascii: "1"), l2[0] == UInt8(ascii: "2") else { return nil }

        func field(_ l: [UInt8], _ a: Int, _ b: Int) -> String {
            String(decoding: l[a..<min(b, l.count)], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
        func number(_ l: [UInt8], _ a: Int, _ b: Int) -> Double? { Double(field(l, a, b)) }
        // TLE exponent notation: " 12345-3" means 0.12345e-3, sign optional.
        func implied(_ l: [UInt8], _ a: Int, _ b: Int) -> Double? {
            var s = field(l, a, b)
            if s.isEmpty { return 0 }
            var sign = 1.0
            if s.hasPrefix("-") { sign = -1; s.removeFirst() } else if s.hasPrefix("+") { s.removeFirst() }
            guard let cut = s.lastIndex(where: { $0 == "-" || $0 == "+" }), cut != s.startIndex else {
                return Double("0." + s).map { sign * $0 }
            }
            guard let mant = Double("0." + s[..<cut]), let exp = Int(s[cut...]) else { return nil }
            return sign * mant * pow(10, Double(exp))
        }

        guard let id = TLE.catalogNumber(field(l1, 2, 7)),
              let id2 = TLE.catalogNumber(field(l2, 2, 7)), id == id2,
              let yy = Int(field(l1, 18, 20)),
              let days = number(l1, 20, 32),
              let bstar = implied(l1, 53, 61),
              let inc = number(l2, 8, 16),
              let raan = number(l2, 17, 25),
              let ecc = Double("0." + field(l2, 26, 33)),
              let argp = number(l2, 34, 42),
              let mo = number(l2, 43, 51),
              let n = number(l2, 52, 63),
              n > 0, ecc < 1, days >= 1, days < 367
        else { return nil }

        let year = yy < 57 ? 2000 + yy : 1900 + yy
        let jd = Orbit.julianDay(year: year, month: 1, day: 1) + (days - 1)

        self.name = name.trimmingCharacters(in: .whitespaces)
        noradID = id
        epoch = Orbit.date(julian: jd)
        self.bstar = bstar
        inclination = inc * .pi / 180
        self.raan = raan * .pi / 180
        argPerigee = argp * .pi / 180
        meanAnomaly = mo * .pi / 180
        eccentricity = ecc
        meanMotion = n
    }

    // Alpha-5: a leading letter extends 5-digit catalog numbers past 99999 (I and O are skipped).
    private static func catalogNumber(_ s: String) -> Int? {
        if let v = Int(s) { return v }
        guard s.count == 5, let first = s.first, first.isLetter, let rest = Int(s.dropFirst()) else { return nil }
        let letters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
        guard let i = letters.firstIndex(of: Character(first.uppercased())) else { return nil }
        return (10 + i) * 10_000 + rest
    }
}

/// Geodetic position on WGS-84, degrees.
struct GeoPoint: Sendable, Hashable {
    var latitude: Double
    var longitude: Double
    var altitudeKm: Double = 0
}

/// Degrees; azimuth 0 = north, clockwise.
struct SkyPosition: Sendable, Hashable {
    var azimuth: Double
    var elevation: Double
    var rangeKm: Double
}

enum Orbit {
    /// Parses 3-line (name + 2 lines) TLE text; skips malformed entries.
    /// Bare 2-line entries are accepted too, named after the NORAD id.
    static func parse(_ text: String) -> [TLE] {
        var lines: [Substring] = []
        text.enumerateLines { line, _ in lines.append(Substring(line)) }
        var out: [TLE] = []
        out.reserveCapacity(lines.count / 3)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("1 "), i + 1 < lines.count, lines[i + 1].hasPrefix("2 ") {
                if let t = TLE(name: "", line1: String(line), line2: String(lines[i + 1])) {
                    var t = t
                    t.name = String(t.noradID)
                    out.append(t)
                }
                i += 2
            } else if i + 2 < lines.count, lines[i + 1].hasPrefix("1 "), lines[i + 2].hasPrefix("2 ") {
                var name = line
                if name.hasPrefix("0 ") { name = name.dropFirst(2) }
                if let t = TLE(name: String(name), line1: String(lines[i + 1]), line2: String(lines[i + 2])) {
                    out.append(t)
                }
                i += 3
            } else {
                i += 1
            }
        }
        return out
    }

    /// Where a TEME position (km) appears from a point on the ground.
    static func look(from observer: GeoPoint, teme: SIMD3<Double>, at date: Date) -> SkyPosition {
        let site = Site(observer)
        return site.look(ecef: ecef(teme: teme, gmst: gmst(date)))
    }

    // MARK: Time and frames

    static func julianDay(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86_400 + 2_440_587.5
    }

    static func date(julian jd: Double) -> Date {
        Date(timeIntervalSince1970: (jd - 2_440_587.5) * 86_400)
    }

    static func julianDay(year: Int, month: Int, day: Int) -> Double {
        let y = Double(year), m = Double(month)
        return 367 * y - floor(7 * (y + floor((m + 9) / 12)) * 0.25) + floor(275 * m / 9) + Double(day) + 1_721_013.5
    }

    /// IAU-82 GMST in radians. UTC stands in for UT1; the sub-second gap is invisible here.
    static func gmst(_ date: Date) -> Double {
        let t = (julianDay(date) - 2_451_545) / 36_525
        var s = -6.2e-6 * t * t * t + 0.093104 * t * t + (876_600 * 3600 + 8_640_184.812866) * t + 67_310.54841
        s = (s * .pi / 180 / 240).truncatingRemainder(dividingBy: 2 * .pi)
        return s < 0 ? s + 2 * .pi : s
    }

    /// TEME to earth-fixed, ignoring polar motion.
    static func ecef(teme r: SIMD3<Double>, gmst g: Double) -> SIMD3<Double> {
        let c = cos(g), s = sin(g)
        return SIMD3(c * r.x + s * r.y, -s * r.x + c * r.y, r.z)
    }

    /// Observer frame, computed once per call site so a whole catalog pass shares it.
    struct Site {
        let position: SIMD3<Double>
        let east: SIMD3<Double>
        let north: SIMD3<Double>
        let up: SIMD3<Double>

        init(_ p: GeoPoint) {
            let a = 6378.137, f = 1 / 298.257223563
            let e2 = f * (2 - f)
            let lat = p.latitude * .pi / 180, lon = p.longitude * .pi / 180
            let sl = sin(lat), cl = cos(lat), so = sin(lon), co = cos(lon)
            let n = a / (1 - e2 * sl * sl).squareRoot()
            position = SIMD3((n + p.altitudeKm) * cl * co, (n + p.altitudeKm) * cl * so, (n * (1 - e2) + p.altitudeKm) * sl)
            east = SIMD3(-so, co, 0)
            north = SIMD3(-sl * co, -sl * so, cl)
            up = SIMD3(cl * co, cl * so, sl)
        }

        func look(ecef: SIMD3<Double>) -> SkyPosition {
            let d = ecef - position
            let range = simd_length(d)
            let e = simd_dot(d, east), n = simd_dot(d, north), u = simd_dot(d, up)
            var az = atan2(e, n) * 180 / .pi
            if az < 0 { az += 360 }
            let el = asin(max(-1, min(1, u / range))) * 180 / .pi
            return SkyPosition(azimuth: az, elevation: el, rangeKm: range)
        }
    }
}

/// SGP4 state for one satellite, with the constants precomputed once.
struct Propagator: Sendable {
    let tle: TLE

    // WGS-72, which is what the TLE fits assume.
    private static let radiusKm = 6378.135
    private static let mu = 398_600.8
    private static let xke = 60 / (radiusKm * radiusKm * radiusKm / mu).squareRoot()
    private static let j2 = 0.001082616
    private static let j3 = -0.00000253881
    private static let j4 = -0.00000165597
    private static let j3oj2 = j3 / j2
    private static let twoPi = 2 * Double.pi

    private let isimp: Bool
    private let ecco, inclo, nodeo, argpo, mo, bstar: Double
    private let noUnkozai, ao: Double
    private let con41, x1mth2, x7thm1: Double
    private let cc1, cc4, cc5, d2, d3, d4: Double
    private let delmo, eta, sinmao: Double
    private let argpdot, mdot, nodedot, nodecf, omgcof, xmcof: Double
    private let t2cof, t3cof, t4cof, t5cof: Double
    private let xlcof, aycof: Double

    /// nil for deep-space (period >= 225 min) or invalid elements.
    init?(_ tle: TLE) {
        typealias P = Propagator
        self.tle = tle
        let x2o3 = 2.0 / 3.0
        let ecco = tle.eccentricity, inclo = tle.inclination, argpo = tle.argPerigee, mo = tle.meanAnomaly
        let noKozai = tle.meanMotion * P.twoPi / 1440
        guard ecco >= 0, ecco < 1, noKozai > 0 else { return nil }

        // initl: recover the Brouwer mean motion from the Kozai one.
        let eccsq = ecco * ecco
        let omeosq = 1 - eccsq
        let rteosq = omeosq.squareRoot()
        let cosio = cos(inclo), cosio2 = cosio * cosio
        let ak = pow(P.xke / noKozai, x2o3)
        let d1 = 0.75 * P.j2 * (3 * cosio2 - 1) / (rteosq * omeosq)
        var del = d1 / (ak * ak)
        let adel = ak * (1 - del * del - del * (1.0 / 3.0 + 134 * del * del / 81))
        del = d1 / (adel * adel)
        let noUnkozai = noKozai / (1 + del)
        let ao = pow(P.xke / noUnkozai, x2o3)
        let sinio = sin(inclo)
        let po = ao * omeosq
        let con42 = 1 - 5 * cosio2
        let con41 = -con42 - cosio2 - cosio2
        let posq = po * po
        let rp = ao * (1 - ecco)

        guard P.twoPi / noUnkozai < 225 else { return nil }

        // sgp4init
        let ss = 78 / P.radiusKm + 1
        let qzms2t = pow((120 - 78) / P.radiusKm, 4)
        // Low perigee drops the higher-order drag terms (Spacetrack's isimp).
        let isimp = rp < 220 / P.radiusKm + 1
        var sfour = ss, qzms24 = qzms2t
        let perige = (rp - 1) * P.radiusKm
        if perige < 156 {
            sfour = perige < 98 ? 20 : perige - 78
            qzms24 = pow((120 - sfour) / P.radiusKm, 4)
            sfour = sfour / P.radiusKm + 1
        }
        let pinvsq = 1 / posq
        let tsi = 1 / (ao - sfour)
        let eta = ao * ecco * tsi
        let etasq = eta * eta
        let eeta = ecco * eta
        let psisq = abs(1 - etasq)
        let coef = qzms24 * pow(tsi, 4)
        let coef1 = coef / pow(psisq, 3.5)
        let cc2 = coef1 * noUnkozai * (ao * (1 + 1.5 * etasq + eeta * (4 + etasq))
            + 0.375 * P.j2 * tsi / psisq * con41 * (8 + 3 * etasq * (8 + etasq)))
        let bstar = tle.bstar
        let cc1 = bstar * cc2
        let cc3 = ecco > 1e-4 ? -2 * coef * tsi * P.j3oj2 * noUnkozai * sinio / ecco : 0
        let x1mth2 = 1 - cosio2
        let cc4 = 2 * noUnkozai * coef1 * ao * omeosq * (eta * (2 + 0.5 * etasq) + ecco * (0.5 + 2 * etasq)
            - P.j2 * tsi / (ao * psisq) * (-3 * con41 * (1 - 2 * eeta + etasq * (1.5 - 0.5 * eeta))
                + 0.75 * x1mth2 * (2 * etasq - eeta * (1 + etasq)) * cos(2 * argpo)))
        let cc5 = 2 * coef1 * ao * omeosq * (1 + 2.75 * (etasq + eeta) + eeta * etasq)
        let cosio4 = cosio2 * cosio2
        let temp1 = 1.5 * P.j2 * pinvsq * noUnkozai
        let temp2 = 0.5 * temp1 * P.j2 * pinvsq
        let temp3 = -0.46875 * P.j4 * pinvsq * pinvsq * noUnkozai
        let mdot = noUnkozai + 0.5 * temp1 * rteosq * con41 + 0.0625 * temp2 * rteosq * (13 - 78 * cosio2 + 137 * cosio4)
        let argpdot = -0.5 * temp1 * con42 + 0.0625 * temp2 * (7 - 114 * cosio2 + 395 * cosio4)
            + temp3 * (3 - 36 * cosio2 + 49 * cosio4)
        let xhdot1 = -temp1 * cosio
        let nodedot = xhdot1 + (0.5 * temp2 * (4 - 19 * cosio2) + 2 * temp3 * (3 - 7 * cosio2)) * cosio
        let omgcof = bstar * cc3 * cos(argpo)
        let xmcof = ecco > 1e-4 ? -x2o3 * coef * bstar / eeta : 0
        let nodecf = 3.5 * omeosq * xhdot1 * cc1
        let t2cof = 1.5 * cc1
        // Guard the 1/(1+cos i) singularity at exactly retrograde equatorial orbits.
        let xlcofDen = abs(cosio + 1) > 1.5e-12 ? 1 + cosio : 1.5e-12
        let xlcof = -0.25 * P.j3oj2 * sinio * (3 + 5 * cosio) / xlcofDen
        let aycof = -0.5 * P.j3oj2 * sinio
        let delmotemp = 1 + eta * cos(mo)

        var d2 = 0.0, d3 = 0.0, d4 = 0.0, t3cof = 0.0, t4cof = 0.0, t5cof = 0.0
        if !isimp {
            let cc1sq = cc1 * cc1
            d2 = 4 * ao * tsi * cc1sq
            let temp = d2 * tsi * cc1 / 3
            d3 = (17 * ao + sfour) * temp
            d4 = 0.5 * temp * ao * tsi * (221 * ao + 31 * sfour) * cc1
            t3cof = d2 + 2 * cc1sq
            t4cof = 0.25 * (3 * d3 + cc1 * (12 * d2 + 10 * cc1sq))
            t5cof = 0.2 * (3 * d4 + 12 * cc1 * d3 + 6 * d2 * d2 + 15 * cc1sq * (2 * d2 + cc1sq))
        }

        self.isimp = isimp
        self.ecco = ecco; self.inclo = inclo; self.nodeo = tle.raan; self.argpo = argpo; self.mo = mo
        self.bstar = bstar
        self.noUnkozai = noUnkozai; self.ao = ao
        self.con41 = con41; self.x1mth2 = x1mth2; self.x7thm1 = 7 * cosio2 - 1
        self.cc1 = cc1; self.cc4 = cc4; self.cc5 = cc5
        self.d2 = d2; self.d3 = d3; self.d4 = d4
        self.delmo = delmotemp * delmotemp * delmotemp
        self.eta = eta; self.sinmao = sin(mo)
        self.argpdot = argpdot; self.mdot = mdot; self.nodedot = nodedot; self.nodecf = nodecf
        self.omgcof = omgcof; self.xmcof = xmcof
        self.t2cof = t2cof; self.t3cof = t3cof; self.t4cof = t4cof; self.t5cof = t5cof
        self.xlcof = xlcof; self.aycof = aycof

        // Same as sgp4init: elements that fail at epoch are unusable.
        guard position(minutesSinceEpoch: 0) != nil else { return nil }
    }

    /// TEME, km; nil if the satellite has decayed or the math fails.
    func position(at date: Date) -> SIMD3<Double>? {
        position(minutesSinceEpoch: date.timeIntervalSince(tle.epoch) / 60)
    }

    func position(minutesSinceEpoch t: Double) -> SIMD3<Double>? {
        typealias P = Propagator
        let twoPi = P.twoPi
        let xmdf = mo + mdot * t
        let argpdf = argpo + argpdot * t
        let nodedf = nodeo + nodedot * t
        var argpm = argpdf
        var mm = xmdf
        let t2 = t * t
        var nodem = nodedf + nodecf * t2
        var tempa = 1 - cc1 * t
        var tempe = bstar * cc4 * t
        var templ = t2cof * t2

        if !isimp {
            let delomg = omgcof * t
            let delmtemp = 1 + eta * cos(xmdf)
            let delm = xmcof * (delmtemp * delmtemp * delmtemp - delmo)
            let temp = delomg + delm
            mm = xmdf + temp
            argpm = argpdf - temp
            let t3 = t2 * t, t4 = t3 * t
            tempa = tempa - d2 * t2 - d3 * t3 - d4 * t4
            tempe = tempe + bstar * cc5 * (sin(mm) - sinmao)
            templ = templ + t3cof * t3 + t4 * (t4cof + t * t5cof)
        }

        let am = pow(P.xke / noUnkozai, 2.0 / 3.0) * tempa * tempa
        let nm = P.xke / pow(am, 1.5)
        var em = ecco - tempe
        guard am.isFinite, em < 1, em >= -0.001 else { return nil }
        if em < 1e-6 { em = 1e-6 }
        mm += noUnkozai * templ
        var xlm = mm + argpm + nodem
        nodem = nodem.truncatingRemainder(dividingBy: twoPi)
        argpm = argpm.truncatingRemainder(dividingBy: twoPi)
        xlm = xlm.truncatingRemainder(dividingBy: twoPi)
        mm = (xlm - argpm - nodem).truncatingRemainder(dividingBy: twoPi)

        let sinip = sin(inclo), cosip = cos(inclo)

        // Long-period periodics.
        let axnl = em * cos(argpm)
        var temp = 1 / (am * (1 - em * em))
        let aynl = em * sin(argpm) + temp * aycof
        let xl = mm + argpm + nodem + temp * xlcof * axnl

        // Kepler's equation, with the step clamp from the reference code.
        let u = (xl - nodem).truncatingRemainder(dividingBy: twoPi)
        var eo1 = u, tem5 = 9999.9, ktr = 1
        var sineo1 = 0.0, coseo1 = 0.0
        while abs(tem5) >= 1e-12 && ktr <= 10 {
            sineo1 = sin(eo1); coseo1 = cos(eo1)
            tem5 = 1 - coseo1 * axnl - sineo1 * aynl
            tem5 = (u - aynl * coseo1 + axnl * sineo1 - eo1) / tem5
            if abs(tem5) >= 0.95 { tem5 = tem5 > 0 ? 0.95 : -0.95 }
            eo1 += tem5
            ktr += 1
        }

        // Short-period periodics.
        let ecose = axnl * coseo1 + aynl * sineo1
        let esine = axnl * sineo1 - aynl * coseo1
        let el2 = axnl * axnl + aynl * aynl
        let pl = am * (1 - el2)
        guard pl >= 0 else { return nil }
        let rl = am * (1 - ecose)
        let betal = (1 - el2).squareRoot()
        temp = esine / (1 + betal)
        let sinu = am / rl * (sineo1 - aynl - axnl * temp)
        let cosu = am / rl * (coseo1 - axnl + aynl * temp)
        var su = atan2(sinu, cosu)
        let sin2u = (cosu + cosu) * sinu
        let cos2u = 1 - 2 * sinu * sinu
        temp = 1 / pl
        let temp1 = 0.5 * P.j2 * temp
        let temp2 = temp1 * temp

        let mrt = rl * (1 - 1.5 * temp2 * betal * con41) + 0.5 * temp1 * x1mth2 * cos2u
        // Below one earth radius means it has re-entered.
        guard mrt >= 1, nm > 0 else { return nil }
        su -= 0.25 * temp2 * x7thm1 * sin2u
        let xnode = nodem + 1.5 * temp2 * cosip * sin2u
        let xinc = inclo + 1.5 * temp2 * cosip * sinip * cos2u

        let sinsu = sin(su), cossu = cos(su)
        let snod = sin(xnode), cnod = cos(xnode)
        let sini = sin(xinc), cosi = cos(xinc)
        let xmx = -snod * cosi, xmy = cnod * cosi
        let ux = xmx * sinsu + cnod * cossu
        let uy = xmy * sinsu + snod * cossu
        let uz = sini * sinsu
        let r = SIMD3(ux, uy, uz) * (mrt * P.radiusKm)
        return r.x.isFinite && r.y.isFinite && r.z.isFinite ? r : nil
    }
}

struct VisibleSatellite: Identifiable, Sendable, Hashable {
    var id: Int            // NORAD id
    var name: String
    var azimuth: Double
    var elevation: Double
    var rangeKm: Double
}

/// Downloads, caches and propagates the Starlink constellation.
actor SatelliteCatalog {
    static let shared = SatelliteCatalog()

    private static let source = URL(string: "https://celestrak.org/NORAD/elements/gp.php?GROUP=starlink&FORMAT=tle")!
    private static let maxAge: TimeInterval = 12 * 3600
    // CelesTrak blocks clients that poll harder than this, failures included.
    private static let minRetry: TimeInterval = 2 * 3600

    private(set) var count = 0
    private(set) var fetchedAt: Date?
    private(set) var lastError: String?

    private var propagators: [Propagator] = []
    private var loadedCache = false
    private var refreshing = false

    private let directory: URL
    private var cacheFile: URL { directory.appendingPathComponent("starlink.tle") }
    // Its modification date records the last download attempt, so the
    // retry limit survives relaunches.
    private var attemptFile: URL { directory.appendingPathComponent("starlink.attempt") }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StarDash", isDirectory: true)
    }

    /// Loads the cached file, refreshing from CelesTrak when it is missing or older than 12 hours. Safe to call often.
    func refreshIfNeeded() async {
        if !loadedCache {
            loadedCache = true
            loadCache()
        }
        guard !refreshing else { return }
        let now = Date()
        if let fetchedAt, now.timeIntervalSince(fetchedAt) < Self.maxAge, !propagators.isEmpty { return }
        if let last = modificationDate(attemptFile), now.timeIntervalSince(last) < Self.minRetry, last <= now { return }

        refreshing = true
        defer { refreshing = false }
        markAttempt(now)

        do {
            var request = URLRequest(url: Self.source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue("StarDash", forHTTPHeaderField: "User-Agent")
            request.httpShouldHandleCookies = false
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw CatalogError("CelesTrak returned HTTP \(http.statusCode)")
            }
            guard let text = String(data: data, encoding: .utf8) else { throw CatalogError("CelesTrak sent unreadable data") }
            let tles = Orbit.parse(text)
            // CelesTrak answers rate-limited or broken requests with a short
            // plain-text message, which must not replace a good cache.
            guard tles.count >= 100 else {
                let hint = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)
                throw CatalogError(hint.isEmpty ? "CelesTrak returned no satellites" : "CelesTrak: \(hint)")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: cacheFile, options: .atomic)
            install(tles)
            fetchedAt = modificationDate(cacheFile) ?? Date()
            lastError = nil
        } catch {
            lastError = (error as? CatalogError)?.message ?? error.localizedDescription
        }
    }

    /// Satellites above `minElevation` degrees for the observer at `date`, highest first.
    func visible(from observer: GeoPoint, at date: Date, minElevation: Double) -> [VisibleSatellite] {
        let site = Orbit.Site(observer)
        let g = Orbit.gmst(date)
        let c = cos(g), s = sin(g)
        // Unit "up" in TEME at this instant; lets most satellites be rejected
        // with one dot product before the full look computation.
        let upTeme = SIMD3(c * site.up.x - s * site.up.y, s * site.up.x + c * site.up.y, site.up.z)
        let siteTeme = SIMD3(c * site.position.x - s * site.position.y, s * site.position.x + c * site.position.y, site.position.z)
        let sinMin = sin(max(-90, min(90, minElevation)) * .pi / 180)

        var out: [VisibleSatellite] = []
        for p in propagators {
            guard let r = p.position(at: date) else { continue }
            let d = r - siteTeme
            let h = simd_dot(d, upTeme)
            // sin(el) = h / |d|; compare squared to skip the square root.
            if sinMin >= 0 {
                if h <= 0 || h * h < sinMin * sinMin * simd_length_squared(d) { continue }
            } else if h < 0, h * h > sinMin * sinMin * simd_length_squared(d) {
                continue
            }
            let look = site.look(ecef: Orbit.ecef(teme: r, gmst: g))
            guard look.elevation >= minElevation else { continue }
            out.append(VisibleSatellite(id: p.tle.noradID, name: p.tle.name,
                                        azimuth: look.azimuth, elevation: look.elevation, rangeKm: look.rangeKm))
        }
        out.sort { $0.elevation > $1.elevation }
        return out
    }

    /// Where every satellite is over the Earth right now, as Earth-fixed vectors in Earth radii
    /// (1 is the surface). For drawing the whole constellation around a globe.
    func shell(at date: Date) -> [SIMD3<Float>] {
        let g = Orbit.gmst(date)
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(propagators.count)
        for p in propagators {
            guard let r = p.position(at: date) else { continue }
            let e = Orbit.ecef(teme: r, gmst: g) / 6371.0
            out.append(SIMD3(Float(e.x), Float(e.y), Float(e.z)))
        }
        return out
    }

    // MARK: Private

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheFile), let text = String(data: data, encoding: .utf8) else { return }
        let tles = Orbit.parse(text)
        guard !tles.isEmpty else { return }
        install(tles)
        fetchedAt = modificationDate(cacheFile)
    }

    private func install(_ tles: [TLE]) {
        // CelesTrak occasionally lists a satellite twice; keep the newest epoch.
        var newest: [Int: TLE] = [:]
        for t in tles where (newest[t.noradID]?.epoch ?? .distantPast) < t.epoch { newest[t.noradID] = t }
        propagators = newest.values.sorted { $0.noradID < $1.noradID }.compactMap(Propagator.init)
        count = propagators.count
    }

    private func markAttempt(_ date: Date) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: attemptFile.path) { fm.createFile(atPath: attemptFile.path, contents: Data()) }
        try? fm.setAttributes([.modificationDate: date], ofItemAtPath: attemptFile.path)
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private struct CatalogError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
