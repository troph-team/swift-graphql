//import Combine
import Foundation

/*
 SwiftGraphQL has no client as it needs no state. Developers
 should take care of caching and other implementation themselves.
 */

// MARK: - Send

/// Sends a query request to the server.
///
/// - parameter endpoint: Server endpoint URL.
/// - parameter operationName: The name of the GraphQL query.
/// - parameter headers: A dictionary of key-value header pairs.
/// - parameter onEvent: Closure that is called each subscription event.
/// - parameter method: Method to use. (Default to POST).
/// - parameter session: URLSession to use. (Default to .shared).
///
@discardableResult
public func send<Type, TypeLock>(
    _ selection: Selection<Type, TypeLock?>,
    to endpoint: String,
    operationName: String? = nil,
    headers: HttpHeaders = [:],
    method: HttpMethod = .post,
    session: URLSession = .shared,
    onComplete completionHandler: @escaping (Response<Type, TypeLock>) -> Void
) -> URLSessionDataTask? where TypeLock: GraphQLHttpOperation & Decodable {
    send(
        selection: selection,
        operationName: operationName,
        endpoint: endpoint,
        headers: headers,
        method: method,
        session: session,
        completionHandler: completionHandler
    )
}

/// Sends a query request to the server.
///
/// - Note: This is a shortcut function for when you are expecting the result.
///         The only difference between this one and the other one is that you may select
///         on non-nullable TypeLock instead of a nullable one.
///
/// - parameter endpoint: Server endpoint URL.
/// - parameter operationName: The name of the GraphQL query.
/// - parameter headers: A dictionary of key-value header pairs.
/// - parameter onEvent: Closure that is called each subscription event.
/// - parameter method: Method to use. (Default to POST).
/// - parameter session: URLSession to use. (Default to .shared).
///
@discardableResult
public func send<Type, TypeLock>(
    _ selection: Selection<Type, TypeLock>,
    to endpoint: String,
    operationName: String? = nil,
    headers: HttpHeaders = [:],
    method: HttpMethod = .post,
    session: URLSession = .shared,
    onComplete completionHandler: @escaping (Response<Type, TypeLock>) -> Void
) -> URLSessionDataTask? where TypeLock: GraphQLHttpOperation & Decodable {
    send(
        selection: selection.nonNullOrFail,
        operationName: operationName,
        endpoint: endpoint,
        headers: headers,
        method: method,
        session: session,
        completionHandler: completionHandler
    )
}


/// Sends a query to the server using given parameters.
private func send<Type, TypeLock>(
    selection: Selection<Type, TypeLock?>,
    operationName: String?,
    endpoint: String,
    headers: HttpHeaders,
    method: HttpMethod,
    session: URLSession,
    completionHandler: @escaping (Response<Type, TypeLock>) -> Void
) -> URLSessionDataTask? where TypeLock: GraphQLOperation & Decodable {
    // Validate that we got a valid url.
    guard let url = URL(string: endpoint) else {
        completionHandler(.failure(.badURL))
        return nil
    }
    
    // Construct a GraphQL request.
    let request = createGraphQLRequest(
        selection: selection,
        operationName: operationName,
        url: url,
        headers: headers,
        method: method
    )
    
    // Create a completion handler.
    func onComplete(data: Data?, response: URLResponse?, error: Error?) {
        /* Process the response. */
        // Check for HTTP errors.
        if let error = error {
            return completionHandler(.failure(.network(error)))
        }
        
        guard let response = response else {
            return completionHandler(.failure(.badpayload(GraphQLPayloadError(reason: "response is nil", response: response))))
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            return completionHandler(.failure(.badpayload(GraphQLPayloadError(reason: "response empty or malformed: cannot cast response to HTTPURLResponse?. Is the response nil?", response: response))))
        }
        
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            return completionHandler(.failure(.badstatus(GraphQLTransportError(reason: "response status code is not in succeed range: expect 200-299, got \(httpResponse.statusCode)", response: response))))
        }

        // Try to serialize the response.
        do {
            if let data = data {
                let result = try GraphQLResult(data, associated: .absent, with: selection)
                return completionHandler(.success(result))
            } else {
                return completionHandler(.failure(.badpayload(GraphQLPayloadError(reason: "response data is empty (\(String(describing: data)))", response: response))))
            }
        } catch {
            return completionHandler(.failure(.badpayload(GraphQLPayloadError(reason: "response deserialization failed: \(String(describing: error))", response: response))))
        }
    }

    // Construct a session data task.
    let dataTask = session.dataTask(with: request, completionHandler: onComplete)
    
    dataTask.resume()
    return dataTask
    
}

// MARK: - Request type aliaii

/// Represents an error of the actual request.
public enum GraphQLResponseError: Error {
    case badURL
    case timeout
    case network(Error)
    case badpayload(GraphQLPayloadError)
    case badstatus(GraphQLTransportError)
    case cancelled
}

public struct GraphQLPayloadError: Error {
    var reason: String
    var response: URLResponse? = nil
    
    public init(reason: String, response: URLResponse? = nil) {
        self.reason = reason
        self.response = response
    }
    
    static let nonNullFailed: GraphQLPayloadError = GraphQLPayloadError(reason: "non-null assumption failed: selection is actually null; failing because of nonNullOrFail")
}

public struct GraphQLTransportError: Error {
    var reason: String
    var response: URLResponse? = nil
    
    public init(reason: String, response: URLResponse? = nil) {
        self.reason = reason
        self.response = response
    }
}

extension GraphQLResponseError: Equatable {
    public static func == (lhs: SwiftGraphQL.GraphQLResponseError, rhs: SwiftGraphQL.GraphQLResponseError) -> Bool {
        // Equals if they are of the same type, different otherwise.
        switch (lhs, rhs) {
        case (.badURL, badURL),
             (.timeout, .timeout),
             (.badpayload, .badpayload),
             (.badstatus, .badstatus):
            return true
        default:
            return false
        }
    }
}

public enum HttpMethod: String, Equatable {
    case get = "GET"
    case post = "POST"
}

public enum GraphQLTransportResponse: Equatable {
    case http(HTTPURLResponse?)
    // accessing websocket transport response is not yet implemented
    case websocket
    // when running unit test there's no associated response with that result, so we use this dummy value to ensure they are equatable
    case absent
}

/// A return value that might contain a return value as described in GraphQL spec.
public typealias Response<Type, TypeLock> = Result<GraphQLResult<Type, TypeLock>, GraphQLResponseError>

/// A dictionary of key-value pairs that represent headers and their values.
public typealias HttpHeaders = [String: String]

// MARK: - Utility functions

/*
 Each of the exposed functions has a backing private helper.
 We use `perform` method to send queries and mutations,
 `listen` to listen for subscriptions, and there's an overarching utility
 `request` method that composes a request and send it.
 */

/// Creates a valid URLRequest using given selection.
private func createGraphQLRequest<Type, TypeLock>(
    selection: Selection<Type, TypeLock?>,
    operationName: String?,
    url: URL,
    headers: HttpHeaders,
    method: HttpMethod
) -> URLRequest where TypeLock: GraphQLOperation & Decodable {
    // Construct a request.
    var request = URLRequest(url: url)

    for header in headers {
        request.setValue(header.value, forHTTPHeaderField: header.key)
    }

    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpMethod = method.rawValue

    // Construct HTTP body.
    let encoder = JSONEncoder()
    let payload = selection.buildPayload(operationName: operationName)
    request.httpBody = try! encoder.encode(payload)

    return request
}

