// NotificationGrouper - iOS 17 通知归纳插件 (基于 Axon 架构)
// 功能: 按应用分组通知、聚合显示、摘要管理
// 适配: iOS 17.x (Dopamine/Palera1n rootless)

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============================================
// 设置项定义
// ============================================
static BOOL ngEnabled = YES;
static BOOL ngGroupByApp = YES;
static NSInteger ngAggregationWindow = 300;
static NSInteger ngMaxCount = 99;
static NSInteger ngSortMode = 0;

static void loadPrefs() {
    NSDictionary *prefs = [[NSDictionary alloc] initWithContentsOfFile:@"/var/jb/Library/Preferences/com.yourname.notificationgrouper.plist"];
    if (!prefs) {
        prefs = [[NSDictionary alloc] initWithContentsOfFile:@"/var/mobile/Library/Preferences/com.yourname.notificationgrouper.plist"];
    }
    ngEnabled = prefs[@"Enabled"] != nil ? [prefs[@"Enabled"] boolValue] : YES;
    ngGroupByApp = prefs[@"GroupByApp"] != nil ? [prefs[@"GroupByApp"] boolValue] : YES;
    ngAggregationWindow = [prefs[@"AggregationWindow"] integerValue] ?: 300;
    ngMaxCount = [prefs[@"MaxCount"] integerValue] ?: 99;
    ngSortMode = [prefs[@"SortMode"] integerValue] ?: 0;
}

// ============================================
// NGNotificationManager - 通知管理器
// ============================================
@interface NGManager : NSObject
@property (nonatomic, strong) NSMutableDictionary *notificationRequests;
@property (nonatomic, strong) NSMutableDictionary *timestamps;
@property (nonatomic, strong) NSMutableDictionary *counts;
@property (nonatomic, strong) NSMutableDictionary *latestRequest;
@property (nonatomic, strong) NSMutableDictionary *names;
@property (nonatomic, strong) id dispatcher;

+ (instancetype)sharedInstance;
- (void)insertNotificationRequest:(id)req;
- (void)removeNotificationRequest:(id)req;
- (NSArray *)requestsForBundleIdentifier:(NSString *)bundleID;
- (NSInteger)countForBundleIdentifier:(NSString *)bundleID;
- (NSString *)summaryForBundleIdentifier:(NSString *)bundleID;
- (UIImage *)iconForBundleIdentifier:(NSString *)bundleID;
- (void)clearAll;
- (NSString *)getBundleIDFromRequest:(id)req;
@end

@implementation NGManager

+ (instancetype)sharedInstance {
    static NGManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[NGManager alloc] init];
        shared.notificationRequests = [NSMutableDictionary new];
        shared.timestamps = [NSMutableDictionary new];
        shared.counts = [NSMutableDictionary new];
        shared.latestRequest = [NSMutableDictionary new];
        shared.names = [NSMutableDictionary new];
    });
    return shared;
}

- (void)clearRubble {
    for (NSString *bundleID in [self.notificationRequests allKeys]) {
        NSMutableArray *requests = self.notificationRequests[bundleID];
        for (NSInteger i = requests.count - 1; i >= 0; i--) {
            if (!requests[i]) [requests removeObjectAtIndex:i];
        }
    }
}

- (NSString *)getBundleIDFromRequest:(id)req {
    if (!req) return nil;
    
    // 尝试多种方式获取 bundleID (iOS 17 兼容性)
    NSString *bundleID = nil;
    
    // 方式1: sectionIdentifier
    if ([req respondsToSelector:@selector(sectionIdentifier)]) {
        bundleID = [req sectionIdentifier];
    }
    
    // 方式2: bulletin.sectionID
    if (!bundleID && [req respondsToSelector:@selector(bulletin)]) {
        id bulletin = [req bulletin];
        if (bulletin && [bulletin respondsToSelector:@selector(sectionID)]) {
            bundleID = [bulletin sectionID];
        }
    }
    
    // 方式3: destinationBundleIdentifier
    if (!bundleID && [req respondsToSelector:@selector(destinationBundleIdentifier)]) {
        bundleID = [req destinationBundleIdentifier];
    }
    
    // 方式4: 其他可能的属性
    if (!bundleID && [req respondsToSelector:@selector(valueForKey:)]) {
        bundleID = [req valueForKey:@"sectionID"];
    }
    
    return bundleID;
}

- (NSDate *)getTimestampFromRequest:(id)req {
    if (!req) return nil;
    if ([req respondsToSelector:@selector(timestamp)]) {
        return [req timestamp];
    }
    return nil;
}

- (NSString *)getNotificationID:(id)req {
    if (!req) return nil;
    if ([req respondsToSelector:@selector(notificationIdentifier)]) {
        return [req notificationIdentifier];
    }
    if ([req respondsToSelector:@selector(valueForKey:)]) {
        id val = [req valueForKey:@"notificationIdentifier"];
        if ([val isKindOfClass:[NSString class]]) return val;
    }
    return nil;
}

- (void)updateCountForBundleIdentifier:(NSString *)bundleID {
    NSArray *requests = [self requestsForBundleIdentifier:bundleID];
    self.counts[bundleID] = @(requests.count);
}

- (NSInteger)countForBundleIdentifier:(NSString *)bundleID {
    if (self.counts[bundleID]) return [self.counts[bundleID] integerValue];
    [self updateCountForBundleIdentifier:bundleID];
    return self.counts[bundleID] ? [self.counts[bundleID] integerValue] : 0;
}

- (NSString *)summaryForBundleIdentifier:(NSString *)bundleID {
    NSInteger count = [self countForBundleIdentifier:bundleID];
    if (count == 0) return nil;
    
    NSString *name = self.names[bundleID];
    if (!name) name = bundleID;
    
    if (count == 1) {
        NSArray *reqs = [self requestsForBundleIdentifier:bundleID];
        if (reqs.count > 0) {
            id req = reqs.firstObject;
            // 尝试获取标题
            if ([req respondsToSelector:@selector(valueForKey:)]) {
                NSString *title = [req valueForKey:@"effectiveContentText"];
                if (title && [title length] > 0) return title;
            }
        }
        return name;
    }
    
    return [NSString stringWithFormat:@"%@ (%ld条)", name, (long)count];
}

- (UIImage *)iconForBundleIdentifier:(NSString *)bundleID {
    // 使用私有 API 获取应用图标
    Class $SBIconModel = objc_getClass("SBIconModel");
    Class $SBIconController = objc_getClass("SBIconController");
    
    if ($SBIconController) {
        id iconController = [$SBIconController performSelector:@selector(sharedInstance)];
        if (iconController) {
            id model = nil;
            if ([iconController respondsToSelector:@selector(homescreenIconViewMap)]) {
                id map = [iconController homescreenIconViewMap];
                if (map && [map respondsToSelector:@selector(iconModel)]) {
                    model = [map iconModel];
                }
            } else if ([iconController respondsToSelector:@selector(model)]) {
                model = [iconController model];
            }
            
            if (model && [model respondsToSelector:@selector(applicationIconForBundleIdentifier:)]) {
                id icon = [model applicationIconForBundleIdentifier:bundleID];
                if (icon) {
                    if ([icon respondsToSelector:@selector(getIconImage:)]) {
                        return [icon getIconImage:2];
                    } else if ([icon respondsToSelector:@selector(iconImageWithInfo:)]) {
                        return [icon iconImageWithInfo:@{@"size": @60.0, @"scale": @2.0}];
                    }
                }
            }
        }
    }
    
    return nil;
}

- (void)insertNotificationRequest:(id)req {
    if (!req) return;
    
    NSString *bundleID = [self getBundleIDFromRequest:req];
    if (!bundleID) return;
    
    // 存储应用名称
    if ([req respondsToSelector:@selector(valueForKey:)]) {
        NSString *header = [req valueForKey:@"effectiveContentText"];
        if (!header) header = [req valueForKey:@"headerText"];
        if (header && [header isKindOfClass:[NSString class]]) {
            self.names[bundleID] = header;
        }
    }
    
    // 存储时间戳
    NSDate *ts = [self getTimestampFromRequest:req];
    if (ts) {
        if (!self.timestamps[bundleID] || [ts compare:self.timestamps[bundleID]] == NSOrderedDescending) {
            self.timestamps[bundleID] = ts;
        }
    }
    
    // 记录最新请求
    NSDate *existingTS = [self getTimestampFromRequest:self.latestRequest[bundleID]];
    if (!existingTS || (ts && [ts compare:existingTS] == NSOrderedDescending)) {
        self.latestRequest[bundleID] = req;
    }
    
    [self clearRubble];
    
    if (self.notificationRequests[bundleID]) {
        NSString *reqID = [self getNotificationID:req];
        BOOL found = NO;
        if (reqID) {
            for (NSInteger i = 0; i < [self.notificationRequests[bundleID] count]; i++) {
                id existing = self.notificationRequests[bundleID][i];
                NSString *existingID = [self getNotificationID:existing];
                if (existingID && [reqID isEqualToString:existingID]) {
                    found = YES;
                    break;
                }
            }
        }
        if (!found) [self.notificationRequests[bundleID] addObject:req];
    } else {
        self.notificationRequests[bundleID] = [NSMutableArray arrayWithObject:req];
    }
    
    [self updateCountForBundleIdentifier:bundleID];
}

- (void)removeNotificationRequest:(id)req {
    if (!req) return;
    
    NSString *bundleID = [self getBundleIDFromRequest:req];
    if (!bundleID) return;
    
    NSString *reqID = [self getNotificationID:req];
    if (self.latestRequest[bundleID] && reqID && [reqID isEqualToString:[self getNotificationID:self.latestRequest[bundleID]]]) {
        self.latestRequest[bundleID] = nil;
    }
    
    [self clearRubble];
    
    if (self.notificationRequests[bundleID] && reqID) {
        NSMutableArray *requests = self.notificationRequests[bundleID];
        for (NSInteger i = requests.count - 1; i >= 0; i--) {
            id existing = requests[i];
            NSString *existingID = [self getNotificationID:existing];
            if (existingID && [reqID isEqualToString:existingID]) {
                [requests removeObjectAtIndex:i];
            }
        }
    }
    
    [self updateCountForBundleIdentifier:bundleID];
}

- (NSArray *)requestsForBundleIdentifier:(NSString *)bundleID {
    [self clearRubble];
    return self.notificationRequests[bundleID] ?: @[];
}

- (void)clearAll {
    [self.notificationRequests removeAllObjects];
    [self.timestamps removeAllObjects];
    [self.counts removeAllObjects];
    [self.latestRequest removeAllObjects];
    [self.names removeAllObjects];
}

@end

// ============================================
// NGViewCell - 分组徽章单元格
// ============================================
@interface NGViewCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *countBadge;
@property (nonatomic, strong) UILabel *nameLabel;
@end

@implementation NGViewCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _iconView = [[UIImageView alloc] initWithFrame:CGRectMake(4, 4, 36, 36)];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.layer.cornerRadius = 8;
        _iconView.clipsToBounds = YES;
        _iconView.backgroundColor = [UIColor systemGray5Color];
        [self.contentView addSubview:_iconView];
        
        _countBadge = [[UILabel alloc] initWithFrame:CGRectMake(4, 38, 36, 16)];
        _countBadge.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
        _countBadge.textAlignment = NSTextAlignmentCenter;
        _countBadge.textColor = [UIColor whiteColor];
        _countBadge.backgroundColor = [UIColor systemRedColor];
        _countBadge.layer.cornerRadius = 8;
        _countBadge.clipsToBounds = YES;
        _countBadge.adjustsFontSizeToFitWidth = YES;
        _countBadge.minimumScaleFactor = 0.5;
        [self.contentView addSubview:_countBadge];
        
        _nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 58, 44, 22)];
        _nameLabel.font = [UIFont systemFontOfSize:9 weight:UIFontWeightMedium];
        _nameLabel.textAlignment = NSTextAlignmentCenter;
        _nameLabel.numberOfLines = 2;
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _nameLabel.textColor = [UIColor labelColor];
        [self.contentView addSubview:_nameLabel];
    }
    return self;
}

- (void)configureWithBundleID:(NSString *)bundleID count:(NSInteger)count name:(NSString *)name icon:(UIImage *)icon {
    _iconView.image = icon ?: [UIImage systemImageNamed:@"app.fill"];
    _nameLabel.text = name ?: bundleID;
    
    if (count > 1) {
        _countBadge.hidden = NO;
        _countBadge.text = count > 99 ? @"99+" : [NSString stringWithFormat:@" %ld ", (long)count];
    } else {
        _countBadge.hidden = YES;
    }
}

@end

// ============================================
// NGView - 通知分组侧边栏视图
// ============================================
@interface NGView : UIView <UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout>
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) NSMutableArray *sortedBundleIDs;
@property (nonatomic, assign) BOOL isExpanded;
@end

@implementation NGView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _sortedBundleIDs = [NSMutableArray new];
        self.backgroundColor = [UIColor clearColor];
        
        UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
        layout.scrollDirection = UICollectionViewScrollDirectionVertical;
        layout.minimumInteritemSpacing = 4;
        layout.minimumLineSpacing = 6;
        layout.sectionInset = UIEdgeInsetsMake(8, 0, 8, 0);
        layout.itemSize = CGSizeMake(44, 80);
        
        _collectionView = [[UICollectionView alloc] initWithFrame:self.bounds collectionViewLayout:layout];
        _collectionView.backgroundColor = [UIColor clearColor];
        _collectionView.dataSource = self;
        _collectionView.delegate = self;
        _collectionView.showsVerticalScrollIndicator = NO;
        [_collectionView registerClass:[NGViewCell class] forCellWithReuseIdentifier:@"NGCell"];
        [self addSubview:_collectionView];
        
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleExpand)];
        [self addGestureRecognizer:tap];
        
        self.alpha = 0.8;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.collectionView.frame = self.bounds;
}

- (void)refresh {
    NGManager *mgr = [NGManager sharedInstance];
    NSArray *allBundleIDs = [[mgr.notificationRequests allKeys] copy];
    
    if (ngSortMode == 0) {
        allBundleIDs = [allBundleIDs sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSDate *ta = mgr.timestamps[a];
            NSDate *tb = mgr.timestamps[b];
            if (!ta) return NSOrderedDescending;
            if (!tb) return NSOrderedAscending;
            return [tb compare:ta];
        }];
    } else {
        allBundleIDs = [allBundleIDs sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSInteger ca = [mgr countForBundleIdentifier:a];
            NSInteger cb = [mgr countForBundleIdentifier:b];
            return cb > ca ? NSOrderedAscending : (cb < ca ? NSOrderedDescending : NSOrderedSame);
        }];
    }
    
    self.sortedBundleIDs = [allBundleIDs mutableCopy];
    [self.collectionView reloadData];
}

- (void)toggleExpand {
    self.isExpanded = !self.isExpanded;
    [UIView animateWithDuration:0.2 animations:^{
        self.alpha = self.isExpanded ? 1.0 : 0.6;
    }];
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.sortedBundleIDs.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    NGViewCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"NGCell" forIndexPath:indexPath];
    NGManager *mgr = [NGManager sharedInstance];
    NSString *bundleID = self.sortedBundleIDs[indexPath.item];
    NSInteger count = [mgr countForBundleIdentifier:bundleID];
    NSString *name = mgr.names[bundleID];
    UIImage *icon = [mgr iconForBundleIdentifier:bundleID];
    [cell configureWithBundleID:bundleID count:count name:name icon:icon];
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    NSString *bundleID = self.sortedBundleIDs[indexPath.item];
    NSLog(@"[NotificationGrouper] Tapped: %@", bundleID);
}

@end

// ============================================
// iOS 17 通知列表 Hook
// ============================================
%group NotificationGrouperiOS17

static NGView *ngBadgeView = nil;
static BOOL ngViewInitialized = NO;

%hook NCNotificationSeparatorsListViewController

- (void)viewDidLoad {
    %orig;
    if (!ngViewInitialized && ngEnabled) {
        ngViewInitialized = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ngBadgeView && self.view) {
                ngBadgeView = [[NGView alloc] initWithFrame:CGRectMake(0, 0, 44, self.view.bounds.size.height)];
                [self.view addSubview:ngBadgeView];
                NSLog(@"[NotificationGrouper] NGView added to NCNotificationSeparatorsListViewController");
            }
        });
    }
}

%end

// iOS 17 通知主列表
%hook NCNotificationCombinedListViewController

%property (nonatomic, assign) BOOL ngAllowChanges;

- (instancetype)init {
    id orig = %orig;
    self.ngAllowChanges = NO;
    return orig;
}

- (bool)insertNotificationRequest:(id)req forCoalescedNotification:(id)arg2 {
    if (!self.ngAllowChanges && ngEnabled) {
        [[NGManager sharedInstance] insertNotificationRequest:req];
        dispatch_async(dispatch_get_main_queue(), ^{
            [ngBadgeView refresh];
        });
    }
    return %orig;
}

- (bool)removeNotificationRequest:(id)req forCoalescedNotification:(id)arg2 {
    if (!self.ngAllowChanges && ngEnabled) {
        [[NGManager sharedInstance] removeNotificationRequest:req];
        dispatch_async(dispatch_get_main_queue(), ^{
            [ngBadgeView refresh];
        });
    }
    return %orig;
}

- (bool)modifyNotificationRequest:(id)req forCoalescedNotification:(id)arg2 {
    if (!self.ngAllowChanges && ngEnabled) {
        [[NGManager sharedInstance] removeNotificationRequest:req];
        [[NGManager sharedInstance] insertNotificationRequest:req];
        dispatch_async(dispatch_get_main_queue(), ^{
            [ngBadgeView refresh];
        });
    }
    return %orig;
}

%end

// iOS 17 结构化列表
%hook NCNotificationStructuredListViewController

%property (nonatomic, assign) BOOL ngAllowChanges;

- (instancetype)init {
    id orig = %orig;
    self.ngAllowChanges = NO;
    return orig;
}

- (bool)insertNotificationRequest:(id)req {
    if (!self.ngAllowChanges && ngEnabled) {
        [[NGManager sharedInstance] insertNotificationRequest:req];
        dispatch_async(dispatch_get_main_queue(), ^{
            [ngBadgeView refresh];
        });
    }
    return %orig;
}

- (bool)removeNotificationRequest:(id)req {
    if (!self.ngAllowChanges && ngEnabled) {
        [[NGManager sharedInstance] removeNotificationRequest:req];
        dispatch_async(dispatch_get_main_queue(), ^{
            [ngBadgeView refresh];
        });
    }
    return %orig;
}

- (bool)modifyNotificationRequest:(id)req {
    if (!self.ngAllowChanges && ngEnabled) {
        [[NGManager sharedInstance] removeNotificationRequest:req];
        [[NGManager sharedInstance] insertNotificationRequest:req];
        dispatch_async(dispatch_get_main_queue(), ^{
            [ngBadgeView refresh];
        });
    }
    return %orig;
}

%end

// 隐藏分组标题 (让通知列表更简洁)
%hook NCNotificationListSectionHeaderView

- (void)layoutSubviews {
    %orig;
    self.hidden = YES;
}

- (CGRect)frame {
    return CGRectZero;
}

%end

// 隐藏"没有更早通知"
%hook NCNotificationListSectionRevealHintView

- (void)layoutSubviews {
    %orig;
    for (UIView *sub in self.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) {
            UILabel *lbl = (UILabel *)sub;
            NSString *txt = lbl.text;
            if (txt && ([txt.lowercaseString containsString:@"older"] || [txt containsString:@"更早"])) {
                lbl.hidden = YES;
            }
        }
    }
}

%end

%end

// ============================================
// 构造函数
// ============================================
%ctor {
    NSLog(@"[NotificationGrouper] Loading...");
    loadPrefs();
    
    if (ngEnabled) {
        %init(NotificationGrouperiOS17);
        NSLog(@"[NotificationGrouper] iOS 17 hooks initialized");
    }
    
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        (CFNotificationCallback)loadPrefs,
        CFSTR("com.yourname.notificationgrouper/ReloadPrefs"),
        NULL,
        CFNotificationSuspensionBehaviorCoalesce
    );
}
