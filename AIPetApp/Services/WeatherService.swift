import Foundation
import CoreLocation
import WeatherKit

/// 一个简单的天气服务，用于基于用户当前位置获取当前天气描述，
/// 例如："正在下雨，22°C"、"晴朗，28°C" 等。
///
/// - 使用 `CLLocationManager` 获取一次性定位（When In Use）。
/// - 使用 `WeatherService`（来自 WeatherKit，而非本项目的服务协议）获取当前天气。
/// - 对外暴露 `fetchCurrentWeatherDescription()` 供上层（如 SystemPromptBuilder / LLMService）使用。
@MainActor
final class AppWeatherService: NSObject {

    static let shared = AppWeatherService()

    private let locationManager = CLLocationManager()
    private let weatherService = WeatherKit.WeatherService.shared

    private var locationContinuation: CheckedContinuation<CLLocation, Error>?

    private override init() {
        super.init()
        locationManager.delegate = self
    }

    /// 获取当前天气的简要描述，用于注入到系统提示词中。
    /// - 返回示例："正在下雨，22°C"、"多云，18°C"、"晴朗，30°C"。
    func fetchCurrentWeatherDescription() async throws -> String {
        let location = try await requestLocationOnce()
        let weather = try await weatherService.weather(for: location)

        let conditionText: String
        switch weather.currentWeather.condition {
        case .clear, .hot:
            conditionText = "晴朗"
        case .mostlyClear, .partlyCloudy:
            conditionText = "多云"
        case .cloudy:
            conditionText = "阴天"
        case .rain, .heavyRain, .drizzle, .isolatedThunderstorms, .scatteredThunderstorms, .strongStorms, .thunderstorms:
            conditionText = "正在下雨"
        case .snow, .heavySnow, .flurries, .sleet, .blizzard:
            conditionText = "下雪"
        case .haze:
            conditionText = "有雾"
        case .windy, .breezy:
            conditionText = "有风"
        default:
            conditionText = "天气多变"
        }

        let temp = Int(round(weather.currentWeather.temperature.converted(to: .celsius).value))
        return "\(conditionText)，\(temp)°C"
    }

    // MARK: - Location

    private func requestLocationOnce() async throws -> CLLocation {
        // 检查授权状态，如果尚未授权则请求 When In Use 权限。
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }

        switch locationManager.authorizationStatus {
        case .restricted, .denied:
            throw WeatherServiceError.locationDenied
        case .authorizedAlways, .authorizedWhenInUse, .authorized:
            break
        case .notDetermined:
            // 授权结果会在 delegate 回调中体现，这里继续走一次位置请求。
            break
        @unknown default:
            break
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.locationContinuation = continuation
            self.locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            self.locationManager.requestLocation()
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension AppWeatherService: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let continuation = locationContinuation else { return }
        locationContinuation = nil
        if let location = locations.first {
            continuation.resume(returning: location)
        } else {
            continuation.resume(throwing: WeatherServiceError.noLocation)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard let continuation = locationContinuation else { return }
        locationContinuation = nil
        continuation.resume(throwing: error)
    }
}

// MARK: - Error

enum WeatherServiceError: Error {
    case locationDenied
    case noLocation
}
