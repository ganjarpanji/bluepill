//  Copyright 2016 LinkedIn Corporation
//  Licensed under the BSD 2-Clause License (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at https://opensource.org/licenses/BSD-2-Clause
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and limitations under the License.

#import "Bluepill.h"
#import "BPConfiguration.h"
#import "SimulatorRunner.h"
#import "BPTreeParser.h"
#import "BPReporters.h"
#import "BPWriter.h"
#import "BPStats.h"
#import "BPUtils.h"
#import "BPWaitTimer.h"
#import "BPExecutionContext.h"
#import "BPHandler.h"
#import <libproc.h>

#define NEXT(x)     { [Bluepill setDiagnosticFunction:#x from:__FUNCTION__ line:__LINE__]; CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{ (x); }); }

static int volatile interrupted = 0;

void onInterrupt(int ignore) {
    interrupted = 1;
}

@interface Bluepill()

@property (nonatomic, strong) BPConfiguration *config;
@property (nonatomic, strong) BPConfiguration *executionConfigCopy;
@property (nonatomic, strong) BPExecutionContext *context;
@property (nonatomic, assign) BPExitStatus finalExitStatus;
@property (nonatomic, assign) BOOL exitLoop;
@property (nonatomic, assign) NSInteger failureTolerance;
@property (nonatomic, assign) NSInteger retries;

@end

@implementation Bluepill

- (instancetype)initWithConfiguration:(BPConfiguration *)config {
    if (self = [super init]) {
        self.config = config;
    }
    return self;
}

/**
 Kicks off the tests and loops until they're complete

 @return The exit status of the last execution of tests
 */
- (BPExitStatus)run {
    // Set up our SIGINT handler
    signal(SIGINT, onInterrupt);
    // Because failed tests are stored in the config so that they are not rerun,
    // We need to copy this here and any time we retry due to a test failure (not crash)
    self.executionConfigCopy = [self.config copy];

    // Save our failure tolerance because we're going to be changing this
    self.failureTolerance = self.executionConfigCopy.failureTolerance;

    // Start the first attempt
    [self begin];

    // Wait for all attempts to complete, or an interruption
    while ([self continueRunning]) {
        if (interrupted) {
            [BPUtils printInfo:WARNING withString:@"Received interrupt (Ctrl-C). Please wait while cleaning up..."];
            [self deleteSimulatorWithContext:self.context andStatus:BPExitStatusInterrupted];
            break;
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, NO);
    }

    // Tests completed or interruption received, show some quick stats as we exit
    [BPUtils printInfo:INFO withString:@"Number of Executions: %lu", self.retries + 1];
    [BPUtils printInfo:INFO withString:@"Final Exit Status: %@", [BPExitStatusHelper stringFromExitStatus:self.finalExitStatus]];
    return self.finalExitStatus;
}

- (void)begin {
    [self beginWithContext:nil];
}

- (void)beginWithContext:(BPExecutionContext *)context {

    // Create a context if no context specified. This will hold all of the data and objects for the current execution.
    if (!context) {
        [self createContext];
    }

    // Let's go
    NEXT([self setupExecutionWithContext:self.context]);
}

// Retry from the beginning
- (void)retry {
    // There were test failures. If our failure tolerance is 0, then we're good with that.
    if (self.failureTolerance == 0) {
        // If there is no more retries, set the final exitCode to current context's exitCode
        self.finalExitStatus = self.context.exitStatus | self.context.finalExitStatus;
        self.exitLoop = YES;
        return;
    }
    [self.context.parser cleanup];
    // Otherwise, reduce our failure tolerance count and retry
    self.failureTolerance -= 1;
    // Also we need to get rid of our saved tests, so we re-execute everything. Recopy config.
    self.executionConfigCopy = [self.config copy];

    // First increment the retry count
    self.retries += 1;

    // Log some useful information to the log
    [BPUtils printInfo:INFO withString:@"Exit Status: %@", [BPExitStatusHelper stringFromExitStatus:self.finalExitStatus]];
    [BPUtils printInfo:INFO withString:@"Failure Tolerance: %lu", self.failureTolerance];
    [BPUtils printInfo:INFO withString:@"Retry count: %lu", self.retries];

    // Then start again at the beginning
    NEXT([self begin]);
}

// Proceed to next test case
- (void)proceed {
    if (self.retries == [self.config.errorRetriesCount integerValue]) {
        self.finalExitStatus = self.context.exitStatus | self.context.finalExitStatus;
        self.exitLoop = YES;
        [BPUtils printInfo:ERROR withString:@"Too many retries have occurred. Giving up."];
        return;
    }
    self.retries += 1;
    [BPUtils printInfo:INFO withString:@"Exit Status: %@", [BPExitStatusHelper stringFromExitStatus:self.finalExitStatus]];
    [BPUtils printInfo:INFO withString:@"Failure Tolerance: %lu", self.failureTolerance];
    [BPUtils printInfo:INFO withString:@"Retry count: %lu", self.retries];
    self.context.attemptNumber = self.retries + 1; // set the attempt number
    self.context.exitStatus = BPExitStatusTestsAllPassed; // reset exitStatus
    NEXT([self beginWithContext:self.context]);
}

- (void)createContext {
    BPExecutionContext *context = [[BPExecutionContext alloc] init];
    context.config = self.executionConfigCopy;
    context.attemptNumber = self.retries + 1;
    self.context = context; // Store the context on self so that it's accessible to the interrupt handler in the loop
}

- (void)setupExecutionWithContext:(BPExecutionContext *)context {
    // Creates all of the objects we'll need for running the tests. Sets up logging, etc.

    [BPUtils printInfo:INFO withString:@"Running Tests. Attempt Number %lu.", context.attemptNumber];
    [BPStats sharedStats].attemptNumber = context.attemptNumber;

    NSString *simulatorLogPath;
    if (context.config.outputDirectory) {
        simulatorLogPath = [context.config.outputDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"%lu-simulator.log", context.attemptNumber]];
    } else {
        NSError *err;
        NSString *tmpFileName = [BPUtils mkstemp:[NSString stringWithFormat:@"%@/%lu-bp-stdout-%u", NSTemporaryDirectory(), context.attemptNumber, getpid()]
                                       withError:&err];
        simulatorLogPath = tmpFileName;
        if (!tmpFileName) {
            simulatorLogPath = [NSString stringWithFormat:@"/tmp/%lu-simulator.log", context.attemptNumber];
            [BPUtils printError:ERROR withString:@"ERROR: %@\nLeaving log in %@", [err localizedDescription], simulatorLogPath];
        }
    }

    // This is the raw output from the simulator running tests
    BPWriter *simulatorWriter = [[BPWriter alloc] initWithDestination:BPWriterDestinationFile andPath:simulatorLogPath];
    context.parser = [[BPTreeParser alloc] initWithWriter:simulatorWriter];

    if (context.attemptNumber == 1) {
        [context.parser cleanup];
    }

    context.runner = [self createSimulatorRunnerWithContext:context];

    NEXT([self createSimulatorWithContext:context]);
}

- (SimulatorRunner *)createSimulatorRunnerWithContext:(BPExecutionContext *)context {
    return [SimulatorRunner simulatorRunnerWithConfiguration:context.config];
}

- (void)createSimulatorWithContext:(BPExecutionContext *)context {
    NSString *stepName = CREATE_SIMULATOR(context.attemptNumber);
    NSString *deviceName = [NSString stringWithFormat:@"BP%d-%lu", getpid(), context.attemptNumber];

    [[BPStats sharedStats] startTimer:stepName];
    [BPUtils printInfo:INFO withString:stepName];

    __weak typeof(self) __self = self;
    BPWaitTimer *timer = [BPWaitTimer timerWithInterval:60.0];
    [timer start];

    BPCreateSimulatorHandler *handler = [BPCreateSimulatorHandler handlerWithTimer:timer];
    __weak typeof(handler) __handler = handler;

    handler.beginWith = ^{
        [[BPStats sharedStats] endTimer:stepName];
        [BPUtils printInfo:(__handler.error ? FAILED : INFO)
                withString:[NSString stringWithFormat:@"Completed: %@ %@", stepName, context.runner.UDID]];
    };

    handler.onSuccess = ^{
        context.simulatorCreated = YES;
        NEXT([__self installApplicationWithContext:context]);
    };

    handler.onError = ^(NSError *error) {
        [[BPStats sharedStats] addSimulatorCreateFailure];
        [BPUtils printError:ERROR withString:@"%@", [error localizedDescription]];
        // If we failed to create the simulator, there's no reason for us to try to delete it, which can just cause more issues
        NEXT([__self deleteSimulatorWithContext:context andStatus:BPExitStatusSimulatorCreationFailed]);
    };

    handler.onTimeout = ^{
        [[BPStats sharedStats] addSimulatorCreateFailure];
        [[BPStats sharedStats] endTimer:stepName];
        [BPUtils printInfo:FAILED withString:[@"Timeout: " stringByAppendingString:stepName]];
        // If we failed to create the simulator, there's no reason for us to try to delete it, which can just cause more issues
        NEXT([__self deleteSimulatorWithContext:context andStatus:BPExitStatusSimulatorCreationFailed]);
    };

    [context.runner createSimulatorWithDeviceName:deviceName completion:handler.defaultHandlerBlock];
}

- (void)installApplicationWithContext:(BPExecutionContext *)context {
    NSString *stepName = INSTALL_APPLICATION(context.attemptNumber);
    [[BPStats sharedStats] startTimer:stepName];
    [BPUtils printInfo:INFO withString:stepName];

    NSError *error = nil;
    BOOL success = [context.runner installApplicationAndReturnError:&error];

    [[BPStats sharedStats] endTimer:stepName];
    [BPUtils printInfo:(success ? INFO : FAILED) withString:[@"Completed: " stringByAppendingString:stepName]];

    if (!success) {
        [[BPStats sharedStats] addSimulatorInstallFailure];
        [BPUtils printError:ERROR withString:@"Could not install app in simulator: %@", [error localizedDescription]];
        NEXT([self deleteSimulatorWithContext:context andStatus:BPExitStatusInstallAppFailed]);
        return;
    } else {
        NEXT([self launchApplicationWithContext:context]);
    }
}

- (void)launchApplicationWithContext:(BPExecutionContext *)context {
    NSString *stepName = LAUNCH_APPLICATION(context.attemptNumber);
    [BPUtils printInfo:INFO withString:stepName];

    [[BPStats sharedStats] startTimer:stepName];
    [[BPStats sharedStats] startTimer:RUN_TESTS(context.attemptNumber)];

    __weak typeof(self) __self = self;
    BPWaitTimer *timer = [BPWaitTimer timerWithInterval:300.0];
    [timer start];

    BPApplicationLaunchHandler *handler = [BPApplicationLaunchHandler handlerWithTimer:timer];
    __weak typeof(handler) __handler = handler;

    handler.beginWith = ^{
        [BPUtils printInfo:((__handler.pid > -1) ? INFO : ERROR) withString:[@"Completed: " stringByAppendingString:stepName]];
    };

    handler.onSuccess = ^{
        context.pid = __handler.pid;
        NEXT([__self checkProcessWithContext:context]);
    };

    handler.onError = ^(NSError *error) {
        [[BPStats sharedStats] endTimer:RUN_TESTS(context.attemptNumber)];
        [BPUtils printError:ERROR withString:@"Could not launch app and tests: %@", [error localizedDescription]];
        NEXT([__self deleteSimulatorWithContext:context andStatus:BPExitStatusLaunchAppFailed]);
    };

    handler.onTimeout = ^{
        [[BPStats sharedStats] addSimulatorLaunchFailure];
        [[BPStats sharedStats] endTimer:RUN_TESTS(context.attemptNumber)];
        [[BPStats sharedStats] endTimer:stepName];
        [BPUtils printInfo:FAILED withString:[@"Timeout: " stringByAppendingString:stepName]];
        NEXT([__self deleteSimulatorWithContext:context andStatus:BPExitStatusLaunchAppFailed]);
    };

    [context.runner launchApplicationAndExecuteTestsWithParser:context.parser andCompletion:handler.defaultHandlerBlock];
}

- (void)checkProcessWithContext:(BPExecutionContext *)context {
    BOOL isRunning = [self isProcessRunningWithContext:context];
    if (!isRunning && [context.runner isFinished]) {
        [[BPStats sharedStats] endTimer:RUN_TESTS(context.attemptNumber)];
        [self runnerCompletedWithContext:context];
        return;
    }
    if (![context.runner isSimulatorRunning]) {
        [[BPStats sharedStats] endTimer:RUN_TESTS(context.attemptNumber)];
        [BPUtils printInfo:ERROR withString:@"SIMULATOR CRASHED!!!"];
        context.simulatorCrashed = YES;
        [[BPStats sharedStats] addSimulatorCrash];
        [self deleteSimulatorWithContext:context andStatus:BPExitStatusSimulatorCrashed];
        return;
    }

    NEXT([self checkProcessWithContext:context]);
}

- (BOOL)isProcessRunningWithContext:(BPExecutionContext *)context {
    int rc = kill(context.pid, 0);
    return !(rc < 0);
}

- (void)runnerCompletedWithContext:(BPExecutionContext *)context {
    NSInteger maxRetries = [context.config.errorRetriesCount integerValue];

    [context.parser completed];
    if (context.attemptNumber > maxRetries) {
        // This is the final retry, so we should force a calculation if we error'd
        [context.parser completedFinalRun];
    }

    if (context.simulatorCrashed == NO) {
        // Dump standard log to stdout
        BPWriter *standardLog;
        if (context.config.plainOutput) {
            if (context.config.outputDirectory) {
                NSString *fileName = [NSString stringWithFormat:@"%lu-%@-results.txt",
                                      context.attemptNumber,
                                      [[context.config.testBundlePath lastPathComponent] stringByDeletingPathExtension]];
                NSString *outputFile = [context.config.outputDirectory stringByAppendingPathComponent:fileName];
                standardLog = [[BPWriter alloc] initWithDestination:BPWriterDestinationFile andPath:outputFile];
            } else {
                standardLog = [[BPWriter alloc] initWithDestination:BPWriterDestinationStdout];
            }
            [standardLog writeLine:@"%@", [context.parser generateLog:[[StandardReporter alloc] init]]];
        }

        if (context.config.junitOutput) {
            BPWriter *junitLog;
            if (context.config.outputDirectory) {
                // Only single xml entry.
                NSString *fileName = [NSString stringWithFormat:@"TEST-%@-results.xml",
                                      [[context.config.testBundlePath lastPathComponent] stringByDeletingPathExtension]];
                NSString *outputFile = [context.config.outputDirectory stringByAppendingPathComponent:fileName];
                junitLog = [[BPWriter alloc] initWithDestination:BPWriterDestinationFile andPath:outputFile];
            } else {
                junitLog = [[BPWriter alloc] initWithDestination:BPWriterDestinationStdout];
            }
            [junitLog removeFile];
            [junitLog writeLine:@"%@", [context.parser generateLog:[[JUnitReporter alloc] init]]];
        }

        if (context.config.jsonOutput) {
            BPWriter *jsonLog;
            if (context.config.outputDirectory) {
                NSString *fileName = [NSString stringWithFormat:@"%lu-%@-timings.json",
                                      context.attemptNumber,
                                      [[context.config.testBundlePath lastPathComponent] stringByDeletingPathExtension]];
                NSString *outputFile = [context.config.outputDirectory stringByAppendingPathComponent:fileName];
                jsonLog = [[BPWriter alloc] initWithDestination:BPWriterDestinationFile andPath:outputFile];
            } else {
                jsonLog = [[BPWriter alloc] initWithDestination:BPWriterDestinationStdout];
            }
            [jsonLog writeLine:@"%@", [context.parser generateLog:[[JSONReporter alloc] init]]];
        }
    }

    if (context.simulatorCrashed) {
        // If we crashed, we need to retry
        [self deleteSimulatorWithContext:context andStatus:BPExitStatusSimulatorCrashed];
    } else {
        [self deleteSimulatorWithContext:context andStatus:[context.runner exitStatus]];
    }
}

- (void)deleteSimulatorWithContext:(BPExecutionContext *)context andStatus:(BPExitStatus)status {
    NSString *stepName = DELETE_SIMULATOR(context.attemptNumber);
    context.exitStatus = status;

    if (!context.simulatorCreated) {
        // Since we didn't create the simulator, don't try to delete the simulator and just go straight to finish
        NEXT([self finishWithContext:context]);
        return;
    }

    [[BPStats sharedStats] startTimer:stepName];
    [BPUtils printInfo:INFO withString:stepName];

    __weak typeof(self) __self = self;
    BPWaitTimer *timer = [BPWaitTimer timerWithInterval:60.0];
    [timer start];

    BPDeleteSimulatorHandler *handler = [BPDeleteSimulatorHandler handlerWithTimer:timer];
    __weak typeof(handler) __handler = handler;

    handler.beginWith = ^{
        [[BPStats sharedStats] endTimer:stepName];
        [BPUtils printInfo:(__handler.error ? FAILED : INFO) withString:[@"Completed: " stringByAppendingString:stepName]];
    };

    handler.onSuccess = ^{
        NEXT([__self finishWithContext:context]);
    };

    handler.onError = ^(NSError *error) {
        [[BPStats sharedStats] addSimulatorDeleteFailure];
        [BPUtils printError:ERROR withString:@"%@", [error localizedDescription]];
        NEXT([__self finishWithContext:context]);
    };

    handler.onTimeout = ^{
        [[BPStats sharedStats] addSimulatorDeleteFailure];
        [[BPStats sharedStats] endTimer:stepName];
        [BPUtils printInfo:FAILED
                withString:[@"Timeout: " stringByAppendingString:stepName]];
        NEXT([__self finishWithContext:context]);
    };

    [context.runner deleteSimulatorWithCompletion:handler.defaultHandlerBlock];
}

/**
 Scenarios:
 1. crash/time out and proceed passes -> Crash/Timeout
 2. crash/time out and retry passes -> AllPass
 3. failure and retry passes -> AllPass
 4. happy all pass -> AllPassed
 5. failure and still fails -> TestFailed
 */
- (void)finishWithContext:(BPExecutionContext *)context {

    // Because BPExitStatusTestsAllPassed is 0, we must check it explicitly against
    // the run rather than the aggregate bitmask built with finalExitStatus

    switch (context.exitStatus) {
        // BP exit handler
        case BPExitStatusInterrupted:
            self.exitLoop = YES;
            return;

        // MARK: Test suite completed

        // If there is no test crash/time out, we retry from scratch
        case BPExitStatusTestsFailed:
            NEXT([self retry]);
            return;

        case BPExitStatusTestsAllPassed:
            // Check previous result
            if (context.finalExitStatus != BPExitStatusTestsAllPassed) {
                // If there is a test crashed/timed out before, retry from scratch
                NEXT([self retry]);
            } else {
                // If it is a real all pass, exit
                self.exitLoop = YES;
                return;
            }
            return;

        // Retry from scratch if there is tooling failure.
        case BPExitStatusSimulatorCreationFailed:
        case BPExitStatusSimulatorCrashed:
        case BPExitStatusInstallAppFailed:
        case BPExitStatusLaunchAppFailed:
            NEXT([self retry]);
            return;

        // If it is test hanging or crashing, we set final exit code of current context and proceed.
        case BPExitStatusTestTimeout:
            context.finalExitStatus = BPExitStatusTestTimeout;
            NEXT([self proceed]);
            return;
        case BPExitStatusAppCrashed:
            context.finalExitStatus = BPExitStatusAppCrashed;
            NEXT([self proceed]);
            return;
    }

}

// MARK: Helpers

- (BOOL)continueRunning {
    return (self.exitLoop == NO);
}

int __line;
NSString *__function;
NSString *__from;

+ (void)setDiagnosticFunction:(const char *)function from:(const char *)from line:(int)line {
    __function = [NSString stringWithCString:function encoding:NSUTF8StringEncoding];
    __from = [NSString stringWithCString:from encoding:NSUTF8StringEncoding];
    __line = line;
}

- (NSString *)debugDescription {
    return [NSString stringWithFormat:@"Currently executing %@: Line %d (Invoked by: %@)", __function, __line, __from];
}

@end
