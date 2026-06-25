// NotificationGrouper - iOS 17 通知归纳插件 (基于 Axon 架构)
// 功能: 按应用分组通知、聚合显示、摘要管理
// 适配: iOS 17.x (Dopamine/Palera1n rootless)

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============================================
// 设置项 (放在所有代码之前，供 hooks 使用)
// ============================================
static BOOL ngEnabled = YES;
static BOOL ngGroupByApp = YES;
static NSInteger ngAggregationWindow = 300;
static NSInteger ngSortMode = 0;

// ============================================
// 私有类前向声明 (供 %hook 引用)
// ============================================
@class NCNotificationRequest;
@class NCCoalescedNotification;
@class NCNotificationContent;
@class NCBulletinRequest;
@class NCNotificationDispatcher;
@class NCNotificationStore;
@class SBIconModel;
@class SBIcon;
@class SBIconViewMap;

// ============================================
// NGManager 单例前向声明 (供 hooks 使用)
// ============================================
@interface NGManager : NSObject
+ (instancetype)sharedInstance;
- (NSString *)bundleIDForRequest:(id)req;
- (NSDate *)timestampForRequest:(id)req;
- (NSString *)nidForRequest:(id)req;
- (void)insertRequest:(id)req;
- (void)removeRequest:(id)req;
- (NSInteger)countForBundleID:(NSString *)bundleID;
- (UIImage *)iconForBundleID:(NSString *)bundleID;
- (NSString *)nameForBundleID:(NSString *)bundleID;
@end

@interface NGView : UIView
+ (void)refreshBadge;
@end

// ============================================
// HOOKS - 放在所有实现代码之前
// ============================================
%group NotificationGrouperiOS17

static NGManager *ngManager = nil;
static NGView *ngBadgeView = nil;
static BOOL ngBadgeInited = NO;

%hook NCNotificationSeparatorsListViewController
- (void)viewDidLoad {
    %orig;
    if (!ngBadgeInited && ngEnabled) {
        ngBadgeInited = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ngBadgeView && self.view) {
                ngBadgeView = [[NGView alloc] initWithFrame:CGRectMake(0, 0, 44, self.view.bounds.size.height)];
                [self.view addSubview:ngBadgeView];
                NSLog(@"[NotificationGrouper] Badge view added");
            }
        });
    }
}
%end

%hook NCNotificationCombinedListViewController
- (bool)insertNotificationRequest:(id)req forCoalescedNotification:(id)n {
    if (ngEnabled) {
        [[NGManager sharedInstance] insertRequest:req];
        dispatch_async(dispatch_get_main_queue(), ^{ [NGView refreshBadge]; });
    }
    return %orig;
}
- (bool)removeNotificationRequest:(id)req forCoalescedNotification:(id)n {
    if (ngEnabled) {
        [[NGManager sharedInstance] removeRequest:req];
        dispatch_async(dispatch_get_main_queue(), ^{ [NGView refreshBadge]; });
    }
    return %orig;
}
- (bool)modifyNotificationRequest:(id)req forCoalescedNotification:(id)n {
    if (ngEnabled) {
        [[NGManager sharedInstance] removeRequest:req];
        [[NGManager sharedInstance] insertRequest:req];
        dispatch_async(dispatch_get_main_queue(), ^{ [NGView refreshBadge]; });
    }
    return %orig;
}
%end

%hook NCNotificationStructuredListViewController
- (bool)insertNotificationRequest:(id)req {
    if (ngEnabled) {
        [[NGManager sharedInstance] insertRequest:req];
        dispatch_async(dispatch_get_main_queue(), ^{ [NGView refreshBadge]; });
    }
    return %orig;
}
- (bool)removeNotificationRequest:(id)req {
    if (ngEnabled) {
        [[NGManager sharedInstance] removeRequest:req];
        dispatch_async(dispatch_get_main_queue(), ^{ [NGView refreshBadge]; });
    }
    return %orig;
}
- (bool)modifyNotificationRequest:(id)req {
    if (ngEnabled) {
        [[NGManager sharedInstance] removeRequest:req];
        [[NGManager sharedInstance] insertRequest:req];
        dispatch_async(dispatch_get_main_queue(), ^{ [NGView refreshBadge]; });
    }
    return %orig;
}
%end

%hook NCNotificationListSectionHeaderView
- (void)layoutSubviews {
    %orig;
    self.hidden = YES;
}
- (CGRect)frame {
    return CGRectZero;
}
%end

%hook NCNotificationListSectionRevealHintView
- (void)layoutSubviews {
    %orig;
    for (UIView *sub in self.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) {
            UILabel *lbl = (UILabel *)sub;
            NSString *txt = lbl.text;
            if (txt && [txt.lowercaseString containsString:@"older"]) lbl.hidden = YES;
        }
    }
}
%end

%end

// ============================================
// 构造函数
// ============================================
%ctor {
    ngManager = [NGManager sharedInstance];
    NSLog(@"[NotificationGrouper] Loading...");
    
    // 加载设置
    NSDictionary *prefs = [[NSDictionary alloc] initWithContentsOfFile:@"/var/jb/Library/Preferences/com.yourname.notificationgrouper.plist"];
    if (!prefs) {
        prefs = [[NSDictionary alloc] initWithContentsOfFile:@"/var/mobile/Library/Preferences/com.yourname.notificationgrouper.plist"];
    }
    ngEnabled = prefs[@"Enabled"] != nil ? [prefs[@"Enabled"] boolValue] : YES;
    ngGroupByApp = prefs[@"GroupByApp"] != nil ? [prefs[@"GroupByApp"] boolValue] : YES;
    ngAggregationWindow = [prefs[@"AggregationWindow"] integerValue] ?: 300;
    ngSortMode = [prefs[@"SortMode"] integerValue] ?: 0;
    
    if (ngEnabled) {
        %init(NotificationGrouperiOS17);
        NSLog(@"[NotificationGrouper] Hooks initialized");
    }
    
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        (CFNotificationCallback)(^{
            NSDictionary *p = [[NSDictionary alloc] initWithContentsOfFile:@"/var/jb/Library/Preferences/com.yourname.notificationgrouper.plist"];
            if (!p) p = [[NSDictionary alloc] initWithContentsOfFile:@"/var/mobile/Library/Preferences/com.yourname.notificationgrouper.plist"];
            ngEnabled = p[@"Enabled"] != nil ? [p[@"Enabled"] boolValue] : YES;
            ngGroupByApp = p[@"GroupByApp"] != nil ? [p[@"GroupByApp"] boolValue] : YES;
            ngAggregationWindow = [p[@"AggregationWindow"] integerValue] ?: 300;
            ngSortMode = [p[@"SortMode"] integerValue] ?: 0;
        }),
        CFSTR("com.yourname.notificationgrouper/ReloadPrefs"), NULL,
        CFNotificationSuspensionBehaviorCoalesce
    );
}

// ============================================
// 私有类接口定义 (供实现代码使用)
// ============================================

@interface NCNotificationRequest : NSObject
- (NSString *)sectionIdentifier;
- (NSString *)notificationIdentifier;
- (id)bulletin;
- (id)destinationBundleIdentifier;
- (NSDate *)timestamp;
- (id)content;
@end

@interface NCCoalescedNotification : NSObject
@property (nonatomic, readonly) NSArray *notificationRequests;
@end

@interface NCNotificationContent : NSObject
@property (nonatomic, copy) NSString *header;
@property (nonatomic, copy) NSString *subheader;
@end

@interface NCBulletinRequest : NSObject
@property (nonatomic, copy) NSString *sectionID;
@end

@interface NCNotificationDispatcher : NSObject
- (id)notificationStore;
@end

@interface NCNotificationStore : NSObject
- (NCCoalescedNotification *)coalescedNotificationForRequest:(NCNotificationRequest *)req;
@end

@interface NCNotificationCombinedListViewController : UIViewController
@end

@interface NCNotificationStructuredListViewController : UIViewController
@end

@interface NCNotificationSeparatorsListViewController : UIViewController
@end

@interface NCNotificationListSectionHeaderView : UIView
@end

@interface NCNotificationListSectionRevealHintView : UIView
@end

@interface SBIconModel : NSObject
- (id)applicationIconForBundleIdentifier:(NSString *)bundleID;
@end

@interface SBIcon : NSObject
- (id)getIconImage:(int)size;
@end

// ============================================
// NGManager 实现
// ============================================
@implementation NGManager

+ (instancetype)sharedInstance {
    static NGManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[NGManager alloc] init]; });
    return shared;
}

- (instancetype)init {
    self = [super init];
    return self;
}

- (NSMutableDictionary *)notificationRequests {
    static NSMutableDictionary *dict = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ dict = [NSMutableDictionary new]; });
    return dict;
}

- (NSMutableDictionary *)timestamps {
    static NSMutableDictionary *dict = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ dict = [NSMutableDictionary new]; });
    return dict;
}

- (NSMutableDictionary *)counts {
    static NSMutableDictionary *dict = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ dict = [NSMutableDictionary new]; });
    return dict;
}

- (NSMutableDictionary *)names {
    static NSMutableDictionary *dict = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ dict = [NSMutableDictionary new]; });
    return dict;
}

- (NSString *)bundleIDForRequest:(id)req {
    if (!req) return nil;
    NSString *bid = [req sectionIdentifier];
    if (bid) return bid;
    id bulletin = [req bulletin];
    if (bulletin && [bulletin respondsToSelector:@selector(sectionID)]) {
        bid = [bulletin sectionID];
        if (bid) return bid;
    }
    return [req destinationBundleIdentifier];
}

- (NSDate *)timestampForRequest:(id)req {
    if (!req) return nil;
    if ([req respondsToSelector:@selector(timestamp)]) return [req timestamp];
    return nil;
}

- (NSString *)nidForRequest:(id)req {
    if (!req) return nil;
    if ([req respondsToSelector:@selector(notificationIdentifier)]) return [req notificationIdentifier];
    return nil;
}

- (void)insertRequest:(id)req {
    if (!req) return;
    NSString *bundleID = [self bundleIDForRequest:req];
    if (!bundleID) return;
    
    // 提取名称
    if ([req respondsToSelector:@selector(content)]) {
        id content = [req content];
        if (content && [content respondsToSelector:@selector(header)]) {
            NSString *h = [content header];
            if (h && [h isKindOfClass:[NSString class]]) self.names[bundleID] = h;
        }
    }
    
    // 时间戳
    NSDate *ts = [self timestampForRequest:req];
    if (ts) {
        NSDate *existing = self.timestamps[bundleID];
        if (!existing || [ts compare:existing] == NSOrderedDescending) {
            self.timestamps[bundleID] = ts;
        }
    }
    
    // 添加到列表
    if (!self.notificationRequests[bundleID]) {
        self.notificationRequests[bundleID] = [NSMutableArray new];
    }
    NSString *nid = [self nidForRequest:req];
    if (nid) {
        BOOL found = NO;
        for (NSString *eid in self.notificationRequests[bundleID]) {
            if ([eid isEqualToString:nid]) { found = YES; break; }
        }
        if (!found) [self.notificationRequests[bundleID] addObject:nid];
    }
    
    self.counts[bundleID] = @(self.notificationRequests[bundleID].count);
}

- (void)removeRequest:(id)req {
    if (!req) return;
    NSString *bundleID = [self bundleIDForRequest:req];
    if (!bundleID) return;
    NSString *nid = [self nidForRequest:req];
    if (nid && self.notificationRequests[bundleID]) {
        NSMutableArray *arr = self.notificationRequests[bundleID];
        for (NSInteger i = arr.count - 1; i >= 0; i--) {
            if ([arr[i] isEqualToString:nid]) [arr removeObjectAtIndex:i];
        }
        self.counts[bundleID] = @(arr.count);
    }
}

- (NSInteger)countForBundleID:(NSString *)bundleID {
    return self.counts[bundleID] ? [self.counts[bundleID] integerValue] : 0;
}

- (NSString *)nameForBundleID:(NSString *)bundleID {
    return self.names[bundleID] ?: bundleID;
}

- (UIImage *)iconForBundleID:(NSString *)bundleID {
    Class $SBIconController = objc_getClass("SBIconController");
    if (!$SBIconController) return nil;
    
    id ctrl = [$SBIconController performSelector:@selector(sharedInstance)];
    if (!ctrl) return nil;
    
    SBIconModel *model = nil;
    if ([ctrl respondsToSelector:@selector(homescreenIconViewMap)]) {
        id map = [ctrl performSelector:@selector(homescreenIconViewMap)];
        if (map && [map respondsToSelector:@selector(iconModel)]) {
            model = [map performSelector:@selector(iconModel)];
        }
    }
    if (!model && [ctrl respondsToSelector:@selector(model)]) {
        model = [ctrl performSelector:@selector(model)];
    }
    if (!model) return nil;
    
    SBIcon *icon = [model applicationIconForBundleIdentifier:bundleID];
    if (icon && [icon respondsToSelector:@selector(getIconImage:)]) {
        return [icon getIconImage:2];
    }
    return nil;
}

@end

// ============================================
// NGViewCell - 分组徽章
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

- (void)configWithBundleID:(NSString *)bundleID count:(NSInteger)count {
    NGManager *mgr = [NGManager sharedInstance];
    _iconView.image = [mgr iconForBundleID:bundleID] ?: [UIImage systemImageNamed:@"app.fill"];
    _nameLabel.text = [mgr nameForBundleID:bundleID];
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
@interface NGView () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) NSMutableArray *sortedBundleIDs;
@property (nonatomic, assign) BOOL isExpanded;
@end

@implementation NGView

+ (void)refreshBadge {
    if (!ngBadgeView) return;
    [ngBadgeView refreshInternal];
}

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

- (void)refreshInternal {
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
            NSInteger ca = [mgr countForBundleID:a];
            NSInteger cb = [mgr countForBundleID:b];
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
    [cell configWithBundleID:bundleID count:[[NGManager sharedInstance] countForBundleID:bundleID]];
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    NSLog(@"[NotificationGrouper] Tapped: %@", self.sortedBundleIDs[indexPath.item]);
}

@end
