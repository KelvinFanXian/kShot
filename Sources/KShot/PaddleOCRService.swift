import AppKit
import Foundation
import OnnxRuntimeBindings

enum PaddleOCRError: LocalizedError {
    case missingResource(String)
    case invalidImage
    case invalidModelOutput([Int])
    case noText

    var errorDescription: String? {
        switch self {
        case let .missingResource(name): "缺少本地 OCR 资源：\(name)"
        case .invalidImage: "无法读取待识别图片"
        case let .invalidModelOutput(shape): "本地 OCR 返回了异常结果：\(shape)"
        case .noText: "没有识别到文字"
        }
    }
}

actor PaddleOCRService {
    static let shared = PaddleOCRService()

    private let modelURLOverride: URL?
    private let dictionaryURLOverride: URL?
    private var environment: ORTEnv?
    private var session: ORTSession?
    private var inputName = ""
    private var outputNames = Set<String>()
    private var decoder: PaddleOCRDecoder?

    init(modelURL: URL? = nil, dictionaryURL: URL? = nil) {
        modelURLOverride = modelURL
        dictionaryURLOverride = dictionaryURL
    }

    func recognize(_ image: NSImage) throws -> String {
        let session = try loadedSession()
        defer { unloadSession() }
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw PaddleOCRError.invalidImage
        }
        let input = try Self.preprocess(cgImage)
        let tensorData = NSMutableData(
            bytes: input.values,
            length: input.values.count * MemoryLayout<Float>.stride
        )
        let tensor = try ORTValue(
            tensorData: tensorData,
            elementType: .float,
            shape: input.shape.map(NSNumber.init(value:))
        )
        let outputs = try session.run(
            withInputs: [inputName: tensor],
            outputNames: outputNames,
            runOptions: nil
        )
        guard let value = outputs.values.first else {
            throw PaddleOCRError.invalidModelOutput([])
        }
        let info = try value.tensorTypeAndShapeInfo()
        let shape = info.shape.map(\.intValue)
        let data = try value.tensorData() as Data
        let floats: [Float] = data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Float.self))
        }
        guard let decoder else { throw PaddleOCRError.invalidModelOutput(shape) }
        let result = try decoder.decode(floats, shape: shape)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw PaddleOCRError.noText }
        return result
    }

    private func unloadSession() {
        session = nil
        environment = nil
        inputName = ""
        outputNames.removeAll(keepingCapacity: false)
        decoder = nil
    }

    private func loadedSession() throws -> ORTSession {
        if let session { return session }
        guard let modelURL = modelURLOverride ?? Bundle.main.url(
            forResource: "PP-OCRv6_tiny_rec",
            withExtension: "onnx",
            subdirectory: "PaddleOCR"
        ) else {
            throw PaddleOCRError.missingResource("PP-OCRv6_tiny_rec.onnx")
        }
        guard let dictionaryURL = dictionaryURLOverride ?? Bundle.main.url(
            forResource: "character_dict",
            withExtension: "txt",
            subdirectory: "PaddleOCR"
        ) else {
            throw PaddleOCRError.missingResource("character_dict.txt")
        }

        var dictionary = try String(contentsOf: dictionaryURL, encoding: .utf8)
            .components(separatedBy: .newlines)
        if dictionary.last == "" { dictionary.removeLast() }
        let decoder = PaddleOCRDecoder(characters: dictionary)
        let environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        try options.setIntraOpNumThreads(Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))))
        let session = try ORTSession(
            env: environment,
            modelPath: modelURL.path,
            sessionOptions: options
        )
        guard let inputName = try session.inputNames().first else {
            throw PaddleOCRError.invalidModelOutput([])
        }

        self.environment = environment
        self.session = session
        self.inputName = inputName
        self.outputNames = Set(try session.outputNames())
        self.decoder = decoder
        return session
    }

    private static func preprocess(_ image: CGImage) throws -> (values: [Float], shape: [Int]) {
        let sourceWidth = image.width
        let sourceHeight = image.height
        guard sourceWidth > 0, sourceHeight > 0 else { throw PaddleOCRError.invalidImage }

        let targetHeight = 48
        let defaultWidth = 320
        let maximumWidth = 3200
        let scaledWidth = max(1, Int(ceil(CGFloat(targetHeight) * CGFloat(sourceWidth) / CGFloat(sourceHeight))))
        let canvasWidth = min(max(defaultWidth, scaledWidth), maximumWidth)
        let contentWidth = min(scaledWidth, canvasWidth)
        let bytesPerRow = contentWidth * 4
        var rgba = [UInt8](repeating: 0, count: targetHeight * bytesPerRow)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &rgba,
                width: contentWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            throw PaddleOCRError.invalidImage
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: contentWidth, height: targetHeight))

        let planeSize = targetHeight * canvasWidth
        var values = [Float](repeating: 0, count: planeSize * 3)
        for y in 0..<targetHeight {
            for x in 0..<contentWidth {
                let sourceOffset = (y * contentWidth + x) * 4
                let targetOffset = y * canvasWidth + x
                let red = Float(rgba[sourceOffset]) / 127.5 - 1
                let green = Float(rgba[sourceOffset + 1]) / 127.5 - 1
                let blue = Float(rgba[sourceOffset + 2]) / 127.5 - 1
                values[targetOffset] = blue
                values[planeSize + targetOffset] = green
                values[planeSize * 2 + targetOffset] = red
            }
        }
        return (values, [1, 3, targetHeight, canvasWidth])
    }
}

struct PaddleOCRDecoder {
    private let characters: [String]

    init(characters: [String]) {
        self.characters = ["blank"] + characters + [" "]
    }

    func decode(_ values: [Float], shape: [Int]) throws -> String {
        guard shape.count == 3, shape[0] == 1, shape[1] > 0, shape[2] > 0,
              values.count == shape.reduce(1, *) else {
            throw PaddleOCRError.invalidModelOutput(shape)
        }
        let steps = shape[1]
        let classes = shape[2]
        var previous = -1
        var text = ""

        for step in 0..<steps {
            let offset = step * classes
            var bestIndex = 0
            var bestValue = values[offset]
            for index in 1..<classes where values[offset + index] > bestValue {
                bestValue = values[offset + index]
                bestIndex = index
            }
            if bestIndex != 0, bestIndex != previous, bestIndex < characters.count {
                text += characters[bestIndex]
            }
            previous = bestIndex
        }
        return text
    }
}
