//
//  ADJActivityHandler.m
//  Adjust
//
//  Created by Christian Wellenbrock on 2013-07-01.
//  Copyright (c) 2013 adjust GmbH. All rights reserved.
//

#import "ADJActivityPackage.h"
#import "ADJActivityHandler.h"
#import "ADJActivityState.h"
#import "ADJPackageBuilder.h"
#import "ADJPackageHandler.h"
#import "ADJLogger.h"
#import "ADJTimer.h"
#import "ADJUtil.h"
#import "UIDevice+ADJAdditions.h"
#import "ADJAdjustFactory.h"
#import "ADJAttributionHandler.h"

static NSString   * const kActivityStateFilename = @"AdjustIoActivityState";
static NSString   * const kAttributionFilename   = @"AdjustIoAttribution";
static NSString   * const kAdjustPrefix          = @"adjust_";
static const char * const kInternalQueueName     = "io.adjust.ActivityQueue";

static const NSTimeInterval kTimerInterval = 60; // 1 minute


#pragma mark -
@interface ADJActivityHandler()

@property (nonatomic) dispatch_queue_t internalQueue;
@property (nonatomic, retain) id<ADJPackageHandler> packageHandler;
@property (nonatomic, retain) id<ADJAttributionHandler> attributionHandler;
@property (nonatomic, retain) ADJActivityState *activityState;
@property (nonatomic, retain) ADJTimer *timer;
@property (nonatomic, retain) id<ADJLogger> logger;
@property (nonatomic, retain) NSObject<AdjustDelegate> *delegate;
@property (nonatomic, copy) ADJAttribution *attribution;
@property (nonatomic, copy) ADJConfig *adjustConfig;

@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL offline;

@property (nonatomic, copy) ADJDeviceInfo* deviceInfo;

@end


#pragma mark -
@implementation ADJActivityHandler

+ (id<ADJActivityHandler>)handlerWithConfig:(ADJConfig *)adjustConfig {
    return [[ADJActivityHandler alloc] initWithConfig:adjustConfig];
}


- (id)initWithConfig:(ADJConfig *)adjustConfig {
    self = [super init];
    if (self == nil) return nil;

    if (adjustConfig == nil) {
        [ADJAdjustFactory.logger error:@"AdjustConfig not initialized correctly"];
        return nil;
    }

    if (![adjustConfig isValid]) {
        return nil;
    }

    self.adjustConfig = adjustConfig;
    self.delegate = adjustConfig.delegate;

    self.logger = ADJAdjustFactory.logger;
    [self addNotificationObserver];
    self.internalQueue = dispatch_queue_create(kInternalQueueName, DISPATCH_QUEUE_SERIAL);
    _enabled = YES;

    dispatch_async(self.internalQueue, ^{
        [self initInternal];
    });

    return self;
}

- (void)trackSubsessionStart {
    dispatch_async(self.internalQueue, ^{
        [self startInternal];
    });
}

- (void)trackSubsessionEnd {
    dispatch_async(self.internalQueue, ^{
        [self endInternal];
    });
}

- (void)trackEvent:(ADJEvent *)event
{
    dispatch_async(self.internalQueue, ^{
        [self eventInternal:event];
    });
}

- (void)finishedTrackingWithResponse:(NSDictionary *)jsonDict{
    [self launchDeepLink:jsonDict];
    [[self getAttributionHandler] checkAttribution:jsonDict];
}

- (void)launchDeepLink:(NSDictionary *)jsonDict{
    if (jsonDict == nil || jsonDict == (id)[NSNull null]) return;

    NSString *deepLink = [jsonDict objectForKey:@"deeplink"];
    if (deepLink == nil) return;

    NSURL* deepLinkUrl = [NSURL URLWithString:deepLink];

    if (![[UIApplication sharedApplication]
          canOpenURL:deepLinkUrl]) {
        [self.logger error:@"Unable to open deep link (%@)", deepLink];
        return;
    }

    [self.logger info:@"Open deep link (%@)", deepLink];

    [[UIApplication sharedApplication] openURL:deepLinkUrl];
}

- (void)setEnabled:(BOOL)enabled {
    if (enabled == _enabled) {
        if (enabled) {
            [self.logger debug:@"Adjust already enabled"];
        } else {
            [self.logger debug:@"Adjust already disabled"];
        }
    }
    _enabled = enabled;
    if (self.activityState != nil) {
        self.activityState.enabled = enabled;
        [self writeActivityState];
    }
    if (enabled) {
        if ([self toPause]) {
            [self.logger info:@"Package and attribution handler remain paused due to the SDK is offline"];
        } else {
            [self.logger info:@"Resuming package handler and attribution handler to enabled the SDK"];
        }
        [self trackSubsessionStart];
    } else {
        [self.logger info:@"Pausing package handler and attribution handler to disable the SDK"];
        [self trackSubsessionEnd];
    }
}

- (BOOL)isEnabled {
    if (self.activityState != nil) {
        return self.activityState.enabled;
    } else {
        return _enabled;
    }
}

- (void)appWillOpenUrl:(NSURL*)url {
    dispatch_async(self.internalQueue, ^{
        [self appWillOpenUrlInternal:url];
    });
}

- (void)setDeviceToken:(NSData *)deviceToken {
    dispatch_async(self.internalQueue, ^{
        [self setDeviceTokenInternal:deviceToken];
    });
}

- (void)setIadDate:(NSDate *)iAdImpressionDate withPurchaseDate:(NSDate *)appPurchaseDate {
    if (iAdImpressionDate == nil) {
        return;
    }

    ADJPackageBuilder *clickBuilder = [[ADJPackageBuilder alloc]
                                       initWithDeviceInfo:self.deviceInfo
                                       activityState:self.activityState
                                       config:self.adjustConfig];

    [clickBuilder setClickTime:iAdImpressionDate];
    [clickBuilder setPurchaseTime:appPurchaseDate];

    ADJActivityPackage *clickPackage = [clickBuilder buildClickPackage:@"iad"];
    [self.packageHandler sendClickPackage:clickPackage];
}

- (BOOL)updateAttribution:(ADJAttribution *)attribution {
    if (attribution == nil) {
        return NO;
    }
    if ([attribution isEqual:self.attribution]) {
        return NO;
    }
    self.attribution = attribution;
    [self writeAttribution];

    return YES;
}

- (void)launchAttributionDelegate{
    if (self.delegate == nil) {
        return;
    }
    [self.delegate performSelectorOnMainThread:@selector(adjustAttributionChanged:)
                                    withObject:self.attribution waitUntilDone:NO];
}

- (void)setOfflineMode:(BOOL)offline {
    if (self.offline == offline) {
        if (offline) {
            [self.logger debug:@"Adjust already in offline mode"];
        } else {
            [self.logger debug:@"Adjust already in online mode"];
        }
    }
    self.offline = offline;
    if (offline) {
        [self.logger info:@"Pausing package and attribution handler to put in offline mode"];
    } else {
        if ([self toPause]) {
            [self.logger info:@"Package and attribution handler remain paused because the SDK is disabled"];
        } else {
            [self.logger info:@"Resuming package handler and attribution handler to put in online mode"];
        }
    }
    [self updateStatus];
}

- (void)setAskingAttribution:(BOOL)askingAttribution {
    self.activityState.askingAttribution = askingAttribution;
    [self writeActivityState];
}

- (void)updateStatus {
    dispatch_async(self.internalQueue, ^{
        [self updateStatusInternal];
    });
}

#pragma mark - internal
- (void)initInternal {
    self.deviceInfo = [ADJDeviceInfo deviceInfoWithSdkPrefix:self.adjustConfig.sdkPrefix];

    if ([self.adjustConfig.environment isEqualToString:ADJEnvironmentProduction]) {
        [self.logger setLogLevel:ADJLogLevelAssert];
    } else {
        [self.logger setLogLevel:self.adjustConfig.logLevel];
    }

    if (!self.adjustConfig.macMd5TrackingEnabled) {
        [self.logger info:@"Tracking of macMd5 is disabled"];
    }

    if (self.adjustConfig.eventBufferingEnabled)  {
        [self.logger info:@"Event buffering is enabled"];
    }

    if (self.adjustConfig.defaultTracker != nil) {
        [self.logger info:@"Default tracker: %@", self.adjustConfig.defaultTracker];
    }

    [self readAttribution];
    [self readActivityState];

    self.packageHandler = [ADJAdjustFactory packageHandlerForActivityHandler:self
                                                                 startPaused:[self toPause]];

    self.timer = [ADJTimer timerWithBlock:^{ [self timerFired]; }
                                    queue:self.internalQueue
                                startTime:0
                             intervalTime:kTimerInterval];

    [[UIDevice currentDevice] adjSetIad:self];

    [self startInternal];
}

- (id<ADJAttributionHandler>) getAttributionHandler {
    //TODO self.activity state can be null in the first session
    if (self.attributionHandler == nil) {
        ADJPackageBuilder *attributionBuilder = [[ADJPackageBuilder alloc] initWithDeviceInfo:self.deviceInfo
                                                                                activityState:self.activityState
                                                                                       config:self.adjustConfig];
        ADJActivityPackage *attributionPackage = [attributionBuilder buildAttributionPackage];
        self.attributionHandler = [ADJAdjustFactory
                                   attributionHandlerForActivityHandler:self
                                   withAttributionPackage:attributionPackage
                                   startPaused:[self toPause]
                                   hasDelegate:(self.delegate != nil)];
    }

    return self.attributionHandler;
}

- (void)startInternal {
    if (self.activityState != nil
        && !self.activityState.enabled) {
        return;
    }

    [self updateStatusInternal];

    [self processSession];

    [self checkAttributionState];

    [self startTimer];
}

- (void)processSession {

    double now = [NSDate.date timeIntervalSince1970];

    // very first session
    if (self.activityState == nil) {
        self.activityState = [[ADJActivityState alloc] init];
        self.activityState.sessionCount = 1; // this is the first session
        self.activityState.createdAt = now;  // starting now

        [self transferSessionPackage];
        [self.activityState resetSessionAttributes:now];
        self.activityState.enabled = _enabled;
        [self writeActivityState];
        return;
    }

    double lastInterval = now - self.activityState.lastActivity;
    if (lastInterval < 0) {
        [self.logger error:@"Time travel!"];
        self.activityState.lastActivity = now;
        [self writeActivityState];
        return;
    }

    // new session
    if (lastInterval > ADJAdjustFactory.sessionInterval) {
        self.activityState.sessionCount++;
        self.activityState.createdAt = now;
        self.activityState.lastInterval = lastInterval;

        [self transferSessionPackage];
        [self.activityState resetSessionAttributes:now];
        [self writeActivityState];
        return;
    }

    // new subsession
    if (lastInterval > ADJAdjustFactory.subsessionInterval) {
        self.activityState.subsessionCount++;
        self.activityState.sessionLength += lastInterval;
        self.activityState.lastActivity = now;
        [self writeActivityState];
        [self.logger info:@"Processed Subsession %d of Session %d",
         self.activityState.subsessionCount,
         self.activityState.sessionCount];
    }
}

- (void)checkAttributionState {
    // if it' a new session
    if (self.activityState.subsessionCount <= 1) {
        return;
    }

    if (self.attribution != nil && !self.activityState.askingAttribution) {
        return;
    }

    [[self getAttributionHandler] getAttribution];
}

- (void)endInternal {
    [self.packageHandler pauseSending];
    [self stopTimer];
    double now = [NSDate.date timeIntervalSince1970];
    [self updateActivityState:now];
    [self writeActivityState];
}

- (void)eventInternal:(ADJEvent *)event
{
    // check consistency
    if (![self checkActivityState:self.activityState]) return;
    if (![event isValid]) return;
    if (![self checkTransactionId:event.transactionId]) return;

    if (!self.activityState.enabled) {
        return;
    }

    // update activity state
    double now = [NSDate.date timeIntervalSince1970];
    [self updateActivityState:now];
    self.activityState.createdAt = now;
    self.activityState.eventCount++;

    // create and populate event package
    ADJPackageBuilder *eventBuilder = [[ADJPackageBuilder alloc] initWithDeviceInfo:self.deviceInfo
                                                                      activityState:self.activityState
                                                                             config:self.adjustConfig];
    ADJActivityPackage *eventPackage = [eventBuilder buildEventPackage:event];
    [self.packageHandler addPackage:eventPackage];

    if (self.adjustConfig.eventBufferingEnabled) {
        [self.logger info:@"Buffered event%@", eventPackage.suffix];
    } else {
        [self.packageHandler sendFirstPackage];
    }

    [self writeActivityState];
}

- (void) appWillOpenUrlInternal:(NSURL *)url {
    NSArray* queryArray = [url.query componentsSeparatedByString:@"&"];
    if (queryArray == nil) {
        return;
    }

    NSMutableDictionary* adjustDeepLinks = [NSMutableDictionary dictionary];
    ADJAttribution *deeplinkAttribution = [[ADJAttribution alloc] init];
    BOOL hasDeepLink = NO;

    for (NSString* fieldValuePair in queryArray) {
        if([self readDeeplinkQueryString:fieldValuePair adjustDeepLinks:adjustDeepLinks attribution:deeplinkAttribution]) {
            hasDeepLink = YES;
        }
    }

    if (!hasDeepLink) {
        return;
    }

    [[self getAttributionHandler] getAttribution];

    ADJPackageBuilder *clickBuilder = [[ADJPackageBuilder alloc] initWithDeviceInfo:self.deviceInfo
                                                                      activityState:self.activityState
                                                                             config:self.adjustConfig];
    clickBuilder.deeplinkParameters = adjustDeepLinks;
    clickBuilder.attribution = deeplinkAttribution;
    [clickBuilder setClickTime:[NSDate date]];

    ADJActivityPackage *clickPackage = [clickBuilder buildClickPackage:@"deeplink"];
    [self.packageHandler sendClickPackage:clickPackage];
}

- (BOOL) readDeeplinkQueryString:(NSString *)queryString
                 adjustDeepLinks:(NSMutableDictionary*)adjustDeepLinks
                     attribution:(ADJAttribution *)deeplinkAttribution
{
    NSArray* pairComponents = [queryString componentsSeparatedByString:@"="];
    if (pairComponents.count != 2) return NO;

    NSString* key = [pairComponents objectAtIndex:0];
    if (![key hasPrefix:kAdjustPrefix]) return NO;

    NSString* value = [pairComponents objectAtIndex:1];
    if (value.length == 0) return NO;

    NSString* keyWOutPrefix = [key substringFromIndex:kAdjustPrefix.length];
    if (keyWOutPrefix.length == 0) return NO;

    if (![self trySetAttributionDeeplink:deeplinkAttribution withKey:keyWOutPrefix withValue:value]) {
        [adjustDeepLinks setObject:value forKey:keyWOutPrefix];
    }

    return YES;
}

- (BOOL) trySetAttributionDeeplink:(ADJAttribution *)deeplinkAttribution
                           withKey:(NSString *)key
                         withValue:(NSString*)value {

    if ([key isEqualToString:@"tracker"]) {
        deeplinkAttribution.trackerName = value;
        return YES;
    }

    if ([key isEqualToString:@"campaign"]) {
        deeplinkAttribution.campaign = value;
        return YES;
    }

    if ([key isEqualToString:@"adgroup"]) {
        deeplinkAttribution.adgroup = value;
        return YES;
    }

    if ([key isEqualToString:@"creative"]) {
        deeplinkAttribution.creative = value;
        return YES;
    }

    return NO;
}

- (void) setDeviceTokenInternal:(NSData *)deviceToken {
    if (deviceToken == nil) {
        return;
    }

    NSString *token = [deviceToken.description stringByTrimmingCharactersInSet: [NSCharacterSet characterSetWithCharactersInString:@"<>"]];
    token = [token stringByReplacingOccurrencesOfString:@" " withString:@""];

    self.deviceInfo.pushToken = token;
}

#pragma mark - private

// returns whether or not the activity state should be written
- (BOOL)updateActivityState:(double)now {
    if (![self checkActivityState:self.activityState]) return NO;

    double lastInterval = now - self.activityState.lastActivity;
    if (lastInterval < 0) {
        [self.logger error:@"Time travel!"];
        self.activityState.lastActivity = now;
        return YES;
    }

    // ignore late updates
    if (lastInterval > ADJAdjustFactory.sessionInterval) return NO;

    self.activityState.sessionLength += lastInterval;
    self.activityState.timeSpent += lastInterval;
    self.activityState.lastActivity = now;

    return (lastInterval > ADJAdjustFactory.subsessionInterval);
}

- (void)writeActivityState {
    [ADJUtil writeObject:self.activityState filename:kActivityStateFilename objectName:@"Activity state"];
}

- (void)writeAttribution {
    [ADJUtil writeObject:self.attribution filename:kAttributionFilename objectName:@"Attribution"];
}

- (void)readActivityState {
    [NSKeyedUnarchiver setClass:[ADJActivityState class] forClassName:@"AIActivityState"];
    self.activityState = [ADJUtil readObject:kActivityStateFilename
                                  objectName:@"Activity state"
                                       class:[ADJActivityState class]];
}

- (void)readAttribution {
    self.attribution = [ADJUtil readObject:kAttributionFilename
                                objectName:@"Attribution"
                                     class:[ADJAttribution class]];
}

- (void)transferSessionPackage {
    ADJPackageBuilder *sessionBuilder = [[ADJPackageBuilder alloc] initWithDeviceInfo:self.deviceInfo
                                                                        activityState:self.activityState
                                                                               config:self.adjustConfig];
    ADJActivityPackage *sessionPackage = [sessionBuilder buildSessionPackage];
    [self.packageHandler addPackage:sessionPackage];
    [self.packageHandler sendFirstPackage];
}

# pragma mark - handlers status
- (void)updateStatusInternal {
    [self updateAttributionHandlerStatus];
    [self updatePackageHandlerStatus];
}

- (void)updateAttributionHandlerStatus {
    if (self.attributionHandler == nil) {
        return;
    }

    if ([self toPause]) {
        [self.attributionHandler pauseSending];
    } else {
        [self.attributionHandler resumeSending];
    }
}

- (void)updatePackageHandlerStatus {
    if (self.packageHandler == nil) {
        return;
    }

    if ([self toPause]) {
        [self.packageHandler pauseSending];
    } else {
        [self.packageHandler resumeSending];
    }
}

- (BOOL)toPause {
    return self.offline || !self.isEnabled;
}

# pragma mark - timer
- (void)startTimer {
    [self.timer resume];
}

- (void)stopTimer {
    [self.timer suspend];
}

- (void)timerFired {
    if (self.activityState != nil
        && !self.activityState.enabled) {
        return;
    }
    [self.packageHandler sendFirstPackage];
    double now = [NSDate.date timeIntervalSince1970];
    if ([self updateActivityState:now]) {
        [self writeActivityState];
    }
}

#pragma mark - notifications
- (void)addNotificationObserver {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;

    [center removeObserver:self];
    [center addObserver:self
               selector:@selector(trackSubsessionStart)
                   name:UIApplicationDidBecomeActiveNotification
                 object:nil];

    [center addObserver:self
               selector:@selector(trackSubsessionEnd)
                   name:UIApplicationWillResignActiveNotification
                 object:nil];

    [center addObserver:self
               selector:@selector(removeNotificationObserver)
                   name:UIApplicationWillTerminateNotification
                 object:nil];
}

- (void)removeNotificationObserver {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - checks
- (BOOL)checkActivityState:(ADJActivityState *)activityState {
    if (activityState == nil) {
        [self.logger error:@"Missing activity state"];
        return NO;
    }
    return YES;
}

- (BOOL) checkTransactionId:(NSString *)transactionId {
    if (transactionId == nil || transactionId.length == 0) {
        return YES; // no transaction ID given
    }

    if ([self.activityState findTransactionId:transactionId]) {
        [self.logger info:@"Skipping duplicate transaction ID '%@'", transactionId];
        [self.logger verbose:@"Found transaction ID in %@", self.activityState.transactionIds];
        return NO; // transaction ID found -> used already
    }
    
    [self.activityState addTransactionId:transactionId];
    [self.logger verbose:@"Added transaction ID %@", self.activityState.transactionIds];
    // activity state will get written by caller
    return YES;
}

@end
