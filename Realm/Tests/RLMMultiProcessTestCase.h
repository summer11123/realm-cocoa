//
//  RLMMultiProcessTestCase.h
//  Realm
//
//  Created by Thomas Goyne on 2/5/15.
//  Copyright (c) 2015 Realm. All rights reserved.
//

#import "RLMTestCase.h"

@interface RLMMultiProcessTestCase : RLMTestCase
// if true, this is running the main test process
@property (nonatomic, readonly) bool isParent;
// arguments passed from the parent process, or nil if not applicable
@property (nonatomic, readonly) NSDictionary *args;

// spawn a child process running the current test and wait for it complete
// returns the return code of the process
- (int)runChildAndWait:(NSDictionary *)args;
@end

#define RLMRunChildAndWait(...) \
    XCTAssertEqual(0, [self runChildAndWait:@{__VA_ARGS__}], @"Tests in child process failed")