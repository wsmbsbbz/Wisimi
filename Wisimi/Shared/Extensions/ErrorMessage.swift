import Foundation

extension Error {
    var userFacingMessage: String {
        guard let error = self as? URLError else { return localizedDescription }
        switch error.code {
        case .notConnectedToInternet: return "网络未连接，请检查网络后重试"
        case .timedOut: return "请求超时，请稍后重试"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "暂时无法连接服务器，请稍后重试"
        case .networkConnectionLost: return "网络连接中断，请重试"
        default: return localizedDescription
        }
    }
}
