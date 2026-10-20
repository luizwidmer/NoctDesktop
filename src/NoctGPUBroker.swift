import Foundation
import CoreFoundation
import Darwin

/// Length-prefixed JSON over one workspace-local Unix socket, carried to the
/// guest by virtio-serial. This process has no network listener or file API.
@main struct NoctGPUBroker {
    static let maxRequest = 1024 * 1024
    static func error(_ s: String) -> Error { NoctMetalError.unavailable(s) }
    static func read(_ fd: Int32, _ count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { p in
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd,p.baseAddress!.advanced(by: offset),count-offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw error("GPU channel closed.") }
                offset += n
            }
        }
        return data
    }
    static func write(_ fd: Int32, _ bytes: Data) throws {
        try bytes.withUnsafeBytes { p in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd,p.baseAddress!.advanced(by: offset),bytes.count-offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw error("GPU channel closed.") }
                offset += n
            }
        }
    }
    static func number(_ value: Any, _ range: ClosedRange<Double>) throws -> Double {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, range.contains(n.doubleValue) else { throw error("Invalid GPU numeric field.") }
        return n.doubleValue
    }
    static func size(_ value: Any?) throws -> Int {
        guard let value else { throw error("Missing GPU surface size.") }
        let n = try number(value,16...512)
        guard n.rounded() == n else { throw error("GPU surface size must be an integer.") }; return Int(n)
    }
    static func respond(_ data: Data, renderer: NoctMetal) throws -> [String:Any] {
        guard let q = try JSONSerialization.jsonObject(with: data) as? [String:Any],
              let v = q["version"], try number(v,1...1) == 1,
              let op = q["op"] as? String else { throw error("Unsupported Noct GPU request version.") }
        if op == "info" {
            return ["ok":true,"version":1,"device":renderer.device.name,"max_dimension":512,"max_vertices":12288,"api":"noct.triangles@1"]
        }
        guard op == "render", let rows = q["vertices"] as? [[Any]], rows.count <= 12288, rows.count % 3 == 0,
              let values = q["clear"] as? [Any], values.count == 4 else { throw error("Invalid GPU render request.") }
        let width = try size(q["width"]), height = try size(q["height"])
        let clear = try values.map { try number($0,0...1) }
        let vertices: [NoctMetal.Vertex] = try rows.map { r in
            guard r.count == 6 else { throw error("A GPU vertex needs x, y, r, g, b, a.") }
            return NoctMetal.Vertex(position: SIMD2(Float(try number(r[0],-1...1)),Float(try number(r[1],-1...1))),
                                    color: SIMD4(Float(try number(r[2],0...1)),Float(try number(r[3],0...1)),Float(try number(r[4],0...1)),Float(try number(r[5],0...1))))
        }
        let result = try renderer.render(width:width,height:height,vertices:vertices,clear:clear)
        return ["ok":true,"version":1,"device":renderer.device.name,"width":width,"height":height,"format":"rgba8",
                "gpu_ms":result.gpuMilliseconds,"sha256":result.sha256,"rgba_base64":result.pixels.base64EncodedString()]
    }
    static func selfTest(_ renderer: NoctMetal) throws {
        let triangle = [[-0.8,-0.8,1.0,0,0,1], [0.8,-0.8,1.0,0,0,1], [0,0.8,1.0,0,0,1]]
        let q: [String:Any] = ["version":1,"op":"render","width":64,"height":64,"vertices":triangle,"clear":[0,0,0,1]]
        let a = try respond(JSONSerialization.data(withJSONObject:q),renderer:renderer)
        guard let base = a["rgba_base64"] as? String, let pixels = Data(base64Encoded:base),
              Array(pixels[(32*64+32)*4..<(32*64+32)*4+4]) == [255,0,0,255],
              Array(pixels[0..<4]) == [0,0,0,255] else { throw error("GPU pixel verification failed.") }
        var green = q
        green["vertices"] = triangle.map { [$0[0],$0[1],0.0,1.0,0,1] }
        let b = try respond(JSONSerialization.data(withJSONObject:green),renderer:renderer)
        guard a["sha256"] as? String != b["sha256"] as? String else { throw error("GPU ignored changed geometry data.") }
        var rejected = 0
        for bad in [["width":15], ["width":513], ["width":64.5], ["version":2], ["op":"shader"], ["vertices":[[2,0,1,0,0,1],[0,0,1,0,0,1],[0,1,1,0,0,1]]]] as [[String:Any]] {
            var item = q; item.merge(bad) { _,new in new }
            do { _ = try respond(JSONSerialization.data(withJSONObject:item),renderer:renderer) }
            catch { rejected += 1 }
        }
        guard rejected == 6 else { throw error("GPU request validation failed.") }
        let report: [String:Any] = ["device":renderer.device.name,"registry_id":renderer.device.registryID,
            "red_center_rgba":[255,0,0,255],"black_corner_rgba":[0,0,0,255],"different_inputs_different_pixels":true,
            "invalid_requests_rejected":rejected,"gpu_ms":a["gpu_ms"]!,"sha256":a["sha256"]!,"passed":true]
        print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
    }
    static func serve(_ path: String, renderer: NoctMetal) throws {
        guard path.hasPrefix("/"), path.utf8.count < 104, !FileManager.default.fileExists(atPath:path) else { throw error("Invalid or occupied GPU socket path.") }
        let fd = socket(AF_UNIX,SOCK_STREAM,0)
        guard fd >= 0 else { throw error("Could not create GPU socket.") }
        defer { Darwin.close(fd); unlink(path) }
        var a = sockaddr_un(); a.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of:&a.sun_path) { $0.copyBytes(from:Array(path.utf8)+[0]) }
        let bound = withUnsafePointer(to:&a) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, chmod(path,0o600) == 0, listen(fd,1) == 0 else { throw error("Could not bind GPU socket.") }
        // One sequential channel bounds concurrent resources and GPU work. The
        // guest client additionally serializes cooperating application requests.
        while true {
            let peer = accept(fd,nil,nil)
            guard peer >= 0 else { if errno == EINTR { continue }; throw error("GPU channel accept failed.") }
            var noSignal: Int32 = 1
            setsockopt(peer,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,socklen_t(MemoryLayout<Int32>.size))
            do {
                while true {
                    let header = try read(peer,4)
                    var timeout = timeval(tv_sec: 10, tv_usec: 0)
                    setsockopt(peer,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
                    setsockopt(peer,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
                    let count = header.reduce(0) { $0 << 8 | Int($1) }
                    guard count > 0, count <= maxRequest else { throw error("Oversized GPU request.") }
                    let request = try read(peer,count)
                    let reply: [String:Any]
                    do { reply = try respond(request,renderer:renderer) }
                    catch { reply = ["ok":false,"version":1,"error":error.localizedDescription] }
                    let response = try JSONSerialization.data(withJSONObject:reply,options:.sortedKeys)
                    let n = response.count
                    try write(peer,Data([UInt8((n>>24)&255),UInt8((n>>16)&255),UInt8((n>>8)&255),UInt8(n&255)]))
                    guard try read(peer,1) == Data([6]) else { throw error("GPU response acknowledgement failed.") }
                    // A FreeBSD tty has a small input queue. Acknowledge each
                    // bounded chunk rather than overflowing it with pixel data.
                    for offset in stride(from:0,to:n,by:1024) {
                        try write(peer,response.subdata(in:offset..<min(offset+1024,n)))
                        guard try read(peer,1) == Data([6]) else { throw error("GPU response acknowledgement failed.") }
                    }
                    // v1 is an offscreen proof, capped at 30 requests/sec. It
                    // avoids an unbounded host command queue from a busy guest.
                    usleep(33_334)
                    timeout = timeval(tv_sec: 0, tv_usec: 0)
                    setsockopt(peer,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
                }
            } catch { /* Disconnect or bad framing. Never log guest payloads. */ }
            Darwin.close(peer)
        }
    }
    static func main() {
        umask(0o077)
        do {
            let renderer = try NoctMetal()
            if CommandLine.arguments == [CommandLine.arguments[0],"--self-test"] { try selfTest(renderer) }
            else if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--socket" { try serve(CommandLine.arguments[2],renderer:renderer) }
            else { throw error("Usage: NoctGPUBroker --socket PATH | --self-test") }
        } catch { fputs("Noct GPU: \(error.localizedDescription)\n",stderr); exit(1) }
    }
}
