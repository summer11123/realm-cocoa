//
//  RLMMultiProcessTestCase.m
//  Realm
//
//  Created by Thomas Goyne on 2/5/15.
//  Copyright (c) 2015 Realm. All rights reserved.
//

#import "RLMMultiProcessTestCase.h"

@interface RLMMultiProcessTestCase ()
@property (nonatomic) bool isParent;
@property (nonatomic, strong) NSString *testName;

@property (nonatomic, strong) NSString *xctestPath;
@property (nonatomic, strong) NSString *testsPath;
@end

@implementation RLMMultiProcessTestCase
// Override all of the methods for creating a XCTestCase object to capture the current test name
+ (id)testCaseWithInvocation:(NSInvocation *)invocation {
    RLMMultiProcessTestCase *testCase = [super testCaseWithInvocation:invocation];
    testCase.testName = NSStringFromSelector(invocation.selector);
    return testCase;
}

- (id)initWithInvocation:(NSInvocation *)invocation {
    self = [super initWithInvocation:invocation];
    if (self) {
        self.testName = NSStringFromSelector(invocation.selector);
    }
    return self;
}

+ (id)testCaseWithSelector:(SEL)selector {
    RLMMultiProcessTestCase *testCase = [super testCaseWithSelector:selector];
    testCase.testName = NSStringFromSelector(selector);
    return testCase;
}

- (id)initWithSelector:(SEL)selector {
    self = [super initWithSelector:selector];
    if (self) {
        self.testName = NSStringFromSelector(selector);
    }
    return self;
}

- (void)setUp {
    self.isParent = !getenv("RLMProcessIsChild");

    NSProcessInfo *info = NSProcessInfo.processInfo;
    self.xctestPath = info.arguments[0];
    self.testsPath = [info.arguments lastObject];

    [super setUp];
}

- (void)deleteFiles {
    // Only the parent should delete files in setUp/tearDown
    if (self.isParent) {
        [super deleteFiles];
    }
}

- (NSDictionary *)args {
    NSString *args = NSProcessInfo.processInfo.environment[@"RLMArguments"];
    if (!args) {
        return nil;
    }
    return [NSKeyedUnarchiver unarchiveObjectWithData:[[NSData alloc] initWithBase64EncodedString:args options:0]];
}

- (int)runChildAndWait:(NSDictionary *)args {
    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    env[@"RLMProcessIsChild"] = @"true";
    env[@"RLMArguments"] = [[NSKeyedArchiver archivedDataWithRootObject:args] base64EncodedStringWithOptions:0];

    NSString *testName = [NSString stringWithFormat:@"%@/%@", self.className, self.testName];

    NSPipe *outputPipe = [NSPipe pipe];
    NSFileHandle *handle = outputPipe.fileHandleForReading;

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = self.xctestPath;
    task.arguments = @[@"-XCTest", testName, self.testsPath];
    task.environment = env;
    task.standardError = outputPipe;
    [task launch];

    NSFileHandle *err = [NSFileHandle fileHandleWithStandardError];
    NSData *delimiter = [@"\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *buffer = [NSMutableData data];

    // Filter the output from the child process to reduce xctest noise
    while (true) {
        NSUInteger newline = [buffer rangeOfData:delimiter options:0 range:NSMakeRange(0, buffer.length)].location;
        if (newline != NSNotFound) {
            // Skip lines starting with "Test Case", "Test Suite" and "     Executed"
            const void *b = buffer.bytes;
            if (newline < 13 || (memcmp(b, "Test Suite", 10) && memcmp(b, "Test Case", 9) && memcmp(b, "     Executed", 13))) {
                [err writeData:[[NSData alloc] initWithBytesNoCopy:buffer.mutableBytes length:newline + 1 freeWhenDone:NO]];
            }
            [buffer replaceBytesInRange:NSMakeRange(0, newline + 1) withBytes:NULL length:0];
        }

        @autoreleasepool {
            NSData *next = [handle availableData];
            if (!next.length)
                break;
            [buffer appendData:next];
        }
    }

    [task waitUntilExit];

    return task.terminationStatus;
}
@end

@interface InterprocessTest : RLMMultiProcessTestCase
@end

@implementation InterprocessTest
- (void)testCreateInitialRealmInChild {
    if (self.isParent) {
        RLMRunChildAndWait();
        RLMRealm *realm = [RLMRealm defaultRealm];
        XCTAssertEqual(1U, [IntObject allObjectsInRealm:realm].count);
    }
    else {
        RLMRealm *realm = [RLMRealm defaultRealm];
        [realm beginWriteTransaction];
        [IntObject createInRealm:realm withObject:@[@0]];
        [realm commitWriteTransaction];
    }
}

- (void)testCreateInitialRealmInParent {
    RLMRealm *realm = [RLMRealm defaultRealm];
    if (self.isParent) {
        [realm beginWriteTransaction];
        [IntObject createInRealm:realm withObject:@[@0]];
        [realm commitWriteTransaction];

        RLMRunChildAndWait();
    }
    else {
        XCTAssertEqual(1U, [IntObject allObjectsInRealm:realm].count);
    }
}

- (void)testOpenInParentThenAddObjectInChild {
    RLMRealm *realm = [RLMRealm defaultRealm];
    XCTAssertEqual(0U, [IntObject allObjectsInRealm:realm].count);

    if (self.isParent) {
        RLMRunChildAndWait();
        XCTAssertEqual(1U, [IntObject allObjectsInRealm:realm].count);
    }
    else {
        [realm beginWriteTransaction];
        [IntObject createInRealm:realm withObject:@[@0]];
        [realm commitWriteTransaction];
    }
}

- (void)testOpenInParentThenAddObjectInChildWithoutAutorefresh {
    RLMRealm *realm = [RLMRealm defaultRealm];
    realm.autorefresh = NO;
    XCTAssertEqual(0U, [IntObject allObjectsInRealm:realm].count);

    if (self.isParent) {
        RLMRunChildAndWait();
        XCTAssertEqual(0U, [IntObject allObjectsInRealm:realm].count);
        [realm refresh];
        XCTAssertEqual(1U, [IntObject allObjectsInRealm:realm].count);
    }
    else {
        [realm beginWriteTransaction];
        [IntObject createInRealm:realm withObject:@[@0]];
        [realm commitWriteTransaction];
    }
}

- (void)testChangeInChildTriggersNotificationInParent {
    RLMRealm *realm = [RLMRealm defaultRealm];
    XCTAssertEqual(0U, [IntObject allObjectsInRealm:realm].count);

    if (self.isParent) {
        [self waitForNotification:RLMRealmDidChangeNotification realm:realm block:^{
            RLMRunChildAndWait();
        }];
        XCTAssertEqual(1U, [IntObject allObjectsInRealm:realm].count);
    }
    else {
        [realm beginWriteTransaction];
        [IntObject createInRealm:realm withObject:@[@0]];
        [realm commitWriteTransaction];
    }
}

- (void)testShareInMemoryRealm {
    RLMRealm *realm = [RLMRealm inMemoryRealmWithIdentifier:@"test"];
    XCTAssertEqual(0U, [IntObject allObjectsInRealm:realm].count);

    if (self.isParent) {
        [self waitForNotification:RLMRealmDidChangeNotification realm:realm block:^{
            RLMRunChildAndWait();
        }];
        XCTAssertEqual(1U, [IntObject allObjectsInRealm:realm].count);
    }
    else {
        [realm beginWriteTransaction];
        [IntObject createInRealm:realm withObject:@[@0]];
        [realm commitWriteTransaction];
    }
}

- (void)testBidirectionalCommunication {
    const int stopValue = 100;

    RLMRealm *realm = [RLMRealm inMemoryRealmWithIdentifier:@"test"];
    [realm beginWriteTransaction];
    IntObject *obj = [IntObject allObjectsInRealm:realm].firstObject;
    if (!obj) {
        obj = [IntObject createInRealm:realm withObject:@[@0]];
        [realm commitWriteTransaction];
    }
    else {
        [realm cancelWriteTransaction];
    }

    RLMNotificationToken *token = [realm addNotificationBlock:^(__unused NSString *note, __unused RLMRealm *realm) {
        if (obj.intCol % 2 != self.isParent && obj.intCol < stopValue) {
            [realm transactionWithBlock:^{
                obj.intCol++;
            }];
        }
    }];

    if (self.isParent) {
        dispatch_queue_t queue = dispatch_queue_create("background", 0);
        dispatch_async(queue, ^{ RLMRunChildAndWait(); });
        while (obj.intCol < stopValue) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
        }
        dispatch_sync(queue, ^{});
    }
    else {
        [realm transactionWithBlock:^{
            obj.intCol++;
        }];
        while (obj.intCol < stopValue) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
        }
    }

    [realm removeNotification:token];
}

- (void)testManyWriters {
    if (self.isParent) {
        RLMRunChildAndWait(@"stuff": @"test");
    }
    else {
        NSLog(@"args: %@", self.args);
    }
}

@end
