import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct SpectralDarkroomApp: App {
    var body: some Scene {
        WindowGroup {
            EditorView()
        }
    }
}

private struct RenderedFrame: Sendable {
    let pixels: Data
    let width: Int
    let height: Int

    func image() throws -> CGImage {
        guard let provider = CGDataProvider(data: pixels as CFData),
              let p3 = CGColorSpace(name: CGColorSpace.displayP3),
              let image = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: p3,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true,
                intent: .defaultIntent
              )
        else { throw RenderError.message("无法显示渲染结果") }
        return image
    }
}

private enum RenderError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(text) = self { return text }
        return nil
    }
}

private struct RenderSettings: Sendable, Hashable {
    var exposure = 0.0
    var autoExposure = true
    var filmFormat = 35.0
    var lensBlur = 0.0
    var scannerBlur = 0.0
    var printExposure = 1.0
    var magenta = 0.0
    var yellow = 0.0
    var filterScale = 20.0
    var preflash = 0.0
    var grain = 1.0
    var grainActive = true
    var halation = 1.0
    var halationBoost = 0.0
    var scatter = 1.0
    var halationActive = true
    var dirCouplers = 1.0
    var dirActive = true
    var densityGamma = 1.0
    var glare = 1.0
    var glareActive = true
    var contrastMaskActive = false
    var contrastHighlights = 0.0
    var contrastShadows = 0.0
    var contrastCore = 1.0
    var contrastScale = 0.03
    var paperGrade = "2"
    var latitudeActive = false
    var highlightKnee = 2.0
    var highlightRoom = 0.0
    var shadowKnee = -2.0
    var shadowRoom = 0.0
    var latitudeRolloff = 2.0
    var antiHalationRemoved = false
    var scannerWhite = false
    var scannerBlack = false

    var wire: [String: Any] {
        [
            "exposure_compensation_ev": exposure,
            "auto_exposure": autoExposure,
            "film_format_mm": filmFormat,
            "lens_blur_um": lensBlur,
            "scanner_lens_blur": scannerBlur,
            "print_exposure": printExposure,
            "m_filter_shift": magenta,
            "y_filter_shift": yellow,
            "filter_shift_scale": filterScale,
            "preflash_exposure": preflash,
            "grain_active": grainActive,
            "grain_amount": grain,
            "halation_active": halationActive,
            "halation_amount": halation,
            "halation_boost_ev": halationBoost,
            "halation_scatter_amount": scatter,
            "dir_couplers_active": dirActive,
            "dir_couplers_amount": dirCouplers,
            "density_curve_gamma": densityGamma,
            "glare_active": glareActive,
            "glare_amount": glare,
            "contrast_mask_active": contrastMaskActive,
            "contrast_mask_highlights": contrastHighlights,
            "contrast_mask_shadows": contrastShadows,
            "contrast_mask_core": contrastCore,
            "contrast_mask_scale": contrastScale,
            "scene_latitude_active": latitudeActive,
            "scene_latitude_highlight_knee": highlightKnee,
            "scene_latitude_highlight_room": highlightRoom,
            "scene_latitude_shadow_knee": shadowKnee,
            "scene_latitude_shadow_room": shadowRoom,
            "scene_latitude_rolloff": latitudeRolloff,
            "antihalation_removed": antiHalationRemoved,
            "scanner_white_correction": scannerWhite,
            "scanner_black_correction": scannerBlack,
        ]
    }
}

private struct PaperGrades: Decodable {
    struct Grade: Decodable {
        let m_filter_neutral: Double
        let y_filter_neutral: Double
        let print_exposure: Double
    }
    let grades: [String: Grade]

    static let bundled: PaperGrades? = {
        guard let url = Bundle.main.url(forResource: "paper_grades", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PaperGrades.self, from: data)
    }()
}

// All engine calls stay on this actor. C's thread-local error string must be
// copied before another operation; the rgba16 result is copied before release.
private actor FilmEngine {
    private var engine: OpaquePointer?
    private var session: OpaquePointer?
    private var frameURL: URL?
    private var pixels: [Float] = []
    private var width = 0
    private var height = 0
    private let maxEdge: CGFloat
    private let previewLongEdge: Int

    init(maxEdge: CGFloat = 4096, previewLongEdge: Int = 1600) {
        self.maxEdge = maxEdge
        self.previewLongEdge = previewLongEdge
    }

    func render(url: URL, film: String, paper: String, scanFilm: Bool,
                settings: RenderSettings, tier: String) throws -> RenderedFrame {
        if engine == nil {
            guard let resources = Bundle.main.resourceURL?.appendingPathComponent("engine"),
                  let created = spk_engine_create(resources.path, nil) else {
                throw RenderError.message("胶片引擎启动失败：\(String(cString: spk_last_error(nil)))")
            }
            engine = created
        }
        if frameURL != url {
            try decode(url)
            frameURL = url
        }
        if let session { spk_session_release(session) }
        session = nil

        var wire: [String: Any] = [
            "film_stock": film,
            "print_stock": paper,
            "scan_film": scanFilm,
            "input_color_space": "sRGB",
            "input_cctf_decoding": false,
            "output_color_space": "Display P3",
            "preview_long_edge": previewLongEdge,
        ]
        wire.merge(settings.wire) { _, new in new }
        if !scanFilm, paper == "ilford_multigrade_iv_rc",
           let grade = PaperGrades.bundled?.grades[settings.paperGrade] {
            wire["c_filter_neutral"] = 0
            wire["m_filter_neutral"] = grade.m_filter_neutral
            wire["y_filter_neutral"] = grade.y_filter_neutral
            wire["print_exposure"] = settings.printExposure * grade.print_exposure
            wire["grain_sublayers_active"] = false
        }
        let json = try JSONSerialization.data(withJSONObject: wire)
        guard let delta = String(data: json, encoding: .utf8) else {
            throw RenderError.message("无法编码胶片设置")
        }
        var reply: UnsafeMutablePointer<CChar>?
        let opened = pixels.withUnsafeBufferPointer { buffer -> OpaquePointer? in
            var input = spk_image(data: buffer.baseAddress,
                                  width: UInt32(width), height: UInt32(height),
                                  channels: 4)
            return spk_open(engine, &input, delta, &reply)
        }
        if let reply { spk_string_free(reply) }
        guard let opened else { throw failure("无法打开照片") }
        session = opened
        var result = spk_result()
        guard spk_reprint(opened, tier, &result) == SPK_OK else {
            throw failure("冲印失败")
        }
        defer { spk_result_free(&result) }
        guard let source = result.rgba16, result.width > 0, result.height > 0 else {
            throw RenderError.message("引擎没有返回像素")
        }
        let w = Int(result.width)
        let h = Int(result.height)
        let stride = Int(result.row_stride_px)
        var bytes = Data(count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let destination = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<h {
                for x in 0..<w {
                    let input = (y * stride + x) * 4
                    let output = (y * w + x) * 4
                    destination[output] = UInt8(truncatingIfNeeded: source[input] >> 8)
                    destination[output + 1] = UInt8(truncatingIfNeeded: source[input + 1] >> 8)
                    destination[output + 2] = UInt8(truncatingIfNeeded: source[input + 2] >> 8)
                    destination[output + 3] = 255
                }
            }
        }
        return RenderedFrame(pixels: bytes, width: w, height: h)
    }

    private func failure(_ prefix: String) -> RenderError {
        .message("\(prefix)：\(String(cString: spk_last_error(engine)))")
    }

    private func decode(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard var image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw RenderError.message("无法解码照片；请尝试 JPEG、HEIC 或受系统支持的 RAW")
        }
        let longEdge = max(image.extent.width, image.extent.height)
        if longEdge > maxEdge {
            image = image.transformed(by: CGAffineTransform(scaleX: maxEdge / longEdge,
                                                             y: maxEdge / longEdge))
        }
        let bounds = image.extent.integral
        let w = Int(bounds.width)
        let h = Int(bounds.height)
        guard w > 0, h > 0, let linear = CGColorSpace(name: CGColorSpace.linearSRGB) else {
            throw RenderError.message("照片尺寸或色彩空间无效")
        }
        var decoded = [Float](repeating: 0, count: w * h * 4)
        let context = CIContext(options: [.workingColorSpace: linear, .outputColorSpace: linear])
        context.render(image, toBitmap: &decoded, rowBytes: w * 4 * MemoryLayout<Float>.size,
                       bounds: bounds, format: .RGBAf, colorSpace: linear)
        pixels = decoded
        width = w
        height = h
    }
}

private struct Stock: Identifiable, Decodable {
    let id: String
    let label: String
    let originalName: String
    let targetPrint: String
    let category: String
    let positive: Bool
    let strongHalation: Bool
    let calibratedPapers: [String]

    var iso: Int {
        originalName.split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
            .first(where: { $0 >= 25 }) ?? Int.max
    }
}

private enum StockSort: String {
    case defaultOrder = "default"
    case name = "name"
    case iso = "iso"
    case recent = "recent"
    case custom = "custom"

    var title: String {
        switch self {
        case .defaultOrder: "默认"
        case .name: "名称"
        case .iso: "感光度"
        case .recent: "最近使用"
        case .custom: "自定义"
        }
    }
}

private struct StockPreviewCard: View {
    let stock: Stock
    let chosen: Bool
    let available: Bool
    let isFilm: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 15)
                    .fill(
                        LinearGradient(
                            colors: chosen
                                ? [Color(red: 0.31, green: 0.26, blue: 0.20),
                                   Color(red: 0.18, green: 0.18, blue: 0.17)]
                                : [Color.white.opacity(0.09), Color.white.opacity(0.045)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                if let url = Bundle.main.url(forResource: stock.id, withExtension: "jpg",
                                              subdirectory: isFilm ? "StockPreviews/films" : "StockPreviews/papers"),
                   let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 160, height: 114)
                        .clipped()
                }
                LinearGradient(
                    colors: [.clear, .black.opacity(0.86)],
                    startPoint: .top, endPoint: .bottom
                )
                VStack(alignment: .leading, spacing: 3) {
                    Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(chosen ? DarkroomStyle.accent : .white.opacity(0.75))
                    Spacer(minLength: 0)
                    Text(stock.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(stock.strongHalation ? "强光晕 · \(stock.originalName)" : stock.originalName)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
                .padding(12)
            }
            .frame(width: 160, height: 114)
            .clipShape(RoundedRectangle(cornerRadius: 15))
            .overlay {
                RoundedRectangle(cornerRadius: 15)
                    .strokeBorder(chosen ? DarkroomStyle.accent.opacity(0.8)
                                         : .white.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.36)
        .accessibilityLabel(available ? stock.label : "\(stock.label)，当前胶片不可搭配")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

private struct StockCatalog: Decodable {
    let films: [Stock]
    let papers: [Stock]

    static func load() -> StockCatalog {
        guard let url = Bundle.main.url(forResource: "stock-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(StockCatalog.self, from: data) else {
            return StockCatalog(films: [], papers: [])
        }
        return catalog
    }
}

private enum DarkroomStyle {
    static let background = Color(red: 0.055, green: 0.060, blue: 0.064)
    static let panel = Color(red: 0.105, green: 0.110, blue: 0.114)
    static let accent = Color(red: 0.91, green: 0.72, blue: 0.47)
    static let muted = Color(red: 0.62, green: 0.63, blue: 0.62)
}

private struct GlassActionStyle: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

private struct NavigationGlass: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

private struct ExportRecord: Identifiable {
    let url: URL
    let date: Date
    var id: URL { url }

    var thumbnail: UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 480,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

private enum EditPanel: String, CaseIterable {
    case film = "胶片"
    case paper = "相纸"
    case adjust = "微调"

    var symbol: String {
        switch self {
        case .film: "camera.aperture"
        case .paper: "square.stack.3d.up"
        case .adjust: "slider.horizontal.3"
        }
    }
}

private struct EditorView: View {
    @State private var selectedURL: URL?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var preview: CGImage?
    @State private var showingHistory = false
    @State private var records: [ExportRecord] = []
    @State private var selectedRecord: ExportRecord?
    @State private var isWorking = false
    @State private var error: String?
    @State private var activePanel: EditPanel = .film
    @State private var showingAdjustments = false
    @State private var showingStockOrder = false
    @State private var showingStockBrowser = false
    @State private var browsingFilm = true
    @State private var stockQuery = ""
    @State private var browserCategory = "全部"
    @State private var editingFilmOrder = true
    @State private var draftOrder: [String] = []
    @AppStorage("filmStockSort") private var filmSort = StockSort.defaultOrder.rawValue
    @AppStorage("paperStockSort") private var paperSort = StockSort.defaultOrder.rawValue
    @AppStorage("filmCustomOrder") private var filmOrder = ""
    @AppStorage("paperCustomOrder") private var paperOrder = ""
    @AppStorage("filmRecentUse") private var filmRecentUse = ""
    @AppStorage("paperRecentUse") private var paperRecentUse = ""
    @State private var film = "kodak_portra_400"
    @State private var paper = "kodak_portra_endura"
    @State private var scanFilm = false
    @State private var settings = RenderSettings()
    @State private var engine = FilmEngine()

    private let catalog = StockCatalog.load()

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 690
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, 14)

                photoStage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 16)

                controls
                    .frame(height: compact ? 208 : 242)
                    .frame(maxWidth: .infinity)
                    .background(DarkroomStyle.panel, in: RoundedRectangle(cornerRadius: 28))
                    .overlay {
                        RoundedRectangle(cornerRadius: 28)
                            .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)

                bottomNavigation
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DarkroomStyle.background.ignoresSafeArea())
            .preferredColorScheme(.dark)
            .tint(DarkroomStyle.accent)
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                importPhoto(item)
            }
            .sheet(isPresented: $showingHistory) {
                historyView
            }
            .sheet(isPresented: $showingAdjustments) {
                adjustmentSheet
            }
            .sheet(isPresented: $showingStockOrder) {
                stockOrderSheet
            }
            .sheet(isPresented: $showingStockBrowser) {
                stockBrowserSheet
            }
            .alert("无法完成冲印", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("好") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SPECTRAL")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .tracking(3.8)
                    .foregroundStyle(DarkroomStyle.accent)
                Text("暗房")
                    .font(.system(size: 29, weight: .semibold, design: .serif))
                    .foregroundStyle(.white)
            }
            Spacer()
            PhotosPicker(selection: $selectedPhoto, matching: .images,
                         preferredItemEncoding: .current) {
                Label("相册", systemImage: "photo.badge.plus")
                    .labelStyle(.iconOnly)
                    .frame(width: 36, height: 36)
            }
            .modifier(GlassActionStyle())
            .accessibilityLabel("从相册选取照片")
            Button {
                process(tier: "full")
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 36, height: 36)
            }
            .modifier(GlassActionStyle())
            .accessibilityLabel("导出到相册")
            .disabled(selectedURL == nil || isWorking)
        }
    }

    private var photoStage: some View {
        GeometryReader { area in
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.black.opacity(0.38))
                if let preview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: area.size.width - 24, maxHeight: area.size.height - 24)
                        .shadow(color: .black.opacity(0.5), radius: 20, y: 9)
                        .accessibilityLabel("冲印预览")
                } else {
                    VStack(spacing: 18) {
                        Image(systemName: "photo.artframe")
                            .font(.system(size: 42, weight: .ultraLight))
                            .foregroundStyle(DarkroomStyle.accent.opacity(0.8))
                        VStack(spacing: 7) {
                            Text("把照片带进暗房")
                                .font(.system(size: 22, weight: .medium, design: .serif))
                                .foregroundStyle(.white)
                            Text("从相册选一张照片，试试胶片与相纸的组合")
                                .font(.system(size: 13))
                                .foregroundStyle(DarkroomStyle.muted)
                                .multilineTextAlignment(.center)
                        }
                        PhotosPicker(selection: $selectedPhoto, matching: .images,
                                     preferredItemEncoding: .current) {
                            Label("从相册选取", systemImage: "photo.on.rectangle")
                                .font(.system(size: 14, weight: .semibold))
                                .padding(.horizontal, 18)
                                .padding(.vertical, 11)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(DarkroomStyle.accent)
                        .foregroundStyle(.black)
                    }
                    .padding(18)
                }
                if isWorking {
                    Color.black.opacity(0.35)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    ProgressView("正在冲印")
                        .tint(DarkroomStyle.accent)
                        .padding(18)
                        .background(.regularMaterial, in: Capsule())
                }
            }
            .frame(width: area.size.width, height: area.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(alignment: .topLeading) {
                if preview != nil {
                    Text("LIVE PREVIEW")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(12)
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack {
                Text(activePanel.rawValue)
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundStyle(.white)
                Spacer()
                Text(activePanel == .adjust ? "松开滑块后冲印" : "点选后自动冲印")
                    .font(.system(size: 11))
                    .foregroundStyle(DarkroomStyle.muted)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)

            ScrollView {
                Group {
                    switch activePanel {
                    case .film:
                        stockChoices(catalog.films, subtitle: "FILM STOCK", isFilm: true)
                    case .paper:
                        if selectedFilm?.positive == true {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("直接扫描", systemImage: "scanner")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(DarkroomStyle.accent)
                                Text("反转片按原始胶片观看，无需选择相纸")
                                    .font(.system(size: 12))
                                    .foregroundStyle(DarkroomStyle.muted)
                            }
                            .padding(.horizontal, 24)
                        } else {
                            stockChoices(catalog.papers, subtitle: "PRINT PAPER", isFilm: false)
                        }
                    case .adjust:
                        VStack(alignment: .leading, spacing: 8) {
                            adjustment("胶片曝光", value: $settings.exposure, range: -8...8,
                                       format: "%.1f EV")
                            adjustment("印相曝光", value: $settings.printExposure, range: 0.05...4,
                                       format: "%.2f")
                            Button {
                                showingAdjustments = true
                            } label: {
                                Label("展开全部微调参数", systemImage: "slider.horizontal.3")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .padding(.horizontal, 24)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 13)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)

            HStack(spacing: 7) {
                Circle()
                    .fill(selectedURL == nil ? DarkroomStyle.muted : DarkroomStyle.accent)
                    .frame(width: 6, height: 6)
                Text(selectedURL == nil ? "等待照片" : "已载入 · 调整后自动冲印")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text(pairStatus)
                    .font(.system(size: 11))
            }
            .foregroundStyle(DarkroomStyle.muted)
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 9)
        }
    }

    private var pairStatus: String {
        if scanFilm { return "直接扫描" }
        return "原片保留"
    }

    private var selectedFilm: Stock? {
        catalog.films.first(where: { $0.id == film })
    }

    private var bottomNavigation: some View {
        HStack(spacing: 10) {
            GeometryReader { area in
                navigationItems
                    .frame(width: area.size.width, height: 58)
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { gesture in
                                guard abs(gesture.translation.width) >
                                      abs(gesture.translation.height) else { return }
                                let width = area.size.width
                                guard width > 0 else { return }
                                let index = min(max(Int(gesture.location.x / (width / 3)), 0), 2)
                                let panel = EditPanel.allCases[index]
                                if activePanel != panel {
                                    withAnimation(.snappy(duration: 0.16)) {
                                        activePanel = panel
                                    }
                                }
                            }
                    )
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .modifier(NavigationGlass())
            Button {
                records = loadRecords()
                showingHistory = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .modifier(NavigationGlass())
            .accessibilityLabel("导出记录")
        }
        .padding(.horizontal, 18)
        .frame(height: 78)
        .frame(maxWidth: .infinity)
        .background(DarkroomStyle.background)
    }

    private var navigationItems: some View {
        HStack(spacing: 0) {
            ForEach(EditPanel.allCases, id: \.self) { panel in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { activePanel = panel }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: panel.symbol)
                            .font(.system(size: 20, weight: .medium))
                            .frame(height: 23)
                        Text(panel.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                    }
                        .foregroundStyle(activePanel == panel ? DarkroomStyle.accent : .white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(activePanel == panel ? .white.opacity(0.14) : .clear,
                                    in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .id(panel)
                .accessibilityAddTraits(activePanel == panel ? .isSelected : [])
            }
        }
        .padding(3)
    }

    private func stockChoices(_ stocks: [Stock], subtitle: String, isFilm: Bool) -> some View {
        let sort = StockSort(rawValue: isFilm ? filmSort : paperSort) ?? .defaultOrder
        let sorted = orderedStocks(stocks, isFilm: isFilm)
        let ordered = isFilm ? sorted : sorted.filter(isPaperCompatible)
            + sorted.filter { !isPaperCompatible($0) }
        let selected = isFilm ? film : paper
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(subtitle)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(DarkroomStyle.muted)
                Spacer()
                Button {
                    browsingFilm = isFilm
                    stockQuery = ""
                    browserCategory = "全部"
                    showingStockBrowser = true
                } label: {
                    Label("查找", systemImage: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                }
                .accessibilityLabel(isFilm ? "查找胶片" : "查找相纸")
                Menu {
                    ForEach(isFilm ? [StockSort.defaultOrder, .name, .iso, .recent, .custom]
                                   : [StockSort.defaultOrder, .name, .recent, .custom],
                            id: \.rawValue) { option in
                        Button {
                            if isFilm { filmSort = option.rawValue }
                            else { paperSort = option.rawValue }
                            if option == .custom { openStockOrder(isFilm: isFilm) }
                        } label: {
                            if sort == option {
                                Label(option.title, systemImage: option == .custom
                                      ? "line.3.horizontal.decrease" : "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                } label: {
                    Label("排序：\(sort.title)", systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 11, weight: .medium))
                }
                .accessibilityLabel("材料排序")
            }
            .padding(.horizontal, 24)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 10) {
                        ForEach(ordered) { stock in
                            let chosen = selected == stock.id
                            let available = isFilm || isPaperCompatible(stock)
                            StockPreviewCard(
                                stock: stock, chosen: chosen, available: available,
                                isFilm: isFilm
                            ) {
                                chooseStock(stock, isFilm: isFilm)
                            }
                            .id(stock.id)
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    DispatchQueue.main.async { proxy.scrollTo(selected, anchor: .center) }
                }
                .onChange(of: activePanel) { _, panel in
                    if panel == (isFilm ? .film : .paper) {
                        DispatchQueue.main.async { proxy.scrollTo(selected, anchor: .center) }
                    }
                }
                .onChange(of: selected) { _, id in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .onChange(of: sort) { _, _ in
                    DispatchQueue.main.async { proxy.scrollTo(selected, anchor: .center) }
                }
            }
            .id(isFilm ? "film-cards" : "paper-cards")
        }
    }

    private func chooseStock(_ stock: Stock, isFilm: Bool) {
        if isFilm {
            film = stock.id
            markUsed(stock.id, isFilm: true)
            if stock.positive {
                scanFilm = true
            } else {
                scanFilm = false
                if stock.calibratedPapers.contains(stock.targetPrint) {
                    paper = stock.targetPrint
                    markUsed(paper, isFilm: false)
                }
            }
        } else {
            guard isPaperCompatible(stock) else { return }
            paper = stock.id
            scanFilm = false
            markUsed(stock.id, isFilm: false)
        }
        if selectedURL != nil { process(tier: "live") }
    }

    private func isPaperCompatible(_ stock: Stock) -> Bool {
        selectedFilm?.positive == false
            && (selectedFilm?.calibratedPapers.contains(stock.id) ?? false)
    }

    private func orderedStocks(_ stocks: [Stock], isFilm: Bool) -> [Stock] {
        let sort = StockSort(rawValue: isFilm ? filmSort : paperSort) ?? .defaultOrder
        let custom = (isFilm ? filmOrder : paperOrder).split(separator: ",").map(String.init)
        let recent = recentUse(isFilm: isFilm)
        let initial = Dictionary(uniqueKeysWithValues: stocks.enumerated().map { ($0.element.id, $0.offset) })
        switch sort {
        case .defaultOrder:
            return stocks
        case .name:
            return stocks.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        case .iso:
            return stocks.sorted {
                $0.iso == $1.iso
                    ? $0.label.localizedStandardCompare($1.label) == .orderedAscending
                    : $0.iso < $1.iso
            }
        case .recent:
            return stocks.sorted {
                let first = recent[$0.id] ?? 0
                let second = recent[$1.id] ?? 0
                return first == second
                    ? (initial[$0.id] ?? 0) < (initial[$1.id] ?? 0)
                    : first > second
            }
        case .custom:
            return stocks.sorted {
                let first = custom.firstIndex(of: $0.id) ?? custom.count + (initial[$0.id] ?? 0)
                let second = custom.firstIndex(of: $1.id) ?? custom.count + (initial[$1.id] ?? 0)
                return first < second
            }
        }
    }

    private func recentUse(isFilm: Bool) -> [String: TimeInterval] {
        let stored = isFilm ? filmRecentUse : paperRecentUse
        return (try? JSONDecoder().decode([String: TimeInterval].self, from: Data(stored.utf8))) ?? [:]
    }

    private func markUsed(_ id: String, isFilm: Bool) {
        var usage = recentUse(isFilm: isFilm)
        usage[id] = Date().timeIntervalSince1970
        guard let data = try? JSONEncoder().encode(usage),
              let value = String(data: data, encoding: .utf8) else { return }
        if isFilm { filmRecentUse = value }
        else { paperRecentUse = value }
    }

    private func openStockOrder(isFilm: Bool) {
        editingFilmOrder = isFilm
        draftOrder = orderedStocks(isFilm ? catalog.films : catalog.papers, isFilm: isFilm)
            .map(\.id)
        showingStockOrder = true
    }

    private var stockOrderSheet: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(draftOrder, id: \.self) { id in
                        if let stock = (editingFilmOrder ? catalog.films : catalog.papers)
                            .first(where: { $0.id == id }) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(stock.label)
                                Text(stock.originalName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onMove { source, destination in
                        draftOrder.move(fromOffsets: source, toOffset: destination)
                        let stored = draftOrder.joined(separator: ",")
                        if editingFilmOrder {
                            filmOrder = stored
                            filmSort = StockSort.custom.rawValue
                        } else {
                            paperOrder = stored
                            paperSort = StockSort.custom.rawValue
                        }
                    }
                } header: {
                    Text("拖动右侧手柄调整显示顺序")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(editingFilmOrder ? "排列胶片" : "排列相纸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showingStockOrder = false }
                }
            }
        }
    }

    private var browserCategories: [String] {
        if browsingFilm {
            return ["全部", "彩色负片", "电影负片", "黑白胶片", "反转片"]
        }
        let available = Set(catalog.papers.map(\.category))
        return ["全部", "推荐搭配", "彩色相纸", "电影拷贝", "黑白相纸"]
            .filter { $0 == "全部" || $0 == "推荐搭配" || available.contains($0) }
    }

    private var browserStocks: [Stock] {
        let all = browsingFilm ? catalog.films : catalog.papers
        let sorted = orderedStocks(all, isFilm: browsingFilm)
        let ordered = browsingFilm ? sorted : sorted.filter(isPaperCompatible)
            + sorted.filter { !isPaperCompatible($0) }
        return ordered.filter { stock in
            let matchesCategory: Bool
            if browserCategory == "推荐搭配" {
                matchesCategory = stock.id == selectedFilm?.targetPrint
            } else {
                matchesCategory = browserCategory == "全部" || stock.category == browserCategory
            }
            return matchesCategory && (stockQuery.isEmpty ||
                stock.label.localizedStandardContains(stockQuery) ||
                stock.originalName.localizedStandardContains(stockQuery) ||
                stock.id.localizedStandardContains(stockQuery))
        }
    }

    private func matchDescription(_ stock: Stock) -> String {
        if browsingFilm {
            if stock.strongHalation { return "强光晕 · 明亮文字和边缘可能发光" }
            if stock.positive { return "反转片 · 自动直接扫描" }
            return stock.category
        }
        guard let selected = selectedFilm else { return stock.category }
        if selected.targetPrint == stock.id { return "推荐搭配 · \(stock.category)" }
        return isPaperCompatible(stock)
            ? "可搭配 · \(stock.category)"
            : "当前胶片不可搭配"
    }

    private var stockBrowserSheet: some View {
        NavigationStack {
            List {
                Section {
                    Picker("类型", selection: $browserCategory) {
                        ForEach(browserCategories, id: \.self) { category in
                            Text(category).tag(category)
                        }
                    }
                    .pickerStyle(.menu)
                } footer: {
                    Text(browsingFilm
                         ? "CineStill 800T 的强光晕来自原始胶片配置，可在微调中调低或关闭。"
                         : "可搭配的相纸排在前面；置灰的相纸没有对应滤色数据，无法选择。")
                }
                Section {
                    ForEach(browserStocks) { stock in
                        Button {
                            chooseStock(stock, isFilm: browsingFilm)
                            showingStockBrowser = false
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(stock.label)
                                        .foregroundStyle(.primary)
                                    Text(stock.originalName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(matchDescription(stock))
                                        .font(.caption2)
                                        .foregroundStyle(stock.strongHalation
                                                         ? DarkroomStyle.accent : .secondary)
                                }
                                Spacer(minLength: 0)
                                if stock.id == (browsingFilm ? film : paper) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(DarkroomStyle.accent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .disabled(!browsingFilm && !isPaperCompatible(stock))
                        .opacity(browsingFilm || isPaperCompatible(stock) ? 1 : 0.4)
                    }
                } header: {
                    Text("共 \(browserStocks.count) 项")
                }
            }
            .searchable(text: $stockQuery, prompt: "搜索名称、品牌或感光度")
            .navigationTitle(browsingFilm ? "选择胶片" : "选择相纸")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showingStockBrowser = false }
                }
            }
        }
    }

    private func adjustment(_ title: String, value: Binding<Double>,
                            range: ClosedRange<Double>, format: String) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(title)
                    .foregroundStyle(.white)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(DarkroomStyle.accent)
            }
            .font(.system(size: 13, weight: .medium))
            Slider(value: value, in: range) { editing in
                if !editing && selectedURL != nil { process(tier: "live") }
            }
        }
        .padding(.horizontal, 24)
    }

    private func switchAdjustment(_ title: String, value: Binding<Bool>) -> some View {
        Toggle(title, isOn: value)
            .font(.system(size: 14))
            .onChange(of: value.wrappedValue) { _, _ in
                if selectedURL != nil { process(tier: "live") }
            }
    }

    private var adjustmentSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    adjustmentGroup("拍摄与底片") {
                        switchAdjustment("自动测光", value: $settings.autoExposure)
                        adjustment("胶片曝光", value: $settings.exposure, range: -8...8, format: "%.1f EV")
                        adjustment("画幅宽度", value: $settings.filmFormat, range: 4...200, format: "%.0f mm")
                        adjustment("镜头模糊", value: $settings.lensBlur, range: 0...50, format: "%.1f µm")
                        adjustment("底片曲线", value: $settings.densityGamma, range: 0.2...4, format: "%.2f")
                        adjustment("扫描镜头模糊", value: $settings.scannerBlur, range: 0...20,
                                   format: "%.1f")
                    }
                    adjustmentGroup("场景宽容度") {
                        switchAdjustment("启用宽容度映射", value: $settings.latitudeActive)
                        adjustment("高光拐点", value: $settings.highlightKnee, range: -4...8,
                                   format: "%+.1f EV")
                        adjustment("高光空间", value: $settings.highlightRoom, range: 0...8,
                                   format: "%.1f EV")
                        adjustment("暗部拐点", value: $settings.shadowKnee, range: -8...4,
                                   format: "%+.1f EV")
                        adjustment("暗部空间", value: $settings.shadowRoom, range: 0...8,
                                   format: "%.1f EV")
                        adjustment("过渡柔和度", value: $settings.latitudeRolloff, range: 1...4,
                                   format: "%.1f")
                    }
                    adjustmentGroup("放大与印相") {
                        if paper == "ilford_multigrade_iv_rc" {
                            Picker("黑白相纸反差等级", selection: $settings.paperGrade) {
                                ForEach(["00", "0", "1", "2", "3", "4", "5"], id: \.self) {
                                    Text($0).tag($0)
                                }
                            }
                            .onChange(of: settings.paperGrade) { _, _ in
                                if selectedURL != nil { process(tier: "live") }
                            }
                        }
                        adjustment("印相曝光", value: $settings.printExposure, range: 0.05...4, format: "%.2f")
                        adjustment("滤色幅度", value: $settings.filterScale, range: 1...60, format: "%.0f CC")
                        adjustment("品红滤色", value: $settings.magenta, range: -1...1, format: "%+.2f")
                        adjustment("黄色滤色", value: $settings.yellow, range: -1...1, format: "%+.2f")
                        adjustment("预曝光", value: $settings.preflash, range: 0...1, format: "%.2f")
                    }
                    adjustmentGroup("胶片质感") {
                        switchAdjustment("颗粒", value: $settings.grainActive)
                        adjustment("颗粒强度", value: $settings.grain, range: 0...2, format: "%.2f")
                        switchAdjustment("光晕", value: $settings.halationActive)
                        adjustment("光晕面积", value: $settings.halation, range: 0...4, format: "%.2f")
                        adjustment("高光光晕补偿", value: $settings.halationBoost, range: 0...8,
                                   format: "%.1f EV")
                        adjustment("散射", value: $settings.scatter, range: 0...1, format: "%.2f")
                        switchAdjustment("移除防光晕层", value: $settings.antiHalationRemoved)
                        switchAdjustment("成色剂耦合", value: $settings.dirActive)
                        adjustment("耦合强度", value: $settings.dirCouplers, range: 0...4, format: "%.2f")
                    }
                    adjustmentGroup("相纸与局部反差") {
                        switchAdjustment("扫描白点校正", value: $settings.scannerWhite)
                        switchAdjustment("扫描黑点校正", value: $settings.scannerBlack)
                        switchAdjustment("相纸眩光", value: $settings.glareActive)
                        adjustment("眩光面积", value: $settings.glare, range: 0...30, format: "%.1f")
                        switchAdjustment("反差蒙版", value: $settings.contrastMaskActive)
                        adjustment("高光", value: $settings.contrastHighlights, range: 0...3, format: "%.2f")
                        adjustment("阴影", value: $settings.contrastShadows, range: 0...3, format: "%.2f")
                        adjustment("核心宽度", value: $settings.contrastCore, range: 0...3, format: "%.2f")
                        adjustment("蒙版尺度", value: $settings.contrastScale, range: 0.002...0.12,
                                   format: "%.3f")
                    }
                    Button("恢复默认参数") {
                        settings = RenderSettings()
                        if selectedURL != nil { process(tier: "live") }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 20)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
            }
            .background(DarkroomStyle.background)
            .navigationTitle("微调")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showingAdjustments = false }
                }
            }
        }
    }

    private func adjustmentGroup<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .serif))
                .foregroundStyle(DarkroomStyle.accent)
            content()
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 4)
        .background(DarkroomStyle.panel, in: RoundedRectangle(cornerRadius: 20))
    }

    private func importPhoto(_ item: PhotosPickerItem) {
        isWorking = true
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                    throw RenderError.message("无法读取这张照片，请选择 JPEG、HEIC 或系统支持的 RAW")
                }
                let contentType = CGImageSourceGetType(source).map { $0 as String }
                let ext = contentType.flatMap { UTType($0)?.preferredFilenameExtension } ?? "img"
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("spectral-photo-\(UUID().uuidString)")
                    .appendingPathExtension(ext)
                try data.write(to: url, options: .atomic)
                selectedURL = url
                selectedPhoto = nil
                preview = nil
                isWorking = false
                process(tier: "live")
            } catch {
                isWorking = false
                self.error = error.localizedDescription
            }
        }
    }

    private func process(tier: String) {
        guard let url = selectedURL else { return }
        isWorking = true
        let film = film, paper = paper, settings = settings
        Task {
            do {
                let result = try await engine.render(
                    url: url, film: film, paper: paper, scanFilm: scanFilm,
                    settings: settings, tier: tier
                )
                let picture = try result.image()
                preview = picture
                if tier == "full" {
                    let target = FileManager.default.temporaryDirectory
                        .appendingPathComponent("SpectralDarkroom-\(UUID().uuidString).jpg")
                    guard let destination = CGImageDestinationCreateWithURL(
                        target as CFURL, UTType.jpeg.identifier as CFString, 1, nil
                    ) else { throw RenderError.message("无法创建 JPEG 文件") }
                    CGImageDestinationAddImage(destination, picture, [
                        kCGImageDestinationLossyCompressionQuality: 0.95
                    ] as CFDictionary)
                    guard CGImageDestinationFinalize(destination) else {
                        throw RenderError.message("无法写入 JPEG 文件")
                    }
                    try await saveToPhotos(target)
                    let historyURL = try historyDirectory()
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension("jpg")
                    try FileManager.default.copyItem(at: target, to: historyURL)
                    records = loadRecords()
                }
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func saveToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw RenderError.message("没有保存到相册的权限；请在系统设置中允许添加照片")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
        }
    }

    private func historyDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask, appropriateFor: nil,
                                               create: true)
            .appendingPathComponent("ExportHistory", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func loadRecords() -> [ExportRecord] {
        guard let directory = try? historyDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return urls.filter { $0.pathExtension.lowercased() == "jpg" }
            .map { url in
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
                    ?? .distantPast
                return ExportRecord(url: url, date: date)
            }
            .sorted { $0.date > $1.date }
    }

    private var historyView: some View {
        NavigationStack {
            ScrollView {
                if records.isEmpty {
                    ContentUnavailableView("暂无导出记录", systemImage: "photo.stack",
                                           description: Text("保存到相册的照片会显示在这里"))
                        .padding(.top, 70)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                              spacing: 14) {
                        ForEach(records) { record in
                            Button { selectedRecord = record } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    if let thumbnail = record.thumbnail {
                                        Image(uiImage: thumbnail)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(height: 170)
                                            .frame(maxWidth: .infinity)
                                            .clipped()
                                            .clipShape(RoundedRectangle(cornerRadius: 14))
                                    }
                                    Text(record.date, format: .dateTime.year().month().day()
                                        .hour().minute())
                                        .font(.caption)
                                        .foregroundStyle(DarkroomStyle.muted)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(18)
                }
            }
            .background(DarkroomStyle.background)
            .navigationTitle("导出记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showingHistory = false }
                }
            }
        }
        .sheet(item: $selectedRecord) { record in
            recordDetail(record)
        }
    }

    private func recordDetail(_ record: ExportRecord) -> some View {
        NavigationStack {
            GeometryReader { area in
                if let image = UIImage(contentsOfFile: record.url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: area.size.width, height: area.size.height)
                }
            }
            .background(DarkroomStyle.background)
            .navigationTitle("已保存到相册")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { selectedRecord = nil }
                }
            }
        }
    }
}
