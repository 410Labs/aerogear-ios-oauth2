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

public protocol URLLoading {
    func loadURL(url: URL)
}

/**
OAuth2WebViewController is a UIViewController to be used when the Oauth2 flow used an embedded view controller
rather than an external browser approach.
*/
open class OAuth2WebViewController: UIViewController, UIWebViewDelegate {
    /// Login URL for OAuth.
    var url: URL? {
        didSet {
            if isViewLoaded, webView.window != nil {
                loadAddressURL()
            }
        }
    }
    
    /// WebView instance used to load login page.
    let webView: UIWebView = UIWebView()
    
    init(url: URL) {
        super.init(nibName: nil, bundle: nil)
        self.url = url
    }
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        
        if let url = aDecoder.decodeObject(forKey: "url") as? URL {
            self.url = url
        }
    }
    
    open override func encode(with aCoder: NSCoder) {
        super.encode(with: aCoder)
        
        guard let url = url else {
            return
        }
        
        aCoder.encode(url, forKey: "url")
    }

    /// Override of viewDidLoad to load the login page.
    override open func viewDidLoad() {
        super.viewDidLoad()
        
        webView.frame = UIScreen.main.bounds
        webView.delegate = self
        self.view.addSubview(webView)
        
        loadAddressURL()
    }

    override open func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        self.webView.frame = self.view.bounds
    }

    func loadAddressURL() {
        guard let url = url else {
            return
        }
        
        let req = URLRequest(url: url)
        webView.loadRequest(req)
    }
}
