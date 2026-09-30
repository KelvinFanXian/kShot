import AppKit
import Foundation

enum ZhipuOCRError: LocalizedError {
    case missingAPIKey
    case invalidImage
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "尚未设置智谱 Coding Plan Key"
        case .invalidImage: "无法生成待识别的图片"
        case .invalidResponse: "智谱返回了无法解析的结果"
        case let .server(message): message
        }
    }
}

struct ZhipuOCRService {
    static let endpoint = URL(string: "https://open.bigmodel.cn/api/coding/paas/v4/chat/completions")!

    func recognize(_ image: NSImage) async throws -> String {
        guard let apiKey = APIKeyStore.shared.load() else { throw ZhipuOCRError.missingAPIKey }
        guard let imageData = pngData(from: image) else { throw ZhipuOCRError.invalidImage }

        let systemPrompt = """
        你是截图文字识别工具。准确提取图片中所有可见文字，保持原有阅读顺序、换行、列表和代码缩进。
        只输出识别出的正文，不要解释，不要添加标题，不要使用 Markdown 代码围栏。无法确认的字符用〔?〕标记，不要猜测。
        """
        let body: [String: Any] = [
            "model": "glm-5.3-flash",
            "messages": [
                ["role": "system", "content": systemPrompt],
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image_url",
                            "image_url": ["url": "data:image/png;base64,\(imageData.base64EncodedString())"]
                        ],
                        ["type": "text", "text": "识别并逐字转录这张截图中的全部文字。"]
                    ]
                ]
            ],
            "thinking": ["type": "enabled"],
            "stream": false,
            "temperature": 0.8,
            "top_p": 0.6,
            "max_tokens": 131_072
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("KShot OCR", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ZhipuOCRError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ZhipuOCRError.server(Self.errorMessage(from: data, statusCode: http.statusCode))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ZhipuOCRError.invalidResponse
        }
        let result = Self.cleaned(content)
        guard !result.isEmpty else { throw ZhipuOCRError.invalidResponse }
        return result
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    static func cleaned(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") && result.hasSuffix("```") {
            let lines = result.components(separatedBy: .newlines)
            if lines.count >= 2 {
                result = lines.dropFirst().dropLast().joined(separator: "\n")
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func errorMessage(from data: Data, statusCode: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return "智谱请求失败（\(statusCode)）：\(message)"
        }
        return "智谱请求失败（HTTP \(statusCode)）"
    }
}
