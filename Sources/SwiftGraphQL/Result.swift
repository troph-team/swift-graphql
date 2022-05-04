import Foundation

// MARK: - GraphQL Result

public struct GraphQLResult<Type, TypeLock> {
    public let data: Type
    public let response: GraphQLTransportResponse
    public let errors: [GraphQLError]?
}

extension GraphQLResult: Equatable where Type: Equatable, TypeLock: Decodable {}

extension GraphQLResult where TypeLock: Decodable {
    init(_ data: Data, associated response: GraphQLTransportResponse, with selection: Selection<Type, TypeLock?>) throws {
        // Decodes the data using provided selection.
        do {
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(GraphQLResponse.self, from: data)
            self.data = try selection.decode(data: decoded.data)
            self.response = response
            self.errors = decoded.errors
        } catch {
            // Catches all errors and turns them into a bad payload SwiftGraphQL error.
            throw GraphQLResponseError.badpayload(.init(reason: "cannot deserialize response: either JSON or GraphQL deserialization failed for message data \(String(describing: data)): \(error)"))
        }
    }

    init(webSocketMessage: GraphQLSocketMessage, with selection: Selection<Type, TypeLock?>) throws {
        // Decodes the data using provided selection.
        do {
            let response: GraphQLResponse = try webSocketMessage.decodePayload()
            self.data = try selection.decode(data: response.data)
            self.response = .websocket
            self.errors = response.errors
        } catch {
            // Catches all errors and turns them into a bad payload SwiftGraphQL error.
            throw GraphQLResponseError.badpayload(.init(reason: "cannot deserialize websocket message: either JSON or GraphQL deserialization failed for message \(String(describing: webSocketMessage)): \(error)"))
        }
    }

    // MARK: - Response

    struct GraphQLResponse: Decodable {
        let data: TypeLock?
        let errors: [GraphQLError]?
    }
}

// MARK: - GraphQL Error

public struct GraphQLError: Codable, Equatable {
    let message: String
    public let locations: [Location]?
//    public let path: [String]?

    public struct Location: Codable, Equatable {
        public let line: Int
        public let column: Int
    }
}
