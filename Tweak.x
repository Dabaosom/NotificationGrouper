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
static NSInteger ngAggregationWindow = 300; // 秒
static NSInteger ngMaxCount = 99;
static NSInteger ngSortMode = 0; // 0=最新优先, 1=数量优先

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
// NCNotificationRequest 前向声明
// ============================================
@class NCNotificationRequest;
@class NCCoalescedNotification;

@interface NSObject (NCTimestamp)
- (NSDate *)timestamp;
@end

// ============================================
// NGNotificationManager - 通知管理器
// ============================================
@interface NGManager : NSObject
@property (nonatomic, strong) NSMutableDictionary *notificationRequests; // bundleID -> NSMutableArray of requests
@property (nonatomic, strong) NSMutableDictionary *timestamps;           // bundleID -> NSDate
@property (nonatomic, strong) NSMutableDictionary *counts;                // bundleID -> count
@property (nonatomic, strong) NSMutableDictionary *latestRequest;         // bundleID -> NCNotificationRequest
@property (nonatomic, strong) NSMutableDictionary *names;                // bundleID -> header string
@property (nonatomic, strong) id dispatcher;

+ (instancetype)sharedInstance;
- (void)insertNotificationRequest:(NCNotificationRequest *)req;
- (void)removeNotificationRequest:(NCNotificationRequest *)req;
- (NSArray *)requestsForBundleIdentifier:(NSString *)bundleID;
- (NSInteger)countForBundleIdentifier:(NSString *)bundleID;
- (NSString *)summaryForBundleIdentifier:(NSString *)bundleID;
- (UIImage *)iconForBundleIdentifier:(NSString *)bundleID;
- (void)clearAll;
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
        // 单条通知，获取实际内容
        NSArray *reqs = [self requestsForBundleIdentifier:bundleID];
        if (reqs.count > 0) {
            id req = reqs.firstObject;
            if ([req respondsToSelector:@selector(content)]) {
                id content = [req content];
                if ([content respondsToSelector:@selector(title)]) {
                    NSString *title = [content title];
                    if (title) return title;
                }
            }
        }
        return name;
    }
    
    return [NSString stringWithFormat:@"%@ (%ld条)", name, (long)count];
}

- (UIImage *)iconForBundleIdentifier:(NSString *)bundleID {
    return [UIImage _applicationIconImageForBundleIdentifier:bundleID format:0 scale:[UIScreen mainScreen].scale];
}

- (void)insertNotificationRequest:(NCNotificationRequest *)req {
    if (!req || ![req respondsToSelector:@selector(notificationIdentifier)]) return;
    
    NSString *bundleID = nil;
    
    // iOS 17: 多种方式获取 bundleID
    if ([req respondsToSelector:@selector(sectionIdentifier)]) {
        bundleID = [req sectionIdentifier];
    }
    if (!bundleID && [req respondsToSelector:@selector(bulletin)]) {
        id bulletin = [req bulletin];
        if ([bulletin respondsToSelector:@selector(sectionID)]) {
            bundleID = [bulletin sectionID];
        }
    }
    if (!bundleID && [req respondsToSelector:@selector(destinationBundleIdentifier)]) {
        bundleID = [req destinationBundleIdentifier];
    }
    if (!bundleID) return;
    
    // 存储应用名称
    if ([req respondsToSelector:@selector(content)]) {
        id content = [req content];
        if ([content respondsToSelector:@selector(header)]) {
            NSString *header = [content header];
            if (header) self.names[bundleID] = header;
        }
    }
    
    // 存储时间戳
    if ([req respondsToSelector:@selector(timestamp)]) {
        NSDate *ts = [req timestamp];
        if (ts) {
            if (!self.timestamps[bundleID] || [ts compare:self.timestamps[bundleID]] == NSOrderedDescending) {
                self.timestamps[bundleID] = ts;
            }
        }
    }
    
    // 记录最新请求
    if (!self.latestRequest[bundleID] || 
        ([req respondsToSelector:@selector(timestamp)] && 
         [self.latestRequest[bundleID] respondsToSelector:@selector(timestamp)] &&
         [ts compare:[self.latestRequest[bundleID] timestamp]] == NSOrderedDescending)) {
        self.latestRequest[bundleID] = req;
    }
    
    [self clearRubble];
    
    if (self.notificationRequests[bundleID]) {
        BOOL found = NO;
        for (NSInteger i = 0; i < [self.notificationRequests[bundleID] count]; i++) {
            id existing = self.notificationRequests[bundleID][i];
            if (existing && [existing respondsToSelector:@selector(notificationIdentifier)] &&
                [[req notificationIdentifier] isEqualToString:[existing notificationIdentifier]]) {
                found = YES;
                break;
            }
        }
        if (!found) [self.notificationRequests[bundleID] addObject:req];
    } else {
        self.notificationRequests[bundleID] = [NSMutableArray arrayWithObject:req];
    }
    
    [self updateCountForBundleIdentifier:bundleID];
}

- (void)removeNotificationRequest:(NCNotificationRequest *)req {
    if (!req || ![req respondsToSelector:@selector(notificationIdentifier)]) return;
    
    NSString *bundleID = nil;
    if ([req respondsToSelector:@selector(sectionIdentifier)]) {
        bundleID = [req sectionIdentifier];
    }
    if (!bundleID && [req respondsToSelector:@selector(bulletin)]) {
        id bulletin = [req bulletin];
        if ([bulletin respondsToSelector:@selector(sectionID)]) {
            bundleID = [bulletin sectionID];
        }
    }
    if (!bundleID && [req respondsToSelector:@selector(destinationBundleIdentifier)]) {
        bundleID = [req destinationBundleIdentifier];
    }
    if (!bundleID) return;
    
    if (self.latestRequest[bundleID] && 
        [[req notificationIdentifier] isEqualToString:[self.latestRequest[bundleID] notificationIdentifier]]) {
        self.latestRequest[bundleID] = nil;
    }
    
    [self clearRubble];
    
    if (self.notificationRequests[bundleID]) {
        NSMutableArray *requests = self.notificationRequests[bundleID];
        for (NSInteger i = requests.count - 1; i >= 0; i--) {
            id existing = requests[i];
            if (existing && [existing respondsToSelector:@selector(notificationIdentifier)] &&
                [[req notificationIdentifier] isEqualToString:[existing notificationIdentifier]]) {
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
// NGView - 自定义通知分组视图
// ============================================
@interface NGViewCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UIImageView *chevron;
@end

@implementation NGViewCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _iconView = [[UIImageView alloc] initWithFrame:CGRectMake(8, 8, 36, 36)];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.layer.cornerRadius = 8;
        _iconView.clipsToBounds = YES;
        [self.contentView addSubview:_iconView];
        
        _countLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 46, 36, 14)];
        _countLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        _countLabel.textAlignment = NSTextAlignmentCenter;
        _countLabel.textColor = [UIColor whiteColor];
        _countLabel.backgroundColor = [UIColor systemRedColor];
        _countLabel.layer.cornerRadius = 7;
        _countLabel.clipsToBounds = YES;
        [self.contentView addSubview:_countLabel];
        
        _nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 64, 52, 20)];
        _nameLabel.font = [UIFont systemFontOfSize:9 weight:UIFontWeightMedium];
        _nameLabel.textAlignment = NSTextAlignmentCenter;
        _nameLabel.numberOfLines = 2;
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.contentView addSubview:_nameLabel];
    }
    return self;
}

- (void)configureWithBundleID:(NSString *)bundleID count:(NSInteger)count {
    self.iconView.image = [[NGManager sharedInstance] iconForBundleIdentifier:bundleID];
    self.nameLabel.text = [[NGManager sharedInstance] names][bundleID] ?: bundleID;
    
    if (count > 0) {
        self.countLabel.hidden = NO;
        if (count > 99) count = 99;
        self.countLabel.text = [NSString stringWithFormat:@" %ld ", (long)count];
    } else {
        self.countLabel.hidden = YES;
    }
}

@end

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
        layout.minimumInteritemSpacing = 2;
        layout.minimumLineSpacing = 4;
        layout.itemSize = CGSizeMake(52, 84);
        
        _collectionView = [[UICollectionView alloc] initWithFrame:self.bounds collectionViewLayout:layout];
        _collectionView.backgroundColor = [UIColor clearColor];
        _collectionView.dataSource = self;
        _collectionView.delegate = self;
        _collectionView.showsVerticalScrollIndicator = NO;
        [_collectionView registerClass:[NGViewCell class] forCellWithReuseIdentifier:@"NGCell"];
        [self addSubview:_collectionView];
        
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleExpand)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.collectionView.frame = self.bounds;
}

- (void)refresh {
    NGManager *mgr = [NGManager sharedInstance];
    NSArray *allBundleIDs = [mgr.notificationRequests allKeys];
    
    // 排序
    if (ngSortMode == 0) {
        // 最新优先
        allBundleIDs = [allBundleIDs sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSDate *ta = mgr.timestamps[a];
            NSDate *tb = mgr.timestamps[b];
            if (!ta) return NSOrderedDescending;
            if (!tb) return NSOrderedAscending;
            return [tb compare:ta];
        }];
    } else {
        // 数量优先
        allBundleIDs = [allBundleIDs sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSInteger ca = [mgr countForBundleIdentifier:a];
            NSInteger cb = [mgr countForBundleIdentifier:b];
            if (ca > cb) return NSOrderedAscending;
            if (ca < cb) return NSOrderedDescending;
            return NSOrderedSame;
        }];
    }
    
    self.sortedBundleIDs = [allBundleIDs mutableCopy];
    [self.collectionView reloadData];
}

- (void)toggleExpand {
    self.isExpanded = !self.isExpanded;
    [UIView animateWithDuration:0.25 animations:^{
        if (self.isExpanded) {
            self.collectionView.alpha = 1.0;
        } else {
            self.collectionView.alpha = 0.6;
        }
    }];
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.sortedBundleIDs.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    NGViewCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"NGCell" forIndexPath:indexPath];
    NSString *bundleID = self.sortedBundleIDs[indexPath.item];
    [cell configureWithBundleID:bundleID count:[NGManager sharedInstance countForBundleIdentifier:bundleID]];
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    NSString *bundleID = self.sortedBundleIDs[indexPath.item];
    NSLog(@"[NotificationGrouper] Tapped on %@", bundleID);
}

@end

// ============================================
// iOS 17 通知列表控制器 Hook
// ============================================
%group NotificationGrouperiOS17

static NGView *ngBadgeView = nil;
static BOOL ngInitialized = NO;

// iOS 17 通知列表控制器
// iOS 17 使用 NCNotificationSeparatorsListViewController 和相关类
%hook NCNotificationSeparatorsListViewController

- (void)viewDidLoad {
    %orig;
    if (!ngInitialized && ngEnabled) {
        ngInitialized = YES;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ngBadgeView) {
                ngBadgeView = [[NGView alloc] initWithFrame:CGRectMake(0, 0, 52, 300)];
                ngBadgeView.isExpanded = NO;
                ngBadgeView.collectionView.alpha = 0.6;
            }
            
            // 尝试添加到视图
            UIView *view = self.view;
            if (view) {
                ngBadgeView.frame = CGRectMake(view.bounds.size.width - 56, 60, 52, view.bounds.size.height - 120);
                [view addSubview:ngBadgeView];
                NSLog(@"[NotificationGrouper] Badge view added to NCNotificationSeparatorsListViewController");
            }
        });
    }
}

%end

// Hook 通知插入
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

%end

// 通知结构化列表 (iOS 17 有些类使用这个)
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

%end

// 隐藏通知分组标题 (让通知看起来更简洁)
%hook NCNotificationListSectionHeaderView

- (void)layoutSubviews {
    %orig;
    self.hidden = YES;
}

- (CGRect)frame {
    CGRect orig = %orig;
    return CGRectZero;
}

%end

// 隐藏"没有旧通知"提示
%hook NCNotificationListSectionRevealHintView

- (void)layoutSubviews {
    %orig;
    for (UIView *subview in self.subviews) {
        if ([subview isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)subview;
            if ([label.text containsString:@"older"] || [label.text containsString:@"更早"]) {
                label.hidden = YES;
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
    
    // 监听设置变更
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        (CFNotificationCallback)loadPrefs,
        CFSTR("com.yourname.notificationgrouper/ReloadPrefs"),
        NULL,
        CFNotificationSuspensionBehaviorCoalesce
    );
}
