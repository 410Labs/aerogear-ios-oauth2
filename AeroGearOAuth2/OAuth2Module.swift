/*
* JBoss, Home of Professional Open Source.
* Copyright Red Hat, Inc., and individual contributors
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/

import Foundation
import UIKit
import SafariServices

/**
Notification constants emitted during oauth authorization flow.
*/
public let AGAppLaunchedWithURLNotification = "AGAppLaunchedWithURLNotification"
public let AGAppDidBecomeActiveNotification = "AGAppDidBecomeActiveNotification"
public let AGAuthzErrorDomain = "AGAuthzErrorDomain"

public struct AGErrorCodes {
    public static let general = 0
    public static let unknown = 1
    public static let wrongStateParameter = 1
    public static let userCanceled = 100
}

public func isAGError(error: Error, withCode code: Int? = nil) -> Bool {
    let nserror = error as NSError
    guard nserror.domain == AGAuthzErrorDomain else {
        return false
    }
    
    guard let code = code else {
        return true
    }
    
    return nserror.code == code
}

/**
The current state that this module is in.

- AuthorizationStatePendingExternalApproval: the module is waiting external approval.
- AuthorizationStateApproved: the oauth flow has been approved.
- AuthorizationStateUnknown: the oauth flow is in unknown state (e.g. user clicked cancel).
*/
enum AuthorizationState {
    case authorizationStatePendingExternalApproval
    case authorizationStateApproved
    case authorizationStateUnknown
}

/**
Parent class of any OAuth2 module implementing generic OAuth2 authorization flow.
*/
open class OAuth2Module: AuthzModule {
    /**
     Gateway to request authorization access.

     :param: completionHandler A block object to be executed when the request operation finishes.
     */

    open let config: Config
    open var http: Http
    open var oauth2Session: OAuth2Session
    var applicationLaunchNotificationObserver: NSObjectProtocol?
    var applicationDidBecomeActiveNotificationObserver: NSObjectProtocol?
    var state: AuthorizationState
    open private(set) var webViewController: UIViewController?
    open private(set) var loadedURL: URL?
    open var serverCode: String?

    open var idToken: String? { return oauth2Session.idToken }

    open var requestIdentifier: String = ProcessInfo.processInfo.globallyUniqueString

    /*
     Delegate UI events to module user
     */
    open private(set) var beganHandlingUI: Bool = false
    
    /*
     Block run at the beginning of handling UI. Allows to prepare application to state where authorization UI can be presented. Second argument with `true` has to be run to proceed.
     */
    open var beginHandlingUICallback: ((OAuth2Module, @escaping (Bool) -> Void) -> Void) = { module, done in
        if let presentedViewController = UIApplication.shared.keyWindow?.rootViewController?.presentedViewController {
            presentedViewController.dismiss(animated: true, completion: {
                done(true)
            })
        } else {
            done(true)
        }
    }
    
    /*
     Block for actually handling the UI for authorization. Provides UIViewController (Internal WebView, Safari, Custom) to be presented on the UI.
     */
    open var handleUICallback: ((OAuth2Module, UIViewController) -> Void) = { module, viewController in
        UIApplication.shared.keyWindow?.rootViewController?.present(viewController, animated: true, completion: nil)
    }
    
    /*
     Block for handling cleanup after authorization was being handled. Executed only if beginHandlingUICallback callback was `true.
     */
    open var finishHandlingUICallback: ((OAuth2Module, UIViewController, @escaping () -> Void) -> Void) = { module, UIViewController, callback in
        UIApplication.shared.keyWindow?.rootViewController?.dismiss(animated: true, completion: callback)
    }
    

    /**
    Initialize an OAuth2 module.

    :param: config the configuration object that setups the module.
    :param: session the session that that module will be bound to.
    :param: requestSerializer the actual request serializer to use when performing requests.
    :param: responseSerializer the actual response serializer to use upon receiving a response.

    :returns: the newly initialized OAuth2Module.
    */
    public required init(config: Config, session: OAuth2Session? = nil, requestSerializer: RequestSerializer = HttpRequestSerializer(), responseSerializer: ResponseSerializer = JsonResponseSerializer()) {
        if (config.accountId == nil) {
            config.accountId = "ACCOUNT_FOR_CLIENTID_\(config.clientId)"
        }
        if (session == nil) {
            self.oauth2Session = TrustedPersistentOAuth2Session(accountId: config.accountId!)
        } else {
            self.oauth2Session = session!
        }

        self.config = config
        self.http = Http(baseURL: config.baseURL, requestSerializer: requestSerializer, responseSerializer:  responseSerializer)
        self.state = .authorizationStateUnknown
    }

    // MARK: Public API - To be overridden if necessary by OAuth2 specific adapter

    /**
    Request an authorization code.

    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    open func requestAuthorizationCode(completionHandler: @escaping (AnyObject?, NSError?) -> Void) {
        // register with the notification system in order to be notified when the 'authorization' process completes in the
        // external browser, and the oauth code is available so that we can then proceed to request the 'access_token'
        // from the server.
        applicationLaunchNotificationObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: AGAppLaunchedWithURLNotification), object: nil, queue: nil, using: { (notification: Notification!) -> Void in
            self.extractCode(notification, completionHandler: { object, error in
                
                
                if self.beganHandlingUI, let webViewController = self.webViewController {
                    self.beganHandlingUI = false
                    
                    self.finishHandlingUICallback(self, webViewController, {
                        completionHandler(object, error)
                        self.webViewController = nil
                    })
                    
                } else {
                    completionHandler(object, error)
                }
            })
        })

        // register to receive notification when the application becomes active so we
        // can clear any pending authorization requests which are not completed properly,
        // that is a user switched into the app without Accepting or Cancelling the authorization
        // request in the external browser process.
        applicationDidBecomeActiveNotificationObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name(rawValue: AGAppDidBecomeActiveNotification), object:nil, queue:nil, using: { (note: Notification!) -> Void in
            // check the state
            if (self.state == .authorizationStatePendingExternalApproval) {
                // unregister
                self.stopObserving()
                // ..and update state
                self.state = .authorizationStateUnknown
            }
        })

        // update state to 'Pending'
        self.state = .authorizationStatePendingExternalApproval

        guard let computedUrl = http.calculateURL(baseURL: config.baseURL, url: config.authzEndpoint),
            let components = NSURLComponents(url: computedUrl, resolvingAgainstBaseURL: false) else {
                let error = NSError(domain:AGAuthzErrorDomain, code:AGErrorCodes.general, userInfo:["NSLocalizedDescriptionKey": "Malformatted URL."])
                completionHandler(nil, error)
                return
        }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "scope", value: config.scope),
            URLQueryItem(name: "redirect_uri", value: config.redirectURL),
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: requestIdentifier)
        ]

        if let audienceId = config.audienceId {
            queryItems.append(URLQueryItem(name: "audience", value: audienceId))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            let error = NSError(domain:AGAuthzErrorDomain, code:AGErrorCodes.general, userInfo:["NSLocalizedDescriptionKey": "Malformed parameters."])
            completionHandler(nil, error)
            return
        }

        loadURL(url: url, completionHandler: completionHandler)
    }
    
    /*
     Loads URL when needed by `requestAuthorizationCode`
     
     :param: url A URL to load, computed by `requestAuthorizationCode`
     :param: completionHandler Completion handler forwarded from `requestAuthorizationCode`
     */
    
    open func loadURL(url: URL, completionHandler completion: @escaping (AnyObject?, NSError?) -> Void) {
        let canceledError = NSError(domain:AGAuthzErrorDomain, code:AGErrorCodes.userCanceled, userInfo:["NSLocalizedDescriptionKey": "Action canceled"])
        
        switch config.webView {
        case .embeddedWebView:
            beginHandlingUICallback(self) { success in
                if success {
                    let webController = OAuth2WebViewController(url: url)
                    self.handleUICallback(self, webController)
                    self.webViewController = webController
                } else {
                    completion(nil, canceledError)
                    self.beganHandlingUI = false
                    self.webViewController = nil
                }
            }
            beganHandlingUI = true
            
        case .externalSafari:
            UIApplication.shared.openURL(url)
            
        case .custom(let urlLoading):
            beginHandlingUICallback(self) { success in
                if success {
                    let viewController = urlLoading(url)
                    self.handleUICallback(self, viewController)
                    self.webViewController = viewController
                } else {
                    completion(nil, canceledError)
                    self.beganHandlingUI = false
                    self.webViewController = nil
                }
            }
            beganHandlingUI = true
            
        case .safariViewController:
            if #available(iOS 9.0, *) {
                beginHandlingUICallback(self) { success in
                    if success {
                        let safariController = SFSafariViewController(url: url)
                        self.handleUICallback(self, safariController)
                        self.webViewController = safariController
                    } else {
                        completion(nil, canceledError)
                        self.beganHandlingUI = false
                        self.webViewController = nil
                    }
                }
                beganHandlingUI = true
            }
        }
        
        loadedURL = url
    }

    /**
    Request to refresh an access token.

    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    open func refreshAccessToken(completionHandler: @escaping (AnyObject?, NSError?) -> Void) {
        if let unwrappedRefreshToken = self.oauth2Session.refreshToken {
            var paramDict: [String: String] = ["refresh_token": unwrappedRefreshToken, "client_id": config.clientId, "grant_type": "refresh_token"]
            if (config.clientSecret != nil) {
                paramDict["client_secret"] = config.clientSecret!
            }

            http.request(method: .post, path: config.refreshTokenEndpoint!, parameters: paramDict as [String : AnyObject]?, completionHandler: { (response, error) in
                if (error != nil) {
                    completionHandler(nil, error)
                    return
                }

                if let unwrappedResponse = response as? [String: AnyObject] {
                    let accessToken: String = unwrappedResponse["access_token"] as! String
                    let expiration = unwrappedResponse["expires_in"] as! NSNumber
                    let exp: String = expiration.stringValue
                    let idToken: String? = unwrappedResponse["id_token"] as? String
                    var refreshToken = unwrappedRefreshToken
                    if let newRefreshToken = unwrappedResponse["refresh_token"] as? String {
                        refreshToken = newRefreshToken
                    }

                    self.oauth2Session.save(accessToken: accessToken, refreshToken: refreshToken, accessTokenExpiration: exp, refreshTokenExpiration: nil, idToken: idToken)

                    completionHandler(unwrappedResponse["access_token"], nil)
                }
            })
        }
    }

    /**
    Exchange an authorization code for an access token.

    :param: code the 'authorization' code to exchange for an access token.
    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    open func exchangeAuthorizationCodeForAccessToken(code: String, completionHandler: @escaping (AnyObject?, NSError?) -> Void) {
        var paramDict: [String: String] = ["code": code, "client_id": config.clientId, "redirect_uri": config.redirectURL, "grant_type":"authorization_code"]

        if let unwrapped = config.clientSecret {
            paramDict["client_secret"] = unwrapped
        }

        if let audience = config.audienceId {
            paramDict["audience"] = audience
        }

        http.request(method: .post, path: config.accessTokenEndpoint, parameters: paramDict as [String : AnyObject]?, completionHandler: {(responseObject, error) in
            if (error != nil) {
                completionHandler(nil, error)
                return
            }

            if let unwrappedResponse = responseObject as? [String: AnyObject] {
                let accessToken = self.tokenResponse(unwrappedResponse)
                completionHandler(accessToken as AnyObject?, nil)
            }
        })
    }

    open func tokenResponse(_ unwrappedResponse: [String: AnyObject]) -> String {
        let accessToken: String   = unwrappedResponse["access_token"] as! String
        let refreshToken: String? = unwrappedResponse["refresh_token"] as? String
        let idToken: String?      = unwrappedResponse["id_token"] as? String
        let serverCode: String?   = unwrappedResponse["server_code"] as? String
        let expiration            = unwrappedResponse["expires_in"] as? NSNumber
        let exp: String?          = expiration?.stringValue
        // expiration for refresh token is used in Keycloak
        let expirationRefresh     = unwrappedResponse["refresh_expires_in"] as? NSNumber
        let expRefresh            = expirationRefresh?.stringValue

        self.oauth2Session.save(accessToken: accessToken, refreshToken: refreshToken, accessTokenExpiration: exp, refreshTokenExpiration: expRefresh, idToken: idToken)
        self.serverCode = serverCode

        return accessToken
    }

    /**
    Gateway to request authorization access.

    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    open func requestAccess(completionHandler: @escaping (AnyObject?, NSError?) -> Void) {
        if (self.oauth2Session.accessToken != nil && self.oauth2Session.tokenIsNotExpired()) {
            // we already have a valid access token, nothing more to be done
            completionHandler(self.oauth2Session.accessToken! as AnyObject?, nil)
        } else if (self.oauth2Session.refreshToken != nil && self.oauth2Session.refreshTokenIsNotExpired()) {
            // need to refresh token
            self.refreshAccessToken(completionHandler: completionHandler)
        } else {
            // ask for authorization code and once obtained exchange code for access token
            self.requestAuthorizationCode(completionHandler: completionHandler)
        }
    }

    /**
    Gateway to provide authentication using the Authorization Code Flow with OpenID Connect.

    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    open func login(completionHandler: @escaping (AnyObject?, OpenIdClaim?, NSError?) -> Void) {

        self.requestAccess { (response: AnyObject?, error: NSError?) -> Void in

            if (error != nil) {
                completionHandler(nil, nil, error)
                return
            }
            var paramDict: [String: String] = [:]
            if response != nil {
                paramDict = ["access_token": response! as! String]
            }
            if let userInfoEndpoint = self.config.userInfoEndpoint {

                self.http.request(method: .get, path:userInfoEndpoint, parameters: paramDict as [String : AnyObject]?, completionHandler: {(responseObject, error) in
                    if (error != nil) {
                        completionHandler(nil, nil, error)
                        return
                    }
                    var openIDClaims: OpenIdClaim?
                    if let unwrappedResponse = responseObject as? [String: AnyObject] {
                        openIDClaims = self.makeOpenIdClaim(fromDict: unwrappedResponse)
                    }
                    completionHandler(response, openIDClaims, nil)
                })
            } else {
                completionHandler(nil, nil, NSError(domain: "OAuth2Module", code: 0, userInfo: ["OpenID Connect" : "No UserInfo endpoint available in config"]))
                return
            }

        }

    }

    open func makeOpenIdClaim(fromDict: [String: AnyObject]) -> OpenIdClaim {
        return OpenIdClaim(fromDict: fromDict)
    }

    /**
    Request to revoke access.

    :param: completionHandler A block object to be executed when the request operation finishes.
    */
    open func revokeAccess(completionHandler: @escaping (AnyObject?, NSError?) -> Void) {
        // return if not yet initialized
        if (self.oauth2Session.accessToken == nil) {
            return
        }
        // return if no revoke endpoint
        guard let revokeTokenEndpoint = config.revokeTokenEndpoint else {
            return
        }

        let paramDict: [String:String] = ["token":self.oauth2Session.accessToken!]

        http.request(method: .post, path: revokeTokenEndpoint, parameters: paramDict as [String : AnyObject]?, completionHandler: { (response, error) in
            if (error != nil) {
                completionHandler(nil, error)
                return
            }

            self.oauth2Session.clearTokens()
            completionHandler(response as AnyObject?, nil)
        })
    }

    /**
    Return any authorization fields.

    :returns:  a dictionary filled with the authorization fields.
    */
    open func authorizationFields() -> [String: String]? {
        if (self.oauth2Session.accessToken == nil) {
            return nil
        } else {
            return ["Authorization":"Bearer \(self.oauth2Session.accessToken!)"]
        }
    }

    /**
    Returns a boolean indicating whether authorization has been granted.

    :returns: true if authorized, false otherwise.
    */
    open func isAuthorized() -> Bool {
        return self.oauth2Session.accessToken != nil && self.oauth2Session.tokenIsNotExpired()
    }

    // MARK: Internal Methods

    func extractCode(_ notification: Notification, completionHandler: @escaping (AnyObject?, NSError?) -> Void) {
        let info = notification.userInfo!
        let url: URL? = info[UIApplicationLaunchOptionsKey.url] as? URL

        // extract the code from the URL
        let queryParamsDict = self.parametersFrom(queryString: url?.query)

        // if exists perform the exchange
        if let code = queryParamsDict["code"] {
            if queryParamsDict["state"] == requestIdentifier {
                self.exchangeAuthorizationCodeForAccessToken(code: code, completionHandler: completionHandler)
                // update state
                state = .authorizationStateApproved
            } else {
                let error = NSError(domain: AGAuthzErrorDomain, code: AGErrorCodes.wrongStateParameter, userInfo: [:])
                completionHandler(nil, error)
            }
        } else {
            guard let errorName = queryParamsDict["error"] else {
                let error = NSError(domain:AGAuthzErrorDomain, code: AGErrorCodes.general, userInfo:["NSLocalizedDescriptionKey": "User cancelled authorization."])
                completionHandler(nil, error)
                return
            }

            let errorDescription = queryParamsDict["error_description"] ?? "There was an error!"
            let error = NSError(domain: AGAuthzErrorDomain, code: AGErrorCodes.unknown, userInfo: ["error": errorName, "errorDescription": errorDescription])

            completionHandler(nil, error)
        }

        // finally, unregister
        self.stopObserving()
    }

    func parametersFrom(queryString: String?) -> [String: String] {
        var parameters = [String: String]()
        if (queryString != nil) {
            let parameterScanner: Scanner = Scanner(string: queryString!)
            var name: NSString? = nil
            var value: NSString? = nil

            while (parameterScanner.isAtEnd != true) {
                name = nil
                parameterScanner.scanUpTo("=", into: &name)
                parameterScanner.scanString("=", into:nil)

                value = nil
                parameterScanner.scanUpTo("&", into:&value)
                parameterScanner.scanString("&", into:nil)

                if (name != nil && value != nil) {
                    parameters[name!.removingPercentEncoding!] = value!.removingPercentEncoding
                }
            }
        }

        return parameters
    }

    deinit {
        self.stopObserving()
    }

    func stopObserving() {
        // clear all observers
        if (applicationLaunchNotificationObserver != nil) {
            NotificationCenter.default.removeObserver(applicationLaunchNotificationObserver!)
            self.applicationLaunchNotificationObserver = nil
        }

        if (applicationDidBecomeActiveNotificationObserver != nil) {
            NotificationCenter.default.removeObserver(applicationDidBecomeActiveNotificationObserver!)
            applicationDidBecomeActiveNotificationObserver = nil
        }
    }
}
