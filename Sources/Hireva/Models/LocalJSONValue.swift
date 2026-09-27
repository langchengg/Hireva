import Foundation

/// Encodes an actual JSON schema object for Ollama's `format` parameter.
/// Existing string-format requests retain their original wire representation.
indirect enum LocalJSONValue: Codable, Equatable {
    case object([String: LocalJSONValue]), array([LocalJSONValue]), string(String), boolean(Bool), number(Double), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let object = try? value.decode([String: LocalJSONValue].self) { self = .object(object) }
        else if let array = try? value.decode([LocalJSONValue].self) { self = .array(array) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let boolean = try? value.decode(Bool.self) { self = .boolean(boolean) }
        else { self = .number(try value.decode(Double.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let object): try value.encode(object)
        case .array(let array): try value.encode(array)
        case .string(let string): try value.encode(string)
        case .boolean(let boolean): try value.encode(boolean)
        case .number(let number): try value.encode(number)
        case .null: try value.encodeNil()
        }
    }
}
