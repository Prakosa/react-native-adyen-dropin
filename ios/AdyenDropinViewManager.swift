import Adyen
import PassKit

internal struct PaymentResponse: Decodable {
    
    internal let resultCode: ResultCode
    
    internal let action: Action?
    
    internal init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.resultCode = try container.decode(ResultCode.self, forKey: .resultCode)
        self.action = try container.decodeIfPresent(Action.self, forKey: .action)
    }
    
    private enum CodingKeys: String, CodingKey {
        case resultCode
        case action
    }
    
}

internal extension PaymentResponse {
    enum ResultCode: String, Decodable {
        case authorised = "Authorised"
        case refused = "Refused"
        case pending = "Pending"
        case cancelled = "Cancelled"
        case error = "Error"
        case received = "Received"
        case redirectShopper = "RedirectShopper"
        case identifyShopper = "IdentifyShopper"
        case challengeShopper = "ChallengeShopper"
        case presentToShopper = "PresentToShopper"
    }
}

@objc(AdyenDropInViewManager)
class AdyenDropInViewManager: RCTViewManager, RCTInvalidating {
    
  private var viewInstance: AdyenDropInView?
  
  func invalidate() {
    print("Invalidating drop-in...")
    print(self.viewInstance != nil)
    if (self.viewInstance != nil) {
      DispatchQueue.main.async {
        self.viewInstance?.invalidate()
      }
    }
  }
  
  override func view() -> (AdyenDropInView) {
    AdyenLogging.isEnabled = true
    self.viewInstance = AdyenDropInView()
    return self.viewInstance!
  }
  
  override class func requiresMainQueueSetup() -> Bool {
    return true
  }
}

@objc(AdyenDropInView)
class AdyenDropInView: UIView {
  static func decodeResponse(_ response: NSDictionary) throws -> PaymentResponse {
    let JSON = try JSONSerialization.data(withJSONObject: response)
    let decoded = try Coder.decode(JSON) as PaymentResponse
    return decoded
  }
  
  private var _dropInComponent: DropInComponent?

  private var _paymentMethods: PaymentMethods?
  
  private var _paymentMethodsConfiguration: DropInComponent.PaymentMethodsConfiguration?
  
  private var _invalidating: Bool = false
  
  @objc var visible: Bool = false {
    didSet {
      if (visible) {
        self.open()
      } else {
        self.close()
      }
    }
  }
  
  @objc var paymentMethods: NSDictionary? {
    didSet {
      do {
        guard paymentMethods != nil else {
          return
        }

        let JSON = try JSONSerialization.data(withJSONObject: paymentMethods!)
        self._paymentMethods = try Coder.decode(JSON) as PaymentMethods
        self.initDropInIfNeeded()
      } catch let err {
        self.onError?(["message": "Failed to decode payment methods (\(err.localizedDescription)"])
        print(err)
      }
    }
  }
  
  @objc var paymentMethodsConfiguration: NSDictionary? {
    didSet {
      guard paymentMethodsConfiguration != nil else {
        return
      }
      
      if let clientKey = paymentMethodsConfiguration?.value(forKey: "clientKey") as? String {
        let parser = ConfigurationParser(clientKey)
        self._paymentMethodsConfiguration = parser.parse(paymentMethodsConfiguration!)
        self.initDropInIfNeeded()
      }
    }
  }
  
  @objc var paymentResponse: NSDictionary? {
    didSet {
      guard paymentResponse != nil else {
        return
      }
      
      do {
        let response = try AdyenDropInView.decodeResponse(paymentResponse!)
        self.handle(response)
      } catch let err {
        self.onError?(["message": "Failed to decode payment response (\(err.localizedDescription)"])
      }
    }
  }
  
  @objc var detailsResponse: NSDictionary? {
    didSet {
      guard detailsResponse != nil else {
        return
      }
      
      do {
        let response = try AdyenDropInView.decodeResponse(detailsResponse!)
        self.handle(response)
      } catch let err {
        self.onError?(["message": "Failed to decode details response (\(err.localizedDescription)"])
      }
    }
  }
  
  // Events
  @objc var onSubmit: RCTDirectEventBlock?
  @objc var onAdditionalDetails: RCTDirectEventBlock?
  @objc var onError: RCTDirectEventBlock?
  @objc var onSuccess: RCTDirectEventBlock?
  @objc var onClose: RCTDirectEventBlock?
  
  func isDropInVisible() -> Bool {
    return self.reactViewController()?.presentedViewController != nil && self.reactViewController()?.presentedViewController == self._dropInComponent?.viewController
  }
  
  func invalidate() {
    self._invalidating = true
    
    if (self._dropInComponent?.viewController != nil) {
      print("Drop-in was visible on invalidation - closing")
      self._dropInComponent!.viewController.dismiss(animated: true) {
        self._dropInComponent = nil
        self._paymentMethods = nil
        self._paymentMethodsConfiguration = nil
      }
    } else {
      print("Drop-in was not visible on invalidation")
      self._dropInComponent = nil
      self._paymentMethods = nil
      self._paymentMethodsConfiguration = nil
    }
    
    self.reactViewController()?.dismiss(animated: false, completion: nil)
  }
  
  func initDropInIfNeeded() {
    guard self._dropInComponent == nil else {
      print("Skipping initialization")
      return
    }
    
    if (self._paymentMethods != nil && self._paymentMethodsConfiguration != nil) {
      print("Initializing drop-in")
      self._dropInComponent = DropInComponent(paymentMethods: _paymentMethods!, paymentMethodsConfiguration: _paymentMethodsConfiguration!)
      self._dropInComponent?.delegate = self
      if let environment = paymentMethodsConfiguration?.value(forKey: "environment") as? String {
        self._dropInComponent?.environment = ConfigurationParser.getEnvironment(environment)
      }
    } else {
      print("Skipped init because either paymentMethods or paymentMethodsConfiguration was not set")
    }
  }
  
  func open() {
    print("Open was called")
    
    guard !self._invalidating else {
      print("Skipping open because invalidating")
      return
    }
    
    guard !(self.isDropInVisible()) else {
      print("Skipping open because viewController is already presenting")
      return
    }
    
    self.initDropInIfNeeded()

    if (self._dropInComponent != nil) {
      self.reactViewController()?.present(self._dropInComponent!.viewController, animated: true, completion: nil)
    }
  }
  
  func close() {
    print("Close was called")
    
    guard !self._invalidating else {
      print("Skipping close because invalidating")
      return
    }
    
    guard (self.isDropInVisible()) else {
      print("Skipping close because viewController is not being presented")
      return
    }
    
    self._dropInComponent!.viewController.dismiss(animated: true) {
      self._dropInComponent = nil
      self.onClose?([:])
    }
  }
  
  func handle(_ result: PaymentResponse) {
    let paymentResultCode = PaymentResultCode.init(rawValue: result.resultCode.rawValue.lowercased())
    
    switch result.resultCode {
    case .authorised, .pending, .received, .challengeShopper, .identifyShopper, .presentToShopper, .redirectShopper:
      if let action = result.action {
          handle(action)
      } else {
        finish(with: paymentResultCode)
      }
    
    case .cancelled, .error, .refused:
      finish(with: paymentResultCode)
    }
  }
  
  func handle(_ action: Action) {
    _dropInComponent?.handle(action)
  }
  
  internal func finish(with resultCode: PaymentResultCode?) {
    let success = resultCode == .authorised || resultCode == .received || resultCode == .pending
    if (success) {
      self.close()
      self.onSuccess?(["resultCode": resultCode?.rawValue ?? ""])
    }
  }
  
  internal func finish(with error: Error) {
    let isCancelled = (error as? ComponentError) == .cancelled
    if (!isCancelled) {
      self.onError?(["error": error.localizedDescription])
    }
  }
}

extension AdyenDropInView: DropInComponentDelegate {
  func didSubmit(_ data: PaymentComponentData, for paymentMethod: PaymentMethod, from component: DropInComponent) {
    self.onSubmit?([
      "paymentMethod": data.paymentMethod.encodable.dictionary as Any,
      "storePaymentMethod": data.storePaymentMethod,
      "browserInfo": data.browserInfo as Any,
      "channel": "iOS"
    ])
  }
  
  func didProvide(_ data: ActionComponentData, from component: DropInComponent) {
    print("didProvide")
    self.onAdditionalDetails?([
      "details": data.details.dictionary as Any,
      "paymentData": (data.paymentData ?? "") as String
    ])
  }
  
  func didComplete(from component: DropInComponent) {
    print("didComplete")
    self.finish(with: .authorised)
  }
  
  func didFail(with error: Error, from component: DropInComponent) {
    print("didFail")
    let isCancelled = (error as? ComponentError) == .cancelled
    if (!isCancelled) {
      self.onError?(["error": error.localizedDescription])
    }
    self.close()
  }
  
  func didCancel(component: PaymentComponent, from dropInComponent: DropInComponent) {
    print("didCancel")
  }
}

extension Encodable {
  var dictionary: [String: Any]? {
    guard let data = try? JSONEncoder().encode(self) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data, options: .allowFragments)).flatMap { $0 as? [String: Any] }
  }
}
