import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Stock: Decodable {
    let id: String
    let targetPrint: String
    let category: String
    let positive: Bool
    let calibratedPapers: [String]
}
struct Catalog: Decodable {
    let films: [Stock]
    let papers: [Stock]
}

guard CommandLine.arguments.count == 4 else {
    fatalError("Usage: render-stock-previews <app resources> <reference images> <output>")
}
let app = URL(fileURLWithPath: CommandLine.arguments[1])
let references = URL(fileURLWithPath: CommandLine.arguments[2])
let output = URL(fileURLWithPath: CommandLine.arguments[3])
let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: app.appendingPathComponent("stock-catalog.json")))
guard let engine = spk_engine_create(app.appendingPathComponent("engine").path, nil) else {
    fatalError("Engine: \(String(cString: spk_last_error(nil)))")
}
defer { spk_engine_destroy(engine) }
let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
let ciContext = CIContext(options: [.workingColorSpace: linear, .outputColorSpace: linear])
var decoded: [String: (pixels: [Float], width: Int, height: Int)] = [:]

func source(_ name: String) throws -> (pixels: [Float], width: Int, height: Int) {
    if let existing = decoded[name] { return existing }
    let url = references.appendingPathComponent("\(name).jpg")
    guard var image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
        fatalError("Cannot decode \(url.path)")
    }
    let scale = min(1, 800 / max(image.extent.width, image.extent.height))
    image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let bounds = image.extent.integral
    let width = Int(bounds.width), height = Int(bounds.height)
    var pixels = [Float](repeating: 0, count: width * height * 4)
    ciContext.render(image, toBitmap: &pixels, rowBytes: width * 16,
                     bounds: bounds, format: .RGBAf, colorSpace: linear)
    decoded[name] = (pixels, width, height)
    return (pixels, width, height)
}

func render(_ stock: Stock, film: Stock, paper: Stock?, photo: String, folder: String) throws {
    let input = try source(photo)
    var settings: [String: Any] = [
        "film_stock": film.id,
        "print_stock": paper?.id ?? (film.targetPrint.isEmpty ? "kodak_portra_endura" : film.targetPrint),
        "scan_film": film.positive,
        "input_color_space": "sRGB",
        "input_cctf_decoding": false,
        "output_color_space": "Display P3",
        "preview_long_edge": 800,
        "auto_exposure": true,
    ]
    if paper?.id == "ilford_multigrade_iv_rc" {
        // Match the app's default grade 2.
        struct Grades: Decodable {
            struct Grade: Decodable {
                let m_filter_neutral: Double
                let y_filter_neutral: Double
                let print_exposure: Double
            }
            let grades: [String: Grade]
        }
        let grades = try JSONDecoder().decode(Grades.self, from: Data(contentsOf: app.appendingPathComponent("paper_grades.json")))
        let grade = grades.grades["2"]!
        settings["c_filter_neutral"] = 0
        settings["m_filter_neutral"] = grade.m_filter_neutral
        settings["y_filter_neutral"] = grade.y_filter_neutral
        settings["print_exposure"] = grade.print_exposure
        settings["grain_sublayers_active"] = false
    }
    let json = String(data: try JSONSerialization.data(withJSONObject: settings), encoding: .utf8)!
    let session = input.pixels.withUnsafeBufferPointer { buffer -> OpaquePointer? in
        var image = spk_image(data: buffer.baseAddress, width: UInt32(input.width),
                              height: UInt32(input.height), channels: 4)
        return spk_open(engine, &image, json, nil)
    }
    guard let session else { throw NSError(domain: "Preview", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(stock.id): \(String(cString: spk_last_error(engine)))"]) }
    defer { spk_session_release(session) }
    var result = spk_result()
    guard spk_reprint(session, "live", &result) == SPK_OK else {
        throw NSError(domain: "Preview", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(stock.id): \(String(cString: spk_last_error(engine)))"])
    }
    defer { spk_result_free(&result) }
    let width = Int(result.width), height = Int(result.height), stride = Int(result.row_stride_px)
    var bytes = Data(count: width * height * 4)
    bytes.withUnsafeMutableBytes { raw in
        let destination = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let pixels = result.rgba16!
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * stride + x) * 4, o = (y * width + x) * 4
                destination[o] = UInt8(truncatingIfNeeded: pixels[i] >> 8)
                destination[o + 1] = UInt8(truncatingIfNeeded: pixels[i + 1] >> 8)
                destination[o + 2] = UInt8(truncatingIfNeeded: pixels[i + 2] >> 8)
                destination[o + 3] = 255
            }
        }
    }
    let provider = CGDataProvider(data: bytes as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: width * 4, space: p3,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: true,
                        intent: .defaultIntent)!
    let directory = output.appendingPathComponent(folder)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent("\(stock.id).jpg")
    guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        fatalError("Cannot create \(destination.path)")
    }
    let thumbnailScale = min(1, 320 / CGFloat(max(width, height)))
    let thumbnail = ciContext.createCGImage(
        CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: thumbnailScale, y: thumbnailScale)),
        from: CGRect(x: 0, y: 0, width: CGFloat(width) * thumbnailScale,
                     height: CGFloat(height) * thumbnailScale),
        format: .RGBA8, colorSpace: p3
    )!
    CGImageDestinationAddImage(writer, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.77] as CFDictionary)
    guard CGImageDestinationFinalize(writer) else { fatalError("Cannot write \(destination.path)") }
    print("\(folder)/\(stock.id).jpg ← \(photo), \(film.id), \(paper?.id ?? "direct scan")")
}

let filmByID = Dictionary(uniqueKeysWithValues: catalog.films.map { ($0.id, $0) })
for film in catalog.films {
    let paper = catalog.papers.first { $0.id == film.targetPrint && film.calibratedPapers.contains($0.id) }
    let photo: String
    if film.category == "黑白胶片" || film.id.contains("portra") || film.id == "fujifilm_pro_400h" {
        photo = "portrait"
    } else if film.category == "电影负片" || film.id == "cinestill_800t" { photo = "night" }
    else { photo = "landscape" }
    try render(film, film: film, paper: paper, photo: photo, folder: "films")
}
for paper in catalog.papers {
    let filmID = paper.category == "黑白相纸" ? "kodak_tri_x_400"
        : paper.category == "电影拷贝" ? "kodak_vision3_250d" : "kodak_portra_400"
    guard let film = filmByID[filmID], film.calibratedPapers.contains(paper.id) else {
        fatalError("No calibrated reference film for \(paper.id)")
    }
    let photo = paper.category == "黑白相纸" ? "portrait"
        : paper.category == "电影拷贝" ? "night" : "portrait"
    try render(paper, film: film, paper: paper, photo: photo, folder: "papers")
}
