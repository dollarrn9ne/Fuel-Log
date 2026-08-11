#if canImport(UIKit)
import UIKit
#endif
import Vision

class ReceiptParser {
    static func parse(image: UIImage, isFuel: Bool, completion: @escaping @Sendable (Double?, Double?, Double?) -> Void) {
        guard let cgImage = image.cgImage else {
            completion(nil, nil, nil)
            return
        }
        
        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest { request, error in
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                DispatchQueue.main.async { completion(nil, nil, nil) }
                return
            }
            
            // Extract all text candidates
            let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            
            // Use regex to find all numbers with decimals (e.g. 45.23 or 2.999)
            let regex = try? NSRegularExpression(pattern: "\\b\\d+[\\.,]\\d{2,3}\\b")
            let nsString = text as NSString
            let results = regex?.matches(in: text, range: NSRange(location: 0, length: nsString.length)) ?? []
            let numberStrings = results.map { nsString.substring(with: $0.range) }
            
            var numbers = numberStrings.compactMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
            numbers.sort(by: >) // Largest to smallest
            
            var total: Double?
            var volume: Double?
            var price: Double?
            
            // Heuristic 1: The absolute largest number is almost always the Total Cost
            if let maxNum = numbers.first, maxNum > 0 {
                total = maxNum
            }
            
            if isFuel, numbers.count >= 2 {
                let candidates = numbers.filter { $0 != total }
                
                // Heuristic 2: Find a Volume and Price where Volume * Price ≈ Total Cost
                var found = false
                for v in candidates {
                    for p in candidates {
                        if v == p { continue }
                        if abs((v * p) - (total ?? 0)) < 1.0 { // Margin of error for rounding
                            volume = max(v, p) // Volume is usually higher than Price per unit
                            price = min(v, p)
                            found = true
                            break
                        }
                    }
                    if found { break }
                }
                
                // Fallback Heuristics
                if !found {
                    volume = candidates.first { $0 > 4.0 && $0 < 100.0 }
                    price = candidates.first { $0 > 0.5 && $0 < 10.0 }
                }
            }
            
            DispatchQueue.main.async {
                completion(total, volume, price)
            }
        }
        
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        
        DispatchQueue.global(qos: .userInitiated).async {
            try? requestHandler.perform([request])
        }
    }
}
