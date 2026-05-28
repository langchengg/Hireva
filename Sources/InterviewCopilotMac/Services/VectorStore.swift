import Foundation

struct VectorScoredChunk {
    let chunk: DocumentChunk
    let similarity: Double
}

struct VectorStore {
    static func encodeEmbedding(_ embedding: [Float]) -> Data {
        var data = Data(capacity: embedding.count * 4)
        for val in embedding {
            var temp = val.bitPattern.littleEndian
            withUnsafeBytes(of: &temp) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        return data
    }

    static func decodeEmbedding(_ data: Data) -> [Float] {
        let count = data.count / 4
        if count == 0 { return [] }
        var embedding = [Float](repeating: 0.0, count: count)
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            for i in 0..<count {
                var pattern: UInt32 = 0
                withUnsafeMutableBytes(of: &pattern) { dest in
                    dest.copyBytes(from: UnsafeRawBufferPointer(start: baseAddress.advanced(by: i * 4), count: 4))
                }
                embedding[i] = Float(bitPattern: UInt32(littleEndian: pattern))
            }
        }
        return embedding
    }

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0.0 }
        
        var dotProduct: Double = 0.0
        var normA: Double = 0.0
        var normB: Double = 0.0
        
        for i in 0..<a.count {
            let valA = Double(a[i])
            let valB = Double(b[i])
            dotProduct += valA * valB
            normA += valA * valA
            normB += valB * valB
        }
        
        if normA == 0.0 || normB == 0.0 {
            return 0.0
        }
        
        return dotProduct / (sqrt(normA) * sqrt(normB))
    }

    static func rankByEmbedding(queryEmbedding: [Float], chunks: [DocumentChunk]) -> [VectorScoredChunk] {
        var scored: [VectorScoredChunk] = []
        
        for chunk in chunks {
            guard let embeddingData = chunk.embedding else { continue }
            let chunkEmbedding = decodeEmbedding(embeddingData)
            
            // Skip dimension mismatch chunks (handled by caller diagnostics/fallbacks)
            guard chunkEmbedding.count == queryEmbedding.count else { continue }
            
            let similarity = cosineSimilarity(queryEmbedding, chunkEmbedding)
            scored.append(VectorScoredChunk(chunk: chunk, similarity: similarity))
        }
        
        // Sort descending by similarity
        return scored.sorted { $0.similarity > $1.similarity }
    }
}
