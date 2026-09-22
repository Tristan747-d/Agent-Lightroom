// al-vision —— 把一张照片变成 LLM 可读的「视觉摘要」(JSON)。
//
// 为什么需要它：本机没有可用的视觉大模型，而纯文本 LLM 无法直接看图。
// macOS Vision 框架能在本机（免费、离线、无隐私外泄）把图像转成**语义+数值摘要**：
// 曝光分布、白平衡偏移、锐度、显著主体、人脸质量/睁闭眼、场景标签、
// 文本密度（文档/截图判定）、地平线倾角、美学评分、主体与背景的亮度差。
// LLM 读这份摘要 + 一条固定的映射规则，就能给出可信的后期参数与保/弃判断。
//
// 编译：swiftc -O -o al-vision al-vision.swift
// 用法：al-vision <图片路径>
import Foundation
import Vision
import CoreImage
import ImageIO

// ── 工具 ────────────────────────────────────────────────────────────────
func j(_ value: Any) -> String {
    if let n = value as? Double { return String(format: "%.4f", n) }
    if let n = value as? Int { return String(n) }
    if let s = value as? String { return "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\"" }
    if let b = value as? Bool { return b ? "true" : "false" }
    if let a = value as? [Any] { return "[" + a.map { j($0) }.joined(separator: ",") + "]" }
    if let d = value as? [String: Any] { return json(d) }
    if value is NSNull { return "null" }
    return "\"\(value)\""
}
func json(_ dict: [String: Any]) -> String {
    "{" + dict.keys.sorted().map { "\"\($0)\":" + j(dict[$0]!) }.joined(separator: ",") + "}"
}

// 把 CGImage 缩放到最长边 maxDim，便于做像素统计（也顺带降噪）。
func scaled(_ image: CGImage, maxDim: Int) -> CGImage {
    let w = image.width, h = image.height
    let scale = Double(maxDim) / Double(max(w, h))
    if scale >= 1 { return image }
    let nw = max(1, Int(Double(w) * scale)), nh = max(1, Int(Double(h) * scale))
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8,
                              bytesPerRow: nw * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
    return ctx.makeImage() ?? image
}

struct Pixels {
    var width = 0, height = 0
    var luma: [Double] = []          // 0..255 亮度
    var saturation: [Double] = []    // 0..1
    var meanR = 0.0, meanG = 0.0, meanB = 0.0
}

func readPixels(_ image: CGImage, maxDim: Int = 512) -> Pixels {
    let img = scaled(image, maxDim: maxDim)
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Pixels() }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var p = Pixels(width: w, height: h)
    p.luma.reserveCapacity(w * h); p.saturation.reserveCapacity(w * h)
    var sr = 0.0, sg = 0.0, sb = 0.0
    for i in stride(from: 0, to: buf.count, by: 4) {
        let r = Double(buf[i]), g = Double(buf[i + 1]), b = Double(buf[i + 2])
        sr += r; sg += g; sb += b
        p.luma.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
        let mx = max(r, max(g, b)), mn = min(r, min(g, b))
        p.saturation.append(mx <= 0 ? 0 : (mx - mn) / mx)
    }
    let n = Double(w * h)
    p.meanR = sr / n; p.meanG = sg / n; p.meanB = sb / n
    return p
}

func percentile(_ sorted: [Double], _ pct: Double) -> Double {
    if sorted.isEmpty { return 0 }
    let idx = Int((pct / 100.0) * Double(sorted.count - 1)).clamped(to: 0...(sorted.count - 1))
    return sorted[idx]
}
extension Int { func clamped(to r: ClosedRange<Int>) -> Int { Swift.min(Swift.max(self, r.lowerBound), r.upperBound) } }

// 拉普拉斯方差：经典的「清晰度」代理指标（越低越糊）。
func laplacianVariance(_ image: CGImage, maxDim: Int = 512) -> Double {
    let img = scaled(image, maxDim: maxDim)
    let w = img.width, h = img.height
    var gray = [Double](repeating: 0, count: w * h)
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    for i in 0..<(w * h) {
        gray[i] = 0.2126 * Double(buf[i * 4]) + 0.7152 * Double(buf[i * 4 + 1]) + 0.0722 * Double(buf[i * 4 + 2])
    }
    var vals: [Double] = []
    for y in 1..<(h - 1) {
        for x in 1..<(w - 1) {
            let i = y * w + x
            vals.append(-4 * gray[i] + gray[i - 1] + gray[i + 1] + gray[i - w] + gray[i + w])
        }
    }
    guard !vals.isEmpty else { return 0 }
    let mean = vals.reduce(0, +) / Double(vals.count)
    return vals.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(vals.count)
}

// ── 主流程 ──────────────────────────────────────────────────────────────
let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("用法: al-vision <图片路径>\n".data(using: .utf8)!)
    exit(2)
}
let path = args[1]
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    print(json(["error": "无法解码图片: \(path)"]))
    exit(1)
}

var out: [String: Any] = [:]
out["file"] = path
out["width"] = cg.width
out["height"] = cg.height

// 1) 像素级：曝光分布 / 白平衡 / 饱和度 / 锐度
let px = readPixels(cg)
let sortedLuma = px.luma.sorted()
let meanLuma = px.luma.reduce(0, +) / Double(max(1, px.luma.count))
let variance = px.luma.reduce(0) { $0 + ($1 - meanLuma) * ($1 - meanLuma) } / Double(max(1, px.luma.count))
let clippedHigh = Double(px.luma.filter { $0 >= 250 }.count) / Double(max(1, px.luma.count)) * 100
let clippedLow = Double(px.luma.filter { $0 <= 5 }.count) / Double(max(1, px.luma.count)) * 100
out["tone"] = [
    "mean_luma": meanLuma,
    "p1": percentile(sortedLuma, 1), "p5": percentile(sortedLuma, 5),
    "p50": percentile(sortedLuma, 50), "p95": percentile(sortedLuma, 95),
    "p99": percentile(sortedLuma, 99),
    "contrast_std": variance.squareRoot(),
    "clipped_high_pct": clippedHigh, "clipped_low_pct": clippedLow,
]
let safeG = max(1.0, px.meanG)
out["color"] = [
    "mean_r": px.meanR, "mean_g": px.meanG, "mean_b": px.meanB,
    "wb_r_over_g": px.meanR / safeG, "wb_b_over_g": px.meanB / safeG,
    "saturation_mean": px.saturation.reduce(0, +) / Double(max(1, px.saturation.count)),
]
let lap = laplacianVariance(cg)
let sharpVerdict = lap < 30 ? "blurry" : (lap < 120 ? "soft" : "sharp")
out["sharpness"] = ["laplacian_var": lap, "verdict": sharpVerdict]

// 2) Vision：语义与结构化视觉
let handler = VNImageRequestHandler(cgImage: cg, options: [:])

// 2a) 场景标签
do {
    let req = VNClassifyImageRequest()
    try handler.perform([req])
    if let obs = req.results {
        out["labels"] = obs.prefix(8).map { ["id": $0.identifier, "confidence": Double($0.confidence)] }
    }
} catch { out["labels"] = [] }

// 2b) 文本（文档/截图判定的硬证据）
do {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .fast
    req.usesLanguageCorrection = false
    try handler.perform([req])
    // 注意：boundingBox 在 VNRecognizedTextObservation 上（candidate 只有 boundingBoxForRange，且 throws）
    let observations = req.results ?? []
    var coverage = 0.0
    var conf = 0.0
    var lineCount = 0
    for obs in observations {
        guard let cand = obs.topCandidates(1).first else { continue }
        lineCount += 1
        coverage += Double(obs.boundingBox.width * obs.boundingBox.height)
        conf += Double(cand.confidence)
    }
    out["text"] = [
        "line_count": lineCount,
        "box_coverage": Swift.min(1.0, coverage),
        "avg_confidence": lineCount == 0 ? 0 : conf / Double(lineCount),
        "is_document_like": (lineCount >= 6 && coverage > 0.05),
    ]
} catch { out["text"] = ["line_count": 0, "box_coverage": 0.0, "avg_confidence": 0.0, "is_document_like": false] }

// 2c) 人脸：数量 / 质量 / 睁闭眼（眼睛纵横比）
do {
    let faces = VNDetectFaceRectanglesRequest()
    try handler.perform([faces])
    let faceObs = faces.results ?? []
    var items: [[String: Any]] = []
    let landmarks = VNDetectFaceLandmarksRequest()
    try? handler.perform([landmarks])
    for (i, f) in faceObs.enumerated() {
        var item: [String: Any] = [
            "box": [Double(f.boundingBox.minX), Double(f.boundingBox.minY),
                    Double(f.boundingBox.width), Double(f.boundingBox.height)],
        ]
        // 人脸区域锐度：比"整图锐度"更能回答"主体/眼睛是否合焦"（本机 SDK 无人脸质量 API）
        let bb = f.boundingBox
        let rect = CGRect(x: bb.minX * Double(cg.width),
                          y: (1.0 - Double(bb.maxY)) * Double(cg.height),
                          width: bb.width * Double(cg.width),
                          height: bb.height * Double(cg.height)).integral
        if rect.width > 8, rect.height > 8, let crop = cg.cropping(to: rect) {
            item["face_sharpness"] = laplacianVariance(crop, maxDim: 256)
        }
        if let lm = landmarks.results?.first(where: { $0.boundingBox == f.boundingBox }),
           let left = lm.landmarks?.leftEye, let right = lm.landmarks?.rightEye {
            func ear(_ region: VNFaceLandmarkRegion2D) -> Double {
                let pts = region.normalizedPoints
                guard pts.count >= 4 else { return 0 }
                let xs = pts.map { Double($0.x) }, ys = pts.map { Double($0.y) }
                let w = (xs.max()! - xs.min()!), h = (ys.max()! - ys.min()!)
                return w <= 0 ? 0 : h / w
            }
            let el = ear(left), er = ear(right)
            item["eye_aspect_ratio_left"] = el
            item["eye_aspect_ratio_right"] = er
            // 经验阈值：EAR < 0.18 视为闭合（仅作提示，最终由算法层判定）
            item["eyes_open"] = (el > 0.18 && er > 0.18)
        }
        items.append(item)
    }
    out["faces"] = ["count": faceObs.count, "items": items]
} catch { out["faces"] = ["count": 0, "items": []] }

// 2d) 显著主体（attention saliency）
do {
    let req = VNGenerateAttentionBasedSaliencyImageRequest()
    try handler.perform([req])
    if let obs = req.results?.first as? VNSaliencyImageObservation,
       let salient = obs.salientObjects?.first {
        out["subject"] = [
            "box": [Double(salient.boundingBox.minX), Double(salient.boundingBox.minY),
                    Double(salient.boundingBox.width), Double(salient.boundingBox.height)],
            "coverage": Double(salient.boundingBox.width * salient.boundingBox.height),
        ]
    } else { out["subject"] = ["coverage": 0.0] }
} catch { out["subject"] = ["coverage": 0.0] }

// 2e) 地平线倾角（决定是否需要自动拉直）
do {
    let req = VNDetectHorizonRequest()
    try handler.perform([req])
    if let obs = req.results?.first as? VNHorizonObservation {
        out["horizon"] = ["angle_deg": Double(obs.angle) * 180.0 / .pi]
    } else { out["horizon"] = ["angle_deg": 0.0] }
} catch { out["horizon"] = ["angle_deg": 0.0] }

// 2f) 美学评分 + 是否"工具类图片"（截图/文档）—— macOS 15+
if #available(macOS 15.0, *) {
    do {
        let req = VNCalculateImageAestheticsScoresRequest()
        try handler.perform([req])
        if let obs = req.results?.first as? VNImageAestheticsScoresObservation {
            out["aesthetics"] = ["overall_score": Double(obs.overallScore), "is_utility": obs.isUtility]
        }
    } catch { out["aesthetics"] = ["overall_score": 0.0, "is_utility": false] }
}

// 2g) 人像分割：主体 vs 背景 亮度差（判断"背景抢戏/主体欠曝"）
if #available(macOS 12.0, *) {
    do {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .fast
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try handler.perform([req])
        if let obs = req.results?.first as? VNPixelBufferObservation {
            let mask = obs.pixelBuffer
            CVPixelBufferLockBaseAddress(mask, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
            let mw = CVPixelBufferGetWidth(mask), mh = CVPixelBufferGetHeight(mask)
            let stride = CVPixelBufferGetBytesPerRow(mask)
            let base = CVPixelBufferGetBaseAddress(mask)!.assumingMemoryBound(to: UInt8.self)
            let small = scaled(cg, maxDim: 256)
            var buf = [UInt8](repeating: 0, count: small.width * small.height * 4)
            let cs = CGColorSpaceCreateDeviceRGB()
            if let ctx = CGContext(data: &buf, width: small.width, height: small.height,
                                   bitsPerComponent: 8, bytesPerRow: small.width * 4, space: cs,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.draw(small, in: CGRect(x: 0, y: 0, width: small.width, height: small.height))
                var subjSum = 0.0, subjN = 0.0, bgSum = 0.0, bgN = 0.0
                for y in 0..<small.height {
                    for x in 0..<small.width {
                        let mx = Swift.min(mw - 1, x * mw / small.width)
                        let my = Swift.min(mh - 1, y * mh / small.height)
                        let conf = Double(base[my * stride + mx]) / 255.0
                        let i = (y * small.width + x) * 4
                        let luma = 0.2126 * Double(buf[i]) + 0.7152 * Double(buf[i + 1]) + 0.0722 * Double(buf[i + 2])
                        if conf > 0.5 { subjSum += luma; subjN += 1 } else { bgSum += luma; bgN += 1 }
                    }
                }
                let subj = subjN > 0 ? subjSum / subjN : 0
                let bg = bgN > 0 ? bgSum / bgN : 0
                out["person_segmentation"] = [
                    "subject_luma": subj, "background_luma": bg,
                    "subject_ratio": subjN / Double(max(1, subjN + bgN)),
                    "subject_minus_background": subj - bg,
                ]
            }
        }
    } catch { /* 无人像时属正常 */ }
}

print(json(out))
