// NotificationGrouper - iOS 17 通知归纳插件 (基于 Axon 架构)
// 功能: 按应用分组通知、聚合显示、摘要管理
// 适配: iOS 17.x (Dopamine/Palera1n rootless)

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============================================
// iOS 17 私有类接口声明 (让编译器认识这些方法)
// ============================================

// 通知请求
@interface NCNotificationRequest : NSObject
- (NSString *)sectionIdentifier;
- (NSString *)notificationIdentifier;
- (id)bulletin;
- (id)destinationBundleIdentifier;
- (NSDate *)timestamp;
@end

// 合并通知
@interface NCCoalescedNotification : NSObject
@property (nonatomic, readonly) NSArray *notificationRequests;
@end

// 通知内容
@interface NCNotificationContent : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *header;
@property (nonatomic, copy) NSString *subheader;
@property (nonatomic, strong) id icon;
@end

// 公报/Bulletin
@interface NCBulletinRequest : NSObject
@property (nonatomic, copy) NSString *sectionID;
@property (nonatomic, copy) NSString *title;
@end

// 通知分发器
@interface NCNotificationDispatcher : NSObject
- (id)notificationStore;
@end

// 通知存储
@interface NCNotificationStore : NSObject
- (NCCoalescedNotification *)coalescedNotificationForRequest:(NCNotificationRequest *)req;
@end

// 视图控制器
@interface NCNotificationCombinedListViewController : UIViewController
@property (nonatomic, assign) BOOL ngAllowChanges;
- (void)insertNotificationRequest:(NCNotificationRequest *)req forCoalescedNotification:(NCCoalescedNotification *)n;
- (void)removeNotificationRequest:(NCNotificationRequest *)req forCoalescedNotification:(NCCoalescedNotification *)n;
- (void)modifyNotificationRequest:(NCNotificationRequest *)req forCoalescedNotification:(NCCoalescedNotification *)n;
- (id)allNotificationRequests;
@end

@interface NCNotificationStructuredListViewController : UIViewController
@property (nonatomic, assign) BOOL ngAllowChanges;
- (void)insertNotificationRequest:(NCNotificationRequest *)req;
- (void)removeNotificationRequest:(NCNotificationRequest *)req;
- (void)modifyNotificationRequest:(NCNotificationRequest *)req;
- (id)allNotificationRequests;
@end

@interface NCNotificationSeparatorsListViewController : UIViewController
@property (nonatomic, strong, readonly) UIView *view;
@end

@interface NCNotificationListSectionHeaderView : UIView
@end

@interface NCNotificationListSectionRevealHintView : UIView
@end

// SpringBoard 图标
@interface SBIconModel : NSObject
- (id)applicationIconForBundleIdentifier:(NSString *)bundleID;
@end

@interface SBIconController : NSObject
+ (instancetype)sharedInstance;
- (id)homescreenIconViewMap;
- (id)model;
@end

@interface SBIcon : NSObject
- (id)getIconImage:(int)size;
- (id)iconImageWithInfo:(NSDictionary *)info;
@end

@interface SBIconViewMap : NSObject
- (SBIconModel *)iconModel;
@end

// ============================================
// 设置项
// ============================================
static BOOL ngEnabled = YES;
static BOOL ngGroupByApp = YES;
static NSInteger ngAggregationWindow = 300;
static NSInteger ngSortMode = 0;

static void loadPrefs() {
    NSDictionary *prefs = [[NSDictionary alloc] initWithContentsOfFile:@"/var/jb/Library/Preferences/com.yourname.notificationgrouper.plist"];
    if (!prefs) {
        prefs = [[NSDictionary alloc] initWithContentsOfFile:@"/var/mobile/Library/Preferences/com.yourname.notificationgrouper.plist"];
    }
    ngEnabled = prefs[@"Enabled"] != nil ? [prefs[@"Enabled"] boolValue] : YES;
    ngGroupByApp = prefs[@"GroupByApp"] != nil ? [prefs[@"GroupByApp"] boolValue] : YES;
    ngAggregationWindow = [prefs[@"AggregationWindow"] integerValue] ?: 300;
    ngSortMode = [prefs[@"SortMode"] integerValue] ?: 0;
}

// ============================================
// NGNotificationManager
// ============================================
@interface NGManager : NSObject
@property (nonatomic, strong) NSMutableDictionary *notificationRequests;
@property (nonatomic, strong) NSMutableDictionary *timestamps;
@property (nonatomic, strong) NSMutableDictionary *counts;
@property (nonatomic, strong) NSMutableDictionary *latestRequest;
@property (nonatomic, strong) NSMutableDictionary *names;
@property (nonatomic, strong) NCNotificationDispatcher *dispatcher;

+ (instancetype)sharedInstance;
- (NSString *)bundleIDForRequest:(NCNotificationRequest *)req;
- (NSDate *)timestampForRequest:(NCNotificationRequest *)req;
- (NSString *)nIDForRequest:(NCNotificationRequest *)req;
- (void)insertNotificationRequest:(NCNotificationRequest *)req;
- (void)removeNotificationRequest:(NCNotificationRequest *)req;
- (NSArray *)requestsForBundleIdentifier:(NSString *)bundleID;
- (NSInteger)countForBundleIdentifier:(NSString *)bundleID;
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

- (NSString *)bundleIDForRequest:(NCNotificationRequest *)req {
    if (!req) return nil;
    
    NSString *bundleID = [req sectionIdentifier];
    if (bundleID) return bundleID;
    
    NCBulletinRequest *bulletin = [req bulletin];
    if (bulletin) {
        bundleID = [bulletin sectionID];
        if (bundleID) return bundleID;
    }
    
    return [req destinationBundleIdentifier];
}

- (NSDate *)timestampForRequest:(NCNotificationRequest *)req {
    if (!req) return nil;
    return [req timestamp];
}

- (NSString *)nIDForRequest:(NCNotificationRequest *)req {
    if (!req) return nil;
    return [req notificationIdentifier];
}

- (void)clearRubble {
    for (NSString *bundleID in [self.notificationRequests allKeys]) {
        NSMutableArray *arr = self.notificationRequests[bundleID];
        for (NSInteger i = arr.count - 1; i >= 0; i--) {
            if (!arr[i]) [arr removeObjectAtIndex:i];
        }
    }
}

- (void)updateCountForBundleID:(NSString *)bundleID {
    [self clearRubble];
    NSArray *reqs = self.notificationRequests[bundleID];
    self.counts[bundleID] = @(reqs ? reqs.count : 0);
}

- (NSInteger)countForBundleIdentifier:(NSString *)bundleID {
    if (self.counts[bundleID]) return [self.counts[bundleID] integerValue];
    [self updateCountForBundleID:bundleID];
    return self.counts[bundleID] ? [self.counts[bundleID] integerValue] : 0;
}

- (UIImage *)iconForBundleIdentifier:(NSString *)bundleID {
    Class $SBIconController = objc_getClass("SBIconController");
    if (!$SBIconController) return nil;
    
    id ctrl = [$SBIconController performSelector:@selector(sharedInstance)];
    if (!ctrl) return nil;
    
    Class $SBIconViewMap = objc_getClass("SBIconViewMap");
    SBIconModel *model = nil;
    if ($SBIconViewMap && [ctrl respondsToSelector:@selector(homescreenIconViewMap)]) {
        id map = [ctrl homescreenIconViewMap];
        if (map && [map respondsToSelector:@selector(iconModel)]) {
            model = [map iconModel];
        }
    }
    if (!model && [ctrl respondsToSelector:@selector(model)]) {
        model = [ctrl model];
    if (!model) return nil;
    
    Class $SBIconModel = objc_getClass("SBIconModel");
    SBIcon *icon = nil;
    if ($SBIconModel && model && [model respondsToSelector:@selector(applicationIconForBundleIdentifier:)]) {
        icon = [model applicationIconForBundleIdentifier:bundleID];
    }
    
    if (icon) {
        if ([icon respondsToSelector:@selector(getIconImage:)]) {
            return [icon getIconImage:2];
        } else if ([icon respondsToSelector:@selector(iconImageWithInfo:)]) {
            return [icon iconImageWithInfo:@{@"size": @60.0, @"scale": @2.0}];
        }
    }
    return nil;
}

- (void)insertNotificationRequest:(NCNotificationRequest *)req {
    if (!req) return;
    
    NSString *bundleID = [self bundleIDForRequest:req];
    if (!bundleID) return;
    
    // 提取标题
    if ([req respondsToSelector:@selector(content)]) {
        NCNotificationContent *content = [req performSelector:@selector(content)];
        if (content && [content respondsToSelector:@selector(header)]) {
            NSString *h = [content header];
            if (h && [h isKindOfClass:[NSString class]]) {
                self.names[bundleID] = h;
            }
        }
    }
    
    // 记录时间戳
    NSDate *ts = [self timestampForRequest:req];
    if (ts) {
        if (!self.timestamps[bundleID] || [ts compare:self.timestamps[bundleID]] == NSOrderedDescending) {
            self.timestamps[bundleID] = ts;
        }
    }
    
    // 记录最新请求
    NSDate *latestTS = [self timestampForRequest:self.latestRequest[bundleID]];
    if (!latestTS || (ts && [ts compare:latestTS] == NSOrderedDescending)) {
        self.latestRequest[bundleID] = req;
    }
    
    [self clearRubble];
    
    NSString *nid = [self nIDForRequest:req];
    if (self.notificationRequests[bundleID]) {
        BOOL found = NO;
        if (nid) {
            for (NCNotificationRequest *existing in self.notificationRequests[bundleID]) {
                if ([[self nIDForRequest:existing] isEqualToString:nid]) {
                    found = YES;
                    break;
                }
            }
        }
        if (!found) [self.notificationRequests[bundleID] addObject:req];
    } else {
        self.notificationRequests[bundleID] = [NSMutableArray arrayWithObject:req];
    }
    
    [self updateCountForBundleID:bundleID];
}

- (void)removeNotificationRequest:(NCNotificationRequest *)req {
    if (!req) return;
    
    NSString *bundleID = [self bundleIDForRequest:req];
    if (!bundleID) return;
    
    NSString *nid = [self nIDForRequest:req];
    if (self.latestRequest[bundleID] && nid && [[self nIDForRequest:self.latestRequest[bundleID]] isEqualToString:nid]) {
        self.latestRequest[bundleID] = nil;
    }
    
    [self clearRubble];
    
    if (self.notificationRequests[bundleID] && nid) {
        NSMutableArray *arr = self.notificationRequests[bundleID];
        for (NSInteger i = arr.count - 1; i >= 0; i--) {
            NCNotificationRequest *existing = arr[i];
            if ([[self nIDForRequest:existing] isEqualToString:nid]) {
                [arr removeObjectAtIndex:i];
            }
        }
    }
    
    [self updateCountForBundleID:bundleID];
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
- (void)configWithBundleID:(NSString *)bundleID count:(NSInteger)count;
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

- (void)configWithBundleID:(NSString *)bundleID count:(NSInteger)count {
    NGManager *mgr = [NGManager sharedInstance];
    _iconView.image = [mgr iconForBundleIdentifier:bundleID] ?: [UIImage systemImageNamed:@"app.fill"];
    _nameLabel.text = mgr.names[bundleID] ?: bundleID;
    
    if (count > 1) {
        _countBadge.hidden = NO;
        _countBadge.text = count > 99 ? @"99+" : [NSString stringWithFormat:@" %ld ", (long)count];
    } else {
        _countBadge.hidden = YES;
    }
}

@end

// ============================================
// NGView - 侧边栏
// ============================================
@interface NGView : UIView <UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout>
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) NSMutableArray *sortedBundleIDs;
@property (nonatomic, assign) BOOL isExpanded;
- (void)refresh;
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
    NSMutableArray *allBundleIDs = [[mgr.notificationRequests allKeys] mutableCopy];
    
    if (ngSortMode == 0) {
        [allBundleIDs sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSDate *ta = mgr.timestamps[a];
            NSDate *tb = mgr.timestamps[b];
            if (!ta) return NSOrderedDescending;
            if (!tb) return NSOrderedAscending;
            return [tb compare:ta];
        }];
    } else {
        [allBundleIDs sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSInteger ca = [mgr countForBundleIdentifier:a];
            NSInteger cb = [mgr countForBundleIdentifier:b];
            return cb > ca ? NSOrderedAscending : (cb < ca ? NSOrderedDescending : NSOrderedSame);
        }];
    }
    
    self.sortedBundleIDs = allBundleIDs;
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
    NSString *bundleID = self.sortedBundleIDs[indexPath.item];
    [cell configWithBundleID:bundleID count:[[NGManager sharedInstance] countForBundleIdentifier:bundleID]];
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    NSLog(@"[NotificationGrouper] Tapped: %@", self.sortedBundleIDs[indexPath.item]);
}

@end

// ============================================
// iOS 17 Hook
// ============================================
%group NotificationGrouperiOS17

static NGView *ngBadgeView = nil;
static BOOL ngViewInited = NO;

%hook NCNotificationSeparatorsListViewController
- (void)viewDidLoad {
    %orig;
    if (!ngViewInited && ngEnabled) {
        ngViewInited = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ngBadgeView) {
                ngBadgeView = [[NGView alloc] initWithFrame:CGRectMake(0, 0, 44, self.view.bounds.size.height)];
                [self.view addSubview:ngBadgeView];
                NSLog(@"[NotificationGrouper] NGView added");
            }
        });
    }
}
%end

%hook NCNotificationCombinedListViewController

%property (nonatomic, assign) BOOL ngAllowChanges;

- (instancetype)init {
    id result = %orig;
    self.ngAllowChanges = NO;
    return result;
}

- (bool)insertNotificationRequest:(NCNotificationRequest *)req forCoalescedNotification:(NCCoalescedNotification *)n {
    if (!self.ngAllowChanges && ngEnabled) {
        [[NGManager sharedInstance] insertNotificationRequest:req];
        dispatch_async(dispatch_get_main_queue(), ^{ [ngBadgeView refresh]; });
    }
    return %orig;
}

- (bool)removeNotificationRequest:(NCNotificationRequest *)req forCoalescedNotification:(NCCoalescedNotification *)n {
    if (!self.ngAllowChanges && ngEnabled) {
        [[NGManager sharedInstance] removeNotificationRequest:req];
        dispatch_async(dispatch_get_main_queue(), ^{ [ngBadgeView refresh]; });
    }
    return %orig;
}

- (bool)modifyNotificationRequest:(NCNotificationRequest *)req forCoalescedNotification:(NCCoalescedNotification *)n {
    if (!self.ngAllowChanges && ngEnabled) {
        [[NGManager sharedInstance] removeNotificationRequest:req];
        [[NGManager sharedInstance] insertNotificationRequest:req];
        dispatch_async(dispatch_get_main_queue(), ^{ [ngBadgeView refresh]; });
    }
    return %orig;
}

%end

%hook NCNotificationStructuredListViewController

%property (nonatomic, assign) BOOL ngAllowChanges;

- (instancetype)init {
    id result = %orig;
    self.ngAllowChanges = NO;
    return result;
}

- (bool)insertNotificationRequest:(NCNotificationRequest *)req {
    if (!self.ngAllowChanges && ngEnabled) {
        [[NGManager sharedInstance] insertNotificationRequest:req];
        dispatch_async(dispatch_get_main_queue(), ^{ [ngBadgeView refresh]; });
    }
    return %orig;
}

- (bool)removeNotificationRequest:(NCNotificationRequest *)req {
    if (!self.ngAllowChanges && ngEnabled) {
        [[NGManager sharedInstance] removeNotificationRequest:req];
        dispatch_async(dispatch_get_main_queue(), ^{ [ngBadgeView refresh]; });
    }
    return %orig;
}

- (bool)modifyNotificationRequest:(NCNotificationRequest *)req {
    if (!self.ngAllowChanges && ngEnabled) {
        [[NGManager sharedInstance] removeNotificationRequest:req];
        [[NGManager sharedInstance] insertNotificationRequest:req];
        dispatch_async(dispatch_get_main_queue(), ^{ [ngBadgeView refresh]; });
    }
    return %orig;
}

%end

// 隐藏分组标题
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
            if (txt && [txt.lowercaseString containsString:@"older"]) {
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
        NSLog(@"[NotificationGrouper] Hooks initialized");
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
