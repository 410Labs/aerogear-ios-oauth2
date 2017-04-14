//
//  ErrorsTest.swift
//  AeroGearOAuth2
//
//  Created by Jarosław Pendowski on 14/04/2017.
//  Copyright © 2017 aerogear. All rights reserved.
//

import XCTest
@testable import AeroGearOAuth2

class ErrorsTest: XCTestCase {
    
    func testIsAGValidErrorTest() {
        let error = NSError(domain: AGAuthzErrorDomain, code: 9999, userInfo: nil)
        XCTAssertTrue(isAGError(error: error))
        
        let randomError = NSError(domain: "Random", code: 9999, userInfo: nil)
        XCTAssertFalse(isAGError(error: randomError))
    }
    
    func testAGValidErrorsTest() {
        let generalError = NSError(domain: AGAuthzErrorDomain, code: AGErrorCodes.general, userInfo: nil)
        XCTAssertTrue(isAGError(error: generalError, withCode: AGErrorCodes.general))

        let unknownError = NSError(domain: AGAuthzErrorDomain, code: AGErrorCodes.unknown, userInfo: nil)
        XCTAssertTrue(isAGError(error: unknownError, withCode: AGErrorCodes.unknown))
        
        let userCanceledError = NSError(domain: AGAuthzErrorDomain, code: AGErrorCodes.userCanceled, userInfo: nil)
        XCTAssertTrue(isAGError(error: userCanceledError, withCode: AGErrorCodes.userCanceled))
    }
}
