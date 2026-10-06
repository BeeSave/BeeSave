import Foundation
import ImageIO

public enum BankImages {
    public static func validate(_ data: Data) throws {
        guard data.count <= 2 * 1024 * 1024, data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) || data.starts(with: [255, 216, 255]), let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int, (1...4096).contains(width), (1...4096).contains(height), CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else { throw BudgetError.invalid("Логотип должен быть корректным PNG/JPEG до 2 MiB и 4096 × 4096 пикселей.") }
    }
    public static func normalized(_ data: Data) throws -> Data {
        try validate(data)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw BudgetError.invalid("Изображение не читается.") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { throw BudgetError.storage("Не удалось подготовить изображение.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= 2 * 1024 * 1024 else { throw BudgetError.invalid("Подготовленный логотип превышает 2 MiB.") }
        return output as Data
    }
}
