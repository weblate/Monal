//
//  NotificationService.m
//  NotificaionService
//
//  Created by Anurodh Pokharel on 9/16/19.
//  Copyright © 2019 Monal.im. All rights reserved.
//

#import "NotificationService.h"
#import "MLConstants.h"
#import "HelperTools.h"
#import "IPC.h"
#import "MLProcessLock.h"
#import "MLXMPPManager.h"
#import "MLNotificationManager.h"
#import "MLFiletransfer.h"
#import "xmpp.h"

@interface Push : NSObject
@property (atomic, strong) NSMutableArray* handlerList;
@property (atomic, strong) NSMutableSet* idleAccounts;
@end

@implementation Push

+(id) instance
{
    static Push* sharedInstance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[Push alloc] init];
    });
    return sharedInstance;
}

-(id) init
{
    self = [super init];
    DDLogInfo(@"Initializing push singleton");
    self.handlerList = [[NSMutableArray alloc] init];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(nowIdle:) name:kMonalIdle object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(filetransfersNowIdle:) name:kMonalFiletransfersIdle object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(xmppError:) name:kXMPPError object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(incomingIPC:) name:kMonalIncomingIPC object:nil];
    return self;
}

-(void) dealloc
{
    DDLogError(@"Deallocating push singleton");
    [DDLog flushLog];
}

-(void) incomingPush:(void (^)(UNNotificationContent* _Nonnull)) contentHandler
{
    DDLogInfo(@"Got incoming push...pinging main app");
    
    //terminate appex if the main app is already running
    if([MLProcessLock checkRemoteRunning:@"MainApp"])
    {
        //this will make sure we still run if we get triggered immediately after the mainapp disconnected but before its process got freezed
        DDLogDebug(@"Main app already in foreground, sleeping for 5 seconds and trying again");
        usleep(5000000);
        
        DDLogDebug(@"Pinging main app again");
        if([MLProcessLock checkRemoteRunning:@"MainApp"])
        {
            DDLogInfo(@"NOT connecting accounts, main app already running in foreground, terminating immediately instead");
            [DDLog flushLog];
            [self feedAllWaitingHandlersWithCompletion:^{
                //now call this new handler we did not add to our handlerList
                [self callHandler:contentHandler];
            }];
            return;
        }
        else
            DDLogDebug(@"Main app not in foreground anymore, connecting now");
    }
    
    @synchronized(self) {
        DDLogInfo(@"Now handling incoming push");
        BOOL first = NO;
        if(![self.handlerList count])
        {
            DDLogInfo(@"First incoming push");
            self.idleAccounts = [[NSMutableSet alloc] init];
            first = YES;
        }
        
        //add contentHandler to our list
        DDLogDebug(@"Adding content handler to list: %lu", [self.handlerList count]);
        [self.handlerList addObject:contentHandler];
        
        if(first)       //first incoming push --> connect to servers
        {
            DDLogDebug(@"locking process and connecting accounts");
            [DDLog flushLog];
            [MLProcessLock lock];
            [[MLXMPPManager sharedInstance] connectIfNecessary];
        }
        else            //second, third etc. incoming push --> reconnect already idle accounts and check connectivity for already connected ones
        {
            for(xmpp* account in self.idleAccounts)
                [[MLXMPPManager sharedInstance] connectAccount:account.accountNo];
            self.idleAccounts = [[NSMutableSet alloc] init];        //we now don't have idle accounts anymore
        }
    }
}

-(void) pushExpired
{
    @synchronized(self) {
        DDLogInfo(@"Handling expired push: %lu", (unsigned long)[self.handlerList count]);
        
        //we don't want to post any sync error notifications if the xmpp channel is idle and we're only downloading filetransfers
        //(e.g. [MLFiletransfer isIdle] is not YES)
        if([self.handlerList count] <= 1 && ![[MLXMPPManager sharedInstance] allAccountsIdle])
        {
            [HelperTools postSendingErrorNotification];
            //this was the last push in the pipeline --> disconnect to prevent double handling of incoming stanzas
            //that could be handled in mainapp and later again in NSE on next NSE wakeup (because still queued in the freezed NSE)
            [self feedAllWaitingHandlersWithCompletion:nil];
        }
        else
        {
            //post a single silent notification using the next handler (that must have been the expired one because handlers expire in order)
            if([self.handlerList count])
            {
                void (^handler)(UNNotificationContent*) = [self.handlerList firstObject];
                [self.handlerList removeObject:handler];
                [self callHandler:handler];
            }
        }
    }
}

-(void) incomingIPC:(NSNotification*) notification
{
    NSDictionary* message = notification.userInfo;
    if([message[@"name"] isEqualToString:@"Monal.disconnectAll"])
    {
        DDLogInfo(@"Got disconnectAll IPC message");
        [self feedAllWaitingHandlers];
    }
    else if([message[@"name"] isEqualToString:@"Monal.connectIfNecessary"])
    {
        DDLogInfo(@"Got connectIfNecessary IPC message");
        //(re)connect all accounts
        [[MLXMPPManager sharedInstance] connectIfNecessary];
    }
}

-(void) callHandler:(void (^)(UNNotificationContent*)) handler
{
    //this is used with special extension filtering entitlement which does not show notifications with empty body, title and subtitle
    //but: app badge updates are still performed: use this to make sure the badge is up to date, even if a message got marked as read (by XEP-0333 etc.)
    UNMutableNotificationContent* emptyContent = [[UNMutableNotificationContent alloc] init];
    NSNumber* unreadMsgCnt = [[DataLayer sharedInstance] countUnreadMessages];
    DDLogInfo(@"Updating unread badge to: %@", unreadMsgCnt);
    emptyContent.badge = unreadMsgCnt;
    handler(emptyContent);
}

-(void) feedAllWaitingHandlersWithCompletion:(monal_void_block_t) completion
{
    //repeated calls to this method will do nothing (every handler will already be used and every content will already be posted)
    @synchronized(self) {
        DDLogInfo(@"Disconnecting all accounts and feeding all pending handlers: %lu", [self.handlerList count]);
        
        //this has to be synchronous because we only want to continue if all accounts are completely disconnected
        [[MLXMPPManager sharedInstance] disconnectAll];
        
        //for debugging
        [self listNotifications];
        
        //we posted all notifications and disconnected, technically we're not running anymore
        //(even though our containing process will still be running for a few more seconds)
        [MLProcessLock unlock];
        
        //feed all waiting handlers with empty notifications to silence them
        //this will terminate/freeze the app extension afterwards
        while([self.handlerList count])
        {
            DDLogDebug(@"Feeding handler");
            void (^handler)(UNNotificationContent*) = [self.handlerList firstObject];
            [self.handlerList removeObject:handler];
            [self callHandler:handler];
        }
    }
    
    if(completion)
        completion();
}

-(void) feedAllWaitingHandlers
{
    //dispatch in another thread to avoid blocking the thread calling this method (most probably the receiveQueue), which could result in a deadlock
    //without this dispatch a deadlock could also occur when this method tries to enter the receiveQueue (disconnectAll) while the receive queue
    //is waiting for the @synchronized(self) block in this method
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self feedAllWaitingHandlersWithCompletion:nil];
    });
}

-(void) listNotifications
{
    [[UNUserNotificationCenter currentNotificationCenter] getPendingNotificationRequestsWithCompletionHandler:^(NSArray* requests) {
        for(UNNotificationRequest* request in requests)
        {
            DDLogInfo(@"listNotifications: pending notification %@ --> %@: %@", request.identifier, request.content.title, request.content.body);
        }
    }];
    [[UNUserNotificationCenter currentNotificationCenter] getDeliveredNotificationsWithCompletionHandler:^(NSArray* notifications) {
        for(UNNotification* notification in notifications)
        {
            DDLogInfo(@"listNotifications: delivered notification %@ --> %@: %@", notification.request.identifier, notification.request.content.title, notification.request.content.body);
        }
    }];
}

-(void) nowIdle:(NSNotification*) notification
{
    //this method will be called inside the receive queue and immediately disconnect the account
    //this is needed to not leak incoming stanzas while no instance of the NotificaionService class is active
    xmpp* xmppAccount = (xmpp*)notification.object;
    
    //ignore repeated idle notifications for already idle accounts
    @synchronized(self.idleAccounts) {
        if([self.idleAccounts containsObject:xmppAccount])
        {
            DDLogDebug(@"Ignoring already idle account: %@", xmppAccount.connectionProperties.identity.jid);
            return;
        }
        [self.idleAccounts addObject:xmppAccount];
    }
    
    DDLogInfo(@"notification handler: some account idle: %@", xmppAccount.connectionProperties.identity.jid);
    [xmppAccount disconnect];
    
    [self checkIfEverythingIsIdle];
}

-(void) filetransfersNowIdle:(NSNotification*) notification
{
    DDLogDebug(@"notification handler: all filetransfers complete now");
    [self checkIfEverythingIsIdle];
}

-(void) checkIfEverythingIsIdle
{
    if([[MLXMPPManager sharedInstance] allAccountsIdle] && [MLFiletransfer isIdle])
    {
        DDLogInfo(@"notification handler: all accounts idle and filetransfers complete --> terminating extension");
        
        //remove syncError notification because all accounts are idle and fully synced now
        [[UNUserNotificationCenter currentNotificationCenter] removeDeliveredNotificationsWithIdentifiers:@[@"syncError"]];
        
        [self feedAllWaitingHandlers];
    }
}

-(void) xmppError:(NSNotification*) notification
{
    DDLogInfo(@"notification handler: got xmpp error");
    if([notification.userInfo[@"isSevere"] boolValue])
    {
        //dispatch in another thread to avoid blocking the thread posting this notification (most probably the receiveQueue)
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            //disconnect this account and make sure the account is marked as idle afterwards
            //(which will ultimately lead to the termination of this app extension)
            DDLogWarn(@"notification handler: severe account error --> disconnecting this account");
            [notification.object disconnect];
            [self nowIdle:notification];
        });
    }
}

@end

@interface NotificationService ()
@end

@implementation NotificationService

+(void) initialize
{
    [HelperTools configureLogging];
    [DDLog flushLog];
    
    //log unhandled exceptions
    NSSetUncaughtExceptionHandler(&logException);
    
    [HelperTools activityLog];
    
    //init IPC
    [IPC initializeForProcess:@"NotificationServiceExtension"];
    
    //handle message notifications by initializing the MLNotificationManager
    [MLNotificationManager sharedInstance];
    
    //initialize the xmppmanager (used later for connectivity checks etc.)
    //we initialize it here to make sure the connectivity check is complete when using it later
    [MLXMPPManager sharedInstance];
    
    //log startup
    NSDictionary* infoDict = [[NSBundle mainBundle] infoDictionary];
    NSString* version = [infoDict objectForKey:@"CFBundleShortVersionString"];
    NSString* buildDate = [NSString stringWithUTF8String:__DATE__];
    NSString* buildTime = [NSString stringWithUTF8String:__TIME__];
    DDLogInfo(@"Notification Service Extension started: %@", [NSString stringWithFormat:NSLocalizedString(@"Version %@ (%@ %@ UTC)", @ ""), version, buildDate, buildTime]);
    [DDLog flushLog];
    usleep(100000);     //wait for initial connectivity check
}

-(id) init
{
    DDLogInfo(@"Initializing notification service extension class");
    self = [super init];
    return self;
}

-(void) dealloc
{
    DDLogInfo(@"Deallocating notification service extension class");
    [DDLog flushLog];
}

-(void) didReceiveNotificationRequest:(UNNotificationRequest*) request withContentHandler:(void (^)(UNNotificationContent* _Nonnull)) contentHandler
{
    DDLogInfo(@"Notification handler called (request id: %@)", request.identifier);
    
    //just "ignore" this push if we have not migrated our defaults db already (this needs a normal app start to happen)
    if(![[HelperTools defaultsDB] boolForKey:@"DefaulsMigratedToAppGroup"])
    {
        DDLogWarn(@"defaults not migrated to app group, ignoring push and posting notification as coming from the appserver (a dummy one)");
        contentHandler([request.content mutableCopy]);
        return;
    }
    
    //proxy to push singleton
    DDLogDebug(@"proxying to incomingPush");
    [DDLog flushLog];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [[Push instance] incomingPush:contentHandler];
    });
    DDLogDebug(@"incomingPush proxy completed");
    [DDLog flushLog];
}

-(void) serviceExtensionTimeWillExpire
{
    DDLogInfo(@"notification handler expired");
    [DDLog flushLog];
    
    //proxy to push singleton
    DDLogDebug(@"proxying to pushExpired");
    [DDLog flushLog];
    [[Push instance] pushExpired];
    DDLogDebug(@"pushExpired proxy completed");
    [DDLog flushLog];
}

@end
