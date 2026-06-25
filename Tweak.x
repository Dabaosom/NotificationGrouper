
// NotificationGrouper - iOS 17 通知归纳插件
// 功能: 按应用分组、时间窗口聚合、摘要显示

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// 通知组管理单例
@interface NGNotificationManager : NSObject
@property (nonatomic, strong) NSMutableDictionary *groupedNotifications;  // bundleID -> notifications array
@property (nonatomic, strong) NSMutableDictionary *lastNotificationTime;   // bundleID -> last timestamp
@property (nonatomic, assign) NSTimeInterval aggregationWindow;           // 聚合时间窗口（秒）
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, strong) NSSet *whitelistApps;                     // 白名单（不聚合的App）

+ (instancetype)sharedManager;
- (void)loadSettings;
- (BOOL)shouldAggregateNotificationFromApp:(NSString *)bundleID;
- (void)addNotification:(id)notification withBundleID:(NSString *)bundleID;
- (NSString *)getSummaryForBundleID:(NSString *)bundleID;
@end

@implementation NGNotificationManager

+ (instancetype)sharedManager {
    static NGNotificationManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[NGNotificationManager alloc] init];
    });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _groupedNotifications = [NSMutableDictionary dictionary];
        _lastNotificationTime = [NSMutableDictionary dictionary];
        _aggregationWindow = 300;  // 默认5分钟
        _enabled = YES;
        _whitelistApps = [NSSet setWithObjects:@"com.apple.MobileSMS", nil];  // 短信默认不聚合
        [self loadSettings];
    }
    return self;
}

- (void)loadSettings {
    NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.yourname.notificationgrouper.plist"];
    if (settings) {
        _enabled = [settings[@"enabled"] boolValue] ?: YES;
        _aggregationWindow = [settings[@"aggregationWindow"] doubleValue] ?: 300;
        
        NSArray *whitelist = settings[@"whitelistApps"];
        if (whitelist) {
            _whitelistApps = [NSSet setWithArray:whitelist];
        }
    }
}

- (BOOL)shouldAggregateNotificationFromApp:(NSString *)bundleID {
    if (!_enabled) return NO;
    if ([_whitelistApps containsObject:bundleID]) return NO;
    return YES;
}

- (void)addNotification:(id)notification withBundleID:(NSString *)bundleID {
    @synchronized (self) {
        if (!_groupedNotifications[bundleID]) {
            _groupedNotifications[bundleID] = [NSMutableArray array];
        }
        
        [_groupedNotifications[bundleID] addObject:notification];
        _lastNotificationTime[bundleID] = @([NSDate date].timeIntervalSince1970);
    }
}

- (NSString *)getSummaryForBundleID:(NSString *)bundleID {
    @synchronized (self) {
        NSArray *notifications = _groupedNotifications[bundleID];
        if (!notifications || notifications.count == 0) {
            return nil;
        }
        
        if (notifications.count == 1) {
            // 只有一条通知，返回原始内容
            id notif = notifications.firstObject;
            return [notif valueForKey:@"_title"] ?: @"";
        }
        
        // 多条通知，生成摘要
        return [NSString stringWithFormat:@"%@ (%lu条通知)", 
                [self getAppNameForBundleID:bundleID], 
                (unsigned long)notifications.count];
    }
}

- (NSString *)getAppNameForBundleID:(NSString *)bundleID {
    // 尝试获取App名称
    NSDictionary *bundleInfo = [NSDictionary dictionaryWithContentsOfFile:
                                [NSString stringWithFormat:@"/var/containers/Bundle/Application/%@/Info.plist", bundleID]];
    if (bundleInfo) {
        return bundleInfo[@"CFBundleDisplayName"] ?: bundleInfo[@"CFBundleName"] ?: bundleID;
    }
    return bundleID;
}

- (void)clearNotificationsForBundleID:(NSString *)bundleID {
    @synchronized (self) {
        [_groupedNotifications removeObjectForKey:bundleID];
        [_lastNotificationTime removeObjectForKey:bundleID];
    }
}

@end

// ============================================
// Hook: 拦截通知
// ============================================

// iOS 17 通知中心相关类
// 尝试hook BBDataProvider (BaseBoard)
%hook BBDataProvider

- (void)addBulletin:(id)bulletin forSectionID:(NSString *)sectionID {
    NGNotificationManager *manager = [NGNotificationManager sharedManager];
    
    if ([manager shouldAggregateNotificationFromApp:sectionID]) {
        // 检查是否在时间窗口内
        NSNumber *lastTime = manager.lastNotificationTime[sectionID];
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        
        if (lastTime && (now - lastTime.doubleValue < manager.aggregationWindow)) {
            // 在时间窗口内，聚合通知
            [manager addNotification:bulletin withBundleID:sectionID];
            
            // 修改通知标题为摘要
            NSString *summary = [manager getSummaryForBundleID:sectionID];
            if (summary) {
                [bulletin setValue:summary forKey:@"_title"];
            }
            
            // 可选：不显示原始通知，只显示聚合后的
            // return;  // 取消这行以显示聚合通知
        } else {
            // 超出时间窗口，清除旧通知，重新开始
            [manager clearNotificationsForBundleID:sectionID];
            [manager addNotification:bulletin withBundleID:sectionID];
        }
    }
    
    %orig(bulletin, sectionID);
}

%end

// Hook NCNotificationRequest (iOS 17 通知请求)
%hook NCNotificationRequest

- (id)initWithBulletin:(id)bulletin sectionID:(NSString *)sectionID {
    NGNotificationManager *manager = [NGNotificationManager sharedManager];
    
    if ([manager shouldAggregateNotificationFromApp:sectionID]) {
        NSNumber *lastTime = manager.lastNotificationTime[sectionID];
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        
        if (lastTime && (now - lastTime.doubleValue < manager.aggregationWindow)) {
            [manager addNotification:bulletin withBundleID:sectionID];
        } else {
            [manager clearNotificationsForBundleID:sectionID];
            [manager addNotification:bulletin withBundleID:sectionID];
        }
    }
    
    return %orig(bulletin, sectionID);
}

%end

// Hook 通知视图控制器，修改显示
%hook NCNotificationViewController

- (void)loadView {
    %orig;
    
    // 可以在这里修改通知的UI显示
    NGNotificationManager *manager = [NGNotificationManager sharedManager];
    NSString *bundleID = [self valueForKey:@"_notificationRequest"] ? 
                         [[self valueForKey:@"_notificationRequest"] valueForKey:@"_sectionID"] : nil;
    
    if (bundleID && [manager shouldAggregateNotificationFromApp:bundleID]) {
        // 修改通知标题为聚合摘要
        NSString *summary = [manager getSummaryForBundleID:bundleID];
        if (summary) {
            // 尝试找到标题Label并修改
            UILabel *titleLabel = [self valueForKey:@"_titleLabel"];
            if (titleLabel) {
                titleLabel.text = summary;
            }
        }
    }
}

%end

// ============================================
// Preference Bundle Interface
// ============================================

@interface NotificationGrouperSettingsController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableDictionary *settings;
@end

@implementation NotificationGrouperSettingsController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"NotificationGrouper";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    
    // 加载设置
    _settings = [NSMutableDictionary dictionaryWithContentsOfFile:
                 @"/var/mobile/Library/Preferences/com.yourname.notificationgrouper.plist"];
    if (!_settings) {
        _settings = [NSMutableDictionary dictionary];
    }
    
    // 创建表格视图
    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    [self.view addSubview:_tableView];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 1;  // 开关
        case 1: return 1;  // 时间窗口
        case 2: return 1;  // 白名单
        default: return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"通用";
        case 1: return @"聚合设置";
        case 2: return @"白名单";
        default: return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"Cell"];
    }
    
    switch (indexPath.section) {
        case 0: {
            // 总开关
            cell.textLabel.text = @"启用通知归纳";
            UISwitch *switchView = [[UISwitch alloc] init];
            switchView.on = [_settings[@"enabled"] boolValue] ?: YES;
            [switchView addTarget:self action:@selector(toggleEnabled:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = switchView;
            break;
        }
        case 1: {
            // 时间窗口
            cell.textLabel.text = @"聚合时间窗口";
            NSNumber *window = _settings[@"aggregationWindow"] ?: @300;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f秒", window.doubleValue];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        }
        case 2: {
            // 白名单
            cell.textLabel.text = @"不聚合的应用";
            cell.detailTextLabel.text = @"点击管理";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        }
    }
    
    return cell;
}

- (void)toggleEnabled:(UISwitch *)sender {
    _settings[@"enabled"] = @(sender.on);
    [_settings writeToFile:@"/var/mobile/Library/Preferences/com.yourname.notificationgrouper.plist" atomically:YES];
    
    // 通知SpringBoard重新加载设置
    notify_post("com.yourname.notificationgrouper/settingsChanged");
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    if (indexPath.section == 1) {
        // 时间窗口设置
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"聚合时间窗口" 
                                                                     message:@"设置同一应用通知的聚合时间（秒）" 
                                                              preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
            textField.placeholder = @"300";
            textField.keyboardType = UIKeyboardTypeNumberPad;
            NSNumber *window = self.settings[@"aggregationWindow"] ?: @300;
            textField.text = [NSString stringWithFormat:@"%.0f", window.doubleValue];
        }];
        
        UIAlertAction *confirm = [UIAlertAction actionWithTitle:@"确定" 
                                                       style:UIAlertActionStyleDefault 
                                                     handler:^(UIAlertAction *action) {
            NSString *input = alert.textFields.firstObject.text;
            if (input.length > 0) {
                self.settings[@"aggregationWindow"] = @([input doubleValue]);
                [self.settings writeToFile:@"/var/mobile/Library/Preferences/com.yourname.notificationgrouper.plist" atomically:YES];
                [self.tableView reloadData];
                notify_post("com.yourname.notificationgrouper/settingsChanged");
            }
        }];
        
        UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" 
                                                      style:UIAlertActionStyleCancel 
                                                    handler:nil];
        
        [alert addAction:confirm];
        [alert addAction:cancel];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

@end

// 构造函数
%ctor {
    @autoreleasepool {
        // 加载偏好设置
        [[NGNotificationManager sharedManager] loadSettings];
        
        // 初始化日志
        NSLog(@"[NotificationGrouper] Loaded successfully");
    }
}
