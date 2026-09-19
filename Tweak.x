#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <PhotosUI/PhotosUI.h>
#import <substrate.h>

// MARK: - 私有类声明
@interface NSTask : NSObject
@property (nonatomic, retain) NSString *launchPath;
@property (nonatomic, retain) NSArray *arguments;
- (void)launch;
- (void)waitUntilExit;
@end

// MARK: - 全局变量
static NSFileManager *g_fileManager = nil;
static UIPasteboard *g_pasteboard = nil;
static BOOL g_canReleaseBuffer = YES;
static BOOL g_bufferReload = YES;
static AVSampleBufferDisplayLayer *g_previewLayer = nil;
static NSTimeInterval g_refreshPreviewByVideoDataOutputTime = 0;
static BOOL g_cameraRunning = NO;
static NSString *g_cameraPosition = @"B";
static AVCaptureVideoOrientation g_photoOrientation = AVCaptureVideoOrientationPortrait;

// 视频读取相关
static AVAssetReader *reader = nil;
static AVAssetReaderTrackOutput *videoTrackout_32BGRA = nil;
static AVAssetReaderTrackOutput *videoTrackout_420YpCbCr8BiPlanarVideoRange = nil;
static AVAssetReaderTrackOutput *videoTrackout_420YpCbCr8BiPlanarFullRange = nil;
static AVAssetReaderTrackOutput *audioTrackout_pcm = nil;

// 音频播放
static AVAudioEngine *g_audioEngine = nil;
static AVPlayerItem *g_audioPlayerItem = nil;
static AVPlayer *g_audioPlayer = nil;
static BOOL g_audioEnabled = YES;

// 计时器
static NSTimeInterval g_videoRecordingStartTime = 0;
static NSTimeInterval g_lastBufferRefreshTime = 0;
static const NSTimeInterval BUFFER_REFRESH_INTERVAL = 30.0;

// 环境与设置
static BOOL g_isIOS15OrLater = NO;
static BOOL g_enableNotification = YES;
static BOOL g_minimizeUIInteraction = NO;
static BOOL g_ldRestartCompleted = NO;

// 下载相关
static NSString *g_downloadAddress = @"";
static BOOL g_downloadRunning = NO;

// RootHide 适配路径
NSString *g_isMirroredMark = @"/var/jb/var/mobile/Library/Caches/vcam_is_mirrored_mark";
NSString *g_tempFile = @"/var/jb/var/mobile/Library/Caches/temp.mov";

// 悬浮窗管理器
static UIWindow *g_floatWindow = nil;
static UIButton *g_floatingBtn = nil;
static UIViewController *g_pickerHostController = nil;

// MARK: - GetFrame 类（视频帧处理核心）
@interface GetFrame : NSObject
+ (CMSampleBufferRef _Nullable)getCurrentFrame:(CMSampleBufferRef) originSampleBuffer :(BOOL)forceReNew;
+ (UIWindow*)getKeyWindow;
+ (void)setupAudioPlayback;
+ (void)showMinimalNotification:(NSString *)message;
+ (void)fixCameraWithLDRestart;
@end

@implementation GetFrame
+ (CMSampleBufferRef _Nullable)getCurrentFrame:(CMSampleBufferRef _Nullable) originSampleBuffer :(BOOL)forceReNew{
    static CMSampleBufferRef sampleBuffer = nil;
    CMFormatDescriptionRef formatDescription = nil;
    CMMediaType mediaType = -1;
    CMMediaType subMediaType = -1;
    CMVideoDimensions dimensions;
    if (originSampleBuffer != nil) {
        formatDescription = CMSampleBufferGetFormatDescription(originSampleBuffer);
        mediaType = CMFormatDescriptionGetMediaType(formatDescription);
        subMediaType = CMFormatDescriptionGetMediaSubType(formatDescription);
        dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
        if (mediaType != kCMMediaType_Video) {
            return originSampleBuffer;
        }
    }
    (void)dimensions;

    if ([g_fileManager fileExistsAtPath:g_tempFile] == NO) return nil;
    if (sampleBuffer != nil && !g_canReleaseBuffer && CMSampleBufferIsValid(sampleBuffer) && forceReNew != YES) return sampleBuffer;

    static NSTimeInterval renewTime = 0;
    if ([g_fileManager fileExistsAtPath:[NSString stringWithFormat:@"%@.new", g_tempFile]]) {
        NSTimeInterval nowTime = [[NSDate date] timeIntervalSince1970];
        if (nowTime - renewTime > 3) {
            renewTime = nowTime;
            g_bufferReload = YES;
        }
    }

    if (g_bufferReload) {
        g_bufferReload = NO;
        @try{
            AVAsset *asset = [AVAsset assetWithURL: [NSURL URLWithString:[NSString stringWithFormat:@"file://%@", g_tempFile]]];
            reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
            AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
            videoTrackout_32BGRA = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];
            videoTrackout_420YpCbCr8BiPlanarVideoRange = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)}];
            videoTrackout_420YpCbCr8BiPlanarFullRange = [[AVAssetReaderTrackOutput alloc] initWithTrack:videoTrack outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)}];
            
            AVAssetTrack *audioTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
            if (audioTrack) {
                audioTrackout_pcm = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack outputSettings:@{AVFormatIDKey : [NSNumber numberWithInt:kAudioFormatLinearPCM]}];
                if (audioTrackout_pcm) [reader addOutput:audioTrackout_pcm];
            }
            
            [reader addOutput:videoTrackout_32BGRA];
            [reader addOutput:videoTrackout_420YpCbCr8BiPlanarVideoRange];
            [reader addOutput:videoTrackout_420YpCbCr8BiPlanarFullRange];
            [reader startReading];
        }@catch(NSException *except) { NSLog(@"初始化读取视频出错:%@", except); }
    }

    CMSampleBufferRef videoTrackout_32BGRA_Buffer = [videoTrackout_32BGRA copyNextSampleBuffer];
    CMSampleBufferRef videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer = [videoTrackout_420YpCbCr8BiPlanarVideoRange copyNextSampleBuffer];
    CMSampleBufferRef videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer = [videoTrackout_420YpCbCr8BiPlanarFullRange copyNextSampleBuffer];

    CMSampleBufferRef newsampleBuffer = nil;
    switch(subMediaType) {
        case kCVPixelFormatType_32BGRA:
            CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_32BGRA_Buffer, &newsampleBuffer); break;
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer, &newsampleBuffer); break;
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer, &newsampleBuffer); break;
        default:
            CMSampleBufferCreateCopy(kCFAllocatorDefault, videoTrackout_32BGRA_Buffer, &newsampleBuffer);
    }
    if (videoTrackout_32BGRA_Buffer != nil) CFRelease(videoTrackout_32BGRA_Buffer);
    if (videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer != nil) CFRelease(videoTrackout_420YpCbCr8BiPlanarVideoRange_Buffer);
    if (videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer != nil) CFRelease(videoTrackout_420YpCbCr8BiPlanarFullRange_Buffer);

    if (newsampleBuffer == nil) {
        g_bufferReload = YES;
    } else {
        if (sampleBuffer != nil) CFRelease(sampleBuffer);
        if (originSampleBuffer != nil) {
            CMSampleBufferRef copyBuffer = nil;
            CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(newsampleBuffer);
            CMSampleTimingInfo sampleTime = {
                .duration = CMSampleBufferGetDuration(originSampleBuffer),
                .presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(originSampleBuffer),
                .decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(originSampleBuffer)
            };
            CMVideoFormatDescriptionRef videoInfo = nil;
            CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &videoInfo);
            CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, nil, nil, videoInfo, &sampleTime, &copyBuffer);
            if (copyBuffer != nil) {
                CFDictionaryRef exifAttachments = CMGetAttachment(originSampleBuffer, (CFStringRef)@"{Exif}", NULL);
                CFDictionaryRef TIFFAttachments = CMGetAttachment(originSampleBuffer, (CFStringRef)@"{TIFF}", NULL);
                if (exifAttachments != nil) CMSetAttachment(copyBuffer, (CFStringRef)@"{Exif}", exifAttachments, kCMAttachmentMode_ShouldPropagate);
                if (exifAttachments != nil) CMSetAttachment(copyBuffer, (CFStringRef)@"{TIFF}", TIFFAttachments, kCMAttachmentMode_ShouldPropagate);
                sampleBuffer = copyBuffer;
            }
            CFRelease(newsampleBuffer);
        } else {
            sampleBuffer = newsampleBuffer;
        }
    }
    if (CMSampleBufferIsValid(sampleBuffer)) return sampleBuffer;
    return nil;
}

+(UIWindow*)getKeyWindow{
    UIWindow *keyWindow = nil;
    if (keyWindow == nil) {
        NSArray *windows = UIApplication.sharedApplication.windows;
        for(UIWindow *window in windows){
            if(window.isKeyWindow) { keyWindow = window; break; }
        }
    }
    return keyWindow;
}

+ (void)setupAudioPlayback {
    static BOOL isAudioSetup = NO;
    if (!g_audioEnabled || isAudioSetup || ![g_fileManager fileExistsAtPath:g_tempFile]) return;
    @try {
        [g_audioPlayer pause]; g_audioPlayer = nil; g_audioPlayerItem = nil;
        NSURL *videoURL = [NSURL fileURLWithPath:g_tempFile];
        g_audioPlayerItem = [AVPlayerItem playerItemWithURL:videoURL];
        g_audioPlayer = [AVPlayer playerWithPlayerItem:g_audioPlayerItem];
        [g_audioPlayer setActionAtItemEnd:AVPlayerActionAtItemEndNone];
        [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:g_audioPlayerItem queue:nil usingBlock:^(NSNotification *note) { [g_audioPlayer seekToTime:kCMTimeZero]; }];
        [g_audioPlayer play];
        isAudioSetup = YES;
    } @catch (NSException *exception) { NSLog(@"Lỗi khi thiết lập âm thanh: %@", exception); }
}

+ (void)showMinimalNotification:(NSString *)message {
    if (!g_enableNotification) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [GetFrame getKeyWindow];
        UIView *notificationView = [[UIView alloc] initWithFrame:CGRectMake(0, 44, window.bounds.size.width, 40)];
        notificationView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
        notificationView.layer.cornerRadius = 10;
        notificationView.clipsToBounds = YES;
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(10, 5, notificationView.bounds.size.width - 20, 30)];
        label.text = message; label.textColor = [UIColor whiteColor];
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont systemFontOfSize:14];
        [notificationView addSubview:label];
        [window addSubview:notificationView];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.5 animations:^{ notificationView.alpha = 0; } completion:^(BOOL finished) { [notificationView removeFromSuperview]; }];
        });
    });
}

+ (void)fixCameraWithLDRestart {
    BOOL hasPowerSelector = [[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb/Library/MobileSubstrate/DynamicLibraries/PowerSelector.dylib"];
    if (hasPowerSelector) {
        NSTask *task = [[NSTask alloc] init];
        [task setLaunchPath:@"/var/jb/usr/bin/powerselector"];
        [task setArguments:@[@"ldrestart"]];
        [task launch];
        g_ldRestartCompleted = YES;
        [GetFrame showMinimalNotification:@"Đang khởi động lại các dịch vụ để sửa lỗi camera..."];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSTask *uiCacheTask = [[NSTask alloc] init];
            [uiCacheTask setLaunchPath:@"/var/jb/usr/bin/uicache"];
            [uiCacheTask launch];
            [GetFrame showMinimalNotification:@"Đã sửa lỗi camera"];
        });
    } else {
        UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Cần PowerSelector" message:@"Để sửa lỗi camera, hãy cài đặt PowerSelector từ Cydia" preferredStyle:UIAlertControllerStyleAlert];
        [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [[GetFrame getKeyWindow].rootViewController presentViewController:alertController animated:YES completion:nil];
    }
}
@end

// MARK: - VCAM 悬浮窗管理器 (核心 UI 逻辑)
@interface VCAMFloatingManager : NSObject <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
+ (instancetype)sharedInstance;
- (void)setupFloatingWindow;
- (void)showMenu;
- (void)selectVideo;
- (void)downloadVideo;
- (void)handlePan:(UIPanGestureRecognizer *)gesture;
@end

@implementation VCAMFloatingManager
+ (instancetype)sharedInstance {
    static VCAMFloatingManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCAMFloatingManager alloc] init];
    });
    return instance;
}

- (void)setupFloatingWindow {
    if (g_floatWindow) {
        g_floatWindow.hidden = NO;
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene *activeScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                activeScene = (UIWindowScene *)scene;
                break;
            }
        }
        
        if (activeScene) {
            g_floatWindow = [[UIWindow alloc] initWithWindowScene:activeScene];
        } else {
            g_floatWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        }
        
        g_floatWindow.windowLevel = UIWindowLevelAlert + 1000;
        g_floatWindow.backgroundColor = [UIColor clearColor];
        g_floatWindow.hidden = NO;
        
        UIViewController *rootVC = [[UIViewController alloc] init];
        rootVC.view.backgroundColor = [UIColor clearColor];
        g_floatWindow.rootViewController = rootVC;
        
        g_floatingBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        g_floatingBtn.frame = CGRectMake(20, 100, 60, 60);
        g_floatingBtn.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.8];
        g_floatingBtn.layer.cornerRadius = 30;
        g_floatingBtn.layer.borderWidth = 2.0;
        g_floatingBtn.layer.borderColor = [UIColor whiteColor].CGColor;
        [g_floatingBtn setTitle:@"VC" forState:UIControlStateNormal];
        [g_floatingBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        g_floatingBtn.titleLabel.font = [UIFont boldSystemFontOfSize:20];
        [g_floatingBtn addTarget:self action:@selector(showMenu) forControlEvents:UIControlEventTouchUpInside];
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [g_floatingBtn addGestureRecognizer:pan];
        [g_floatWindow addSubview:g_floatingBtn];
    });
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    UIView *btn = gesture.view;
    CGPoint translation = [gesture translationInView:btn.superview];
    btn.center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:btn.superview];
}

- (void)showMenu {
    NSString *str = g_pasteboard.string;
    NSString *infoStr = @"使用镜头后将记录信息";
    if (str != nil && [str hasPrefix:@"CCVCAM"]) {
        str = [str substringFromIndex:6];
        NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:str options:0];
        infoStr = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
    }
    NSString *title = @"iOS-VCAM";
    if ([g_fileManager fileExistsAtPath:g_tempFile]) title = @"iOS-VCAM ✅";
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:title message:infoStr preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *next = [UIAlertAction actionWithTitle:@"选择视频" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){ [self selectVideo]; }];
    UIAlertAction *download = [UIAlertAction actionWithTitle:@"下载视频" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){ [self downloadVideo]; }];
    UIAlertAction *cancelReplace = [UIAlertAction actionWithTitle:@"禁用替换" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
        if ([g_fileManager fileExistsAtPath:g_tempFile]) [g_fileManager removeItemAtPath:g_tempFile error:nil];
    }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消操作" style:UIAlertActionStyleCancel handler:nil];
    [alertController addAction:next]; [alertController addAction:download]; [alertController addAction:cancelReplace]; [alertController addAction:cancel];
    [[GetFrame getKeyWindow].rootViewController presentViewController:alertController animated:YES completion:nil];
}

// 使用 PHPickerViewController 替代 UIImagePicker，异步处理，彻底解决卡死
- (void)selectVideo {
    if (@available(iOS 14.0, *)) {
        PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
        config.filter = [PHPickerFilter videosFilter];
        config.selectionLimit = 1;
        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
        picker.delegate = self;
        [[GetFrame getKeyWindow].rootViewController presentViewController:picker animated:YES completion:nil];
    }
}

#pragma mark - PHPickerViewControllerDelegate
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;

    PHPickerResult *result = results.firstObject;
    NSItemProvider *provider = result.itemProvider;
    
    if ([provider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier]) {
        [provider loadFileRepresentationForTypeIdentifier:UTTypeMovie.identifier completionHandler:^(NSURL *url, NSError *error) {
            if (error || !url) {
                NSLog(@"选择视频失败: %@", error);
                return;
            }
            
            // 此时已经在后台线程，可以安全进行文件拷贝，彻底避免主线程卡死
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSString *tempPath = [url path];
                if ([g_fileManager fileExistsAtPath:g_tempFile]) [g_fileManager removeItemAtPath:g_tempFile error:nil];
                
                NSError *copyError = nil;
                if ([g_fileManager copyItemAtPath:tempPath toPath:g_tempFile error:&copyError]) {
                    // 通知 GetFrame 刷新视频 buffer
                    [g_fileManager createDirectoryAtPath:[NSString stringWithFormat:@"%@.new", g_tempFile] withIntermediateDirectories:YES attributes:nil error:nil];
                    
                    // 回到主线程，启动音频播放和提示
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [GetFrame setupAudioPlayback];
                        [GetFrame showMinimalNotification:@"视频已加载"];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            [g_fileManager removeItemAtPath:[NSString stringWithFormat:@"%@.new", g_tempFile] error:nil];
                        });
                    });
                } else {
                    NSLog(@"视频拷贝失败: %@", copyError);
                }
            });
        }];
    }
}

- (void)downloadVideo {
    if (g_downloadRunning) return;
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"下载视频" message:@"输入远程视频地址（MOV/MP4）" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        if ([g_downloadAddress isEqual:@""]) { textField.placeholder = @"http://..."; } else { textField.text = g_downloadAddress; }
        textField.keyboardType = UIKeyboardTypeURL;
    }];
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"下载" style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        g_downloadAddress = alert.textFields[0].text;
        if ([g_downloadAddress isEqual:@""]) return;
        g_downloadRunning = YES;
        [GetFrame showMinimalNotification:@"开始下载..."];
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSString *tempPath = [NSString stringWithFormat:@"%@.downloading.mov", g_tempFile];
            NSData *urlData = [NSData dataWithContentsOfURL:[NSURL URLWithString:g_downloadAddress]];
            if ([urlData writeToFile:tempPath atomically:YES]) {
                AVAsset *asset = [AVAsset assetWithURL: [NSURL URLWithString:[NSString stringWithFormat:@"file://%@", tempPath]]];
                if (asset.playable) {
                    if ([g_fileManager fileExistsAtPath:g_tempFile]) [g_fileManager removeItemAtPath:g_tempFile error:nil];
                    [g_fileManager moveItemAtPath:tempPath toPath:g_tempFile error:nil];
                    [g_fileManager createDirectoryAtPath:[NSString stringWithFormat:@"%@.new", g_tempFile] withIntermediateDirectories:YES attributes:nil error:nil];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [GetFrame showMinimalNotification:@"下载完成"];
                        [g_fileManager removeItemAtPath:[NSString stringWithFormat:@"%@.new", g_tempFile] error:nil];
                    });
                } else {
                    if ([g_fileManager fileExistsAtPath:tempPath]) [g_fileManager removeItemAtPath:tempPath error:nil];
                    dispatch_async(dispatch_get_main_queue(), ^{ [GetFrame showMinimalNotification:@"视频格式无效"]; });
                }
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{ [GetFrame showMinimalNotification:@"下载失败"]; });
            }
            g_downloadRunning = NO;
        });
    }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:okAction]; [alert addAction:cancel];
    [[GetFrame getKeyWindow].rootViewController presentViewController:alert animated:YES completion:nil];
}
@end

// MARK: - 越狱 Hook 核心逻辑

CALayer *g_maskLayer = nil;

%hook AVCaptureVideoPreviewLayer
- (void)addSublayer:(CALayer *)layer{
    %orig;
    [[VCAMFloatingManager sharedInstance] setupFloatingWindow];
    
    static CADisplayLink *displayLink = nil;
    if (displayLink == nil) {
        displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(step:)];
        [displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
    }
    if (![[self sublayers] containsObject:g_previewLayer]) {
        g_previewLayer = [[AVSampleBufferDisplayLayer alloc] init];
        g_maskLayer = [CALayer new];
        g_maskLayer.backgroundColor = [UIColor blackColor].CGColor;
        [self insertSublayer:g_maskLayer above:layer];
        [self insertSublayer:g_previewLayer above:g_maskLayer];
        dispatch_async(dispatch_get_main_queue(), ^{
            g_previewLayer.frame = [UIApplication sharedApplication].keyWindow.bounds;
            g_maskLayer.frame = [UIApplication sharedApplication].keyWindow.bounds;
        });
    }
}

%new
-(void)step:(CADisplayLink *)sender{
    if ([g_fileManager fileExistsAtPath:g_tempFile]) {
        if (g_maskLayer != nil) g_maskLayer.opacity = 1;
        if (g_previewLayer != nil) { g_previewLayer.opacity = 1; [g_previewLayer setVideoGravity:[self videoGravity]]; }
    } else {
        if (g_maskLayer != nil) g_maskLayer.opacity = 0;
        if (g_previewLayer != nil) g_previewLayer.opacity = 0;
    }
    if (g_cameraRunning && g_previewLayer != nil) {
        g_previewLayer.frame = self.bounds;
        switch(g_photoOrientation) {
            case AVCaptureVideoOrientationPortrait:
            case AVCaptureVideoOrientationPortraitUpsideDown:
                g_previewLayer.transform = CATransform3DMakeRotation(0 / 180.0 * M_PI, 0.0, 0.0, 1.0); break;
            case AVCaptureVideoOrientationLandscapeRight:
                g_previewLayer.transform = CATransform3DMakeRotation(90 / 180.0 * M_PI, 0.0, 0.0, 1.0); break;
            case AVCaptureVideoOrientationLandscapeLeft:
                g_previewLayer.transform = CATransform3DMakeRotation(-90 / 180.0 * M_PI, 0.0, 0.0, 1.0); break;
            default:
                g_previewLayer.transform = self.transform;
        }
        static NSTimeInterval refreshTime = 0;
        NSTimeInterval nowTime = [[NSDate date] timeIntervalSince1970] * 1000;
        if (nowTime - g_refreshPreviewByVideoDataOutputTime > 1000) {
            static CMSampleBufferRef copyBuffer = nil;
            if (nowTime - refreshTime > 1000 / 33 && g_previewLayer.readyForMoreMediaData) {
                refreshTime = nowTime;
                g_photoOrientation = -1;
                CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:nil :NO];
                if (newBuffer != nil) {
                    [g_previewLayer flush];
                    if (copyBuffer != nil) CFRelease(copyBuffer);
                    CMSampleBufferCreateCopy(kCFAllocatorDefault, newBuffer, &copyBuffer);
                    if (copyBuffer != nil) [g_previewLayer enqueueSampleBuffer:copyBuffer];
                    NSDate *datenow = [NSDate date];
                    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
                    [formatter setDateFormat:@"YYYY-MM-dd HH:mm:ss"];
                    CGSize dimensions = self.bounds.size;
                    NSString *str = [NSString stringWithFormat:@"%@\n%@ - %@\nW:%.0f H:%.0f", [formatter stringFromDate:datenow], [NSProcessInfo processInfo].processName, [NSString stringWithFormat:@"%@ - %@", g_cameraPosition, @"preview"], dimensions.width, dimensions.height];
                    NSData *data = [str dataUsingEncoding:NSUTF8StringEncoding];
                    [g_pasteboard setString:[NSString stringWithFormat:@"CCVCAM%@", [data base64EncodedStringWithOptions:0]]];
                }
            }
        }
    }
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    if (currentTime - g_lastBufferRefreshTime > BUFFER_REFRESH_INTERVAL) {
        g_lastBufferRefreshTime = currentTime;
        g_bufferReload = YES;
    }
}
%end

%hook AVCaptureSession
-(void) startRunning {
    g_cameraRunning = YES; g_bufferReload = YES;
    g_videoRecordingStartTime = [[NSDate date] timeIntervalSince1970];
    g_lastBufferRefreshTime = g_videoRecordingStartTime;
    g_refreshPreviewByVideoDataOutputTime = g_videoRecordingStartTime * 1000;
    %orig;
}
-(void) stopRunning {
    g_cameraRunning = NO;
    %orig;
}
- (void)addInput:(AVCaptureDeviceInput *)input {
    if ([[input device] position] > 0) { g_cameraPosition = [[input device] position] == 1 ? @"B" : @"F"; }
    %orig;
}
- (void)addOutput:(AVCaptureOutput *)output{
    %orig;
}
%end

%hook AVCaptureStillImageOutput
- (void)captureStillImageAsynchronouslyFromConnection:(AVCaptureConnection *)connection completionHandler:(void (^)(CMSampleBufferRef imageDataSampleBuffer, NSError *error))handler{
    g_canReleaseBuffer = NO;
    void (^newHandler)(CMSampleBufferRef imageDataSampleBuffer, NSError *error) = ^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
        CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:imageDataSampleBuffer :YES];
        if (newBuffer != nil) imageDataSampleBuffer = newBuffer;
        handler(imageDataSampleBuffer, error);
        g_canReleaseBuffer = YES;
    };
    %orig(connection, [newHandler copy]);
}
+ (NSData *)jpegStillImageNSDataRepresentation:(CMSampleBufferRef)jpegSampleBuffer{
    CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:nil :NO];
    if (newBuffer != nil) {
        CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(newBuffer);
        CIImage *ciimage = [CIImage imageWithCVImageBuffer:pixelBuffer];
        if (@available(iOS 11.0, *)) {
            switch(g_photoOrientation){
                case AVCaptureVideoOrientationPortrait: ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationUp]; break;
                case AVCaptureVideoOrientationPortraitUpsideDown: ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationDown]; break;
                case AVCaptureVideoOrientationLandscapeRight: ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationRight]; break;
                case AVCaptureVideoOrientationLandscapeLeft: ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationLeft]; break;
            }
        }
        UIImage *uiimage = [UIImage imageWithCIImage:ciimage scale:2.0f orientation:UIImageOrientationUp];
        if ([g_fileManager fileExistsAtPath:g_isMirroredMark]) uiimage = [UIImage imageWithCIImage:ciimage scale:2.0f orientation:UIImageOrientationUpMirrored];
        return UIImageJPEGRepresentation(uiimage, 1);
    }
    return %orig;
}
%end

%hook AVCapturePhotoOutput
+ (NSData *)JPEGPhotoDataRepresentationForJPEGSampleBuffer:(CMSampleBufferRef)JPEGSampleBuffer previewPhotoSampleBuffer:(CMSampleBufferRef)previewPhotoSampleBuffer{
    CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:nil :NO];
    if (newBuffer != nil) {
        CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(newBuffer);
        CIImage *ciimage = [CIImage imageWithCVImageBuffer:pixelBuffer];
        if (@available(iOS 11.0, *)) {
            switch(g_photoOrientation){
                case AVCaptureVideoOrientationPortrait: ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationUp]; break;
                case AVCaptureVideoOrientationPortraitUpsideDown: ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationDown]; break;
                case AVCaptureVideoOrientationLandscapeRight: ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationRight]; break;
                case AVCaptureVideoOrientationLandscapeLeft: ciimage = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationLeft]; break;
            }
        }
        UIImage *uiimage = [UIImage imageWithCIImage:ciimage scale:2.0f orientation:UIImageOrientationUp];
        if ([g_fileManager fileExistsAtPath:g_isMirroredMark]) uiimage = [UIImage imageWithCIImage:ciimage scale:2.0f orientation:UIImageOrientationUpMirrored];
        return UIImageJPEGRepresentation(uiimage, 1);
    }
    return %orig;
}

- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate{
    if (settings == nil || delegate == nil) return %orig;
    if (g_isIOS15OrLater) {
        if (@available(iOS 15.0, *)) {
            if ([delegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
                static NSMutableArray *hooked;
                if (hooked == nil) hooked = [NSMutableArray new];
                NSString *className = NSStringFromClass([delegate class]);
                if ([hooked containsObject:className] == NO) {
                    [hooked addObject:className];
                    __block void (*original_method)(id self, SEL _cmd, AVCapturePhotoOutput *captureOutput, AVCapturePhoto *photo, NSError *error) = nil;
                    MSHookMessageEx([delegate class], @selector(captureOutput:didFinishProcessingPhoto:error:), imp_implementationWithBlock(^(id self, AVCapturePhotoOutput *captureOutput, AVCapturePhoto *photo, NSError *error){
                        if (![g_fileManager fileExistsAtPath:g_tempFile]) return original_method(self, @selector(captureOutput:didFinishProcessingPhoto:error:), captureOutput, photo, error);
                        g_canReleaseBuffer = NO;
                        static CMSampleBufferRef copyBuffer = nil;
                        CMSampleBufferRef tempBuffer = nil;
                        CVPixelBufferRef tempPixelBuffer = photo.pixelBuffer;
                        CMSampleTimingInfo sampleTime = {0,};
                        CMVideoFormatDescriptionRef videoInfo = nil;
                        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, tempPixelBuffer, &videoInfo);
                        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, tempPixelBuffer, true, nil, nil, videoInfo, &sampleTime, &tempBuffer);
                        CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:tempBuffer :YES];
                        if (tempBuffer != nil) CFRelease(tempBuffer);
                        if (newBuffer != nil) {
                            if (copyBuffer != nil) CFRelease(copyBuffer);
                            CMSampleBufferCreateCopy(kCFAllocatorDefault, newBuffer, &copyBuffer);
                            __block CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(copyBuffer);
                            CIImage *ciimage = [CIImage imageWithCVImageBuffer:imageBuffer];
                            CIImage *ciimageRotate = [ciimage imageByApplyingCGOrientation:kCGImagePropertyOrientationLeft];
                            CIContext *cicontext = [CIContext new];
                            __block CGImageRef _Nullable cgimage = [cicontext createCGImage:ciimageRotate fromRect:ciimageRotate.extent];
                            UIImage *uiimage = [UIImage imageWithCIImage:ciimage];
                            __block NSData *theNewPhoto = UIImageJPEGRepresentation(uiimage, 1);
                            
                            __block NSData *(*fileDataRepresentationWithCustomizer)(id self, SEL _cmd, id<AVCapturePhotoFileDataRepresentationCustomizer> customizer);
                            MSHookMessageEx([photo class], @selector(fileDataRepresentationWithCustomizer:), imp_implementationWithBlock(^(id self, id<AVCapturePhotoFileDataRepresentationCustomizer> customizer){
                                if ([g_fileManager fileExistsAtPath:g_tempFile]) return theNewPhoto;
                                return fileDataRepresentationWithCustomizer(self, @selector(fileDataRepresentationWithCustomizer:), customizer);
                            }), (IMP*)&fileDataRepresentationWithCustomizer);
                            
                            __block NSData *(*fileDataRepresentation)(id self, SEL _cmd);
                            MSHookMessageEx([photo class], @selector(fileDataRepresentation), imp_implementationWithBlock(^(id self, SEL _cmd){
                                if ([g_fileManager fileExistsAtPath:g_tempFile]) return theNewPhoto;
                                return fileDataRepresentation(self, @selector(fileDataRepresentation));
                            }), (IMP*)&fileDataRepresentation);
                            
                            __block CVPixelBufferRef *(*previewPixelBuffer)(id self, SEL _cmd);
                            MSHookMessageEx([photo class], @selector(previewPixelBuffer), imp_implementationWithBlock(^(id self, SEL _cmd){ return nil; }), (IMP*)&previewPixelBuffer);
                            
                            __block CVImageBufferRef (*pixelBuffer)(id self, SEL _cmd);
                            MSHookMessageEx([photo class], @selector(pixelBuffer), imp_implementationWithBlock(^(id self, SEL _cmd){
                                if ([g_fileManager fileExistsAtPath:g_tempFile]) return imageBuffer;
                                return pixelBuffer(self, @selector(pixelBuffer));
                            }), (IMP*)&pixelBuffer);
                            
                            __block CGImageRef _Nullable(*CGImageRepresentation)(id self, SEL _cmd);
                            MSHookMessageEx([photo class], @selector(CGImageRepresentation), imp_implementationWithBlock(^(id self, SEL _cmd){
                                if ([g_fileManager fileExistsAtPath:g_tempFile]) return cgimage;
                                return CGImageRepresentation(self, @selector(CGImageRepresentation));
                            }), (IMP*)&CGImageRepresentation);
                            
                            __block CGImageRef _Nullable(*previewCGImageRepresentation)(id self, SEL _cmd);
                            MSHookMessageEx([photo class], @selector(previewCGImageRepresentation), imp_implementationWithBlock(^(id self, SEL _cmd){
                                if ([g_fileManager fileExistsAtPath:g_tempFile]) return cgimage;
                                return previewCGImageRepresentation(self, @selector(previewCGImageRepresentation));
                            }), (IMP*)&previewCGImageRepresentation);
                        }
                        g_canReleaseBuffer = YES;
                        return original_method(self, @selector(captureOutput:didFinishProcessingPhoto:error:), captureOutput, photo, error);
                    }), (IMP*)&original_method);
                }
            }
        }
    }
    %orig;
}
%end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue{
    if (sampleBufferDelegate == nil || sampleBufferCallbackQueue == nil) return %orig;
    static NSMutableArray *hooked;
    if (hooked == nil) hooked = [NSMutableArray new];
    NSString *className = NSStringFromClass([sampleBufferDelegate class]);
    if ([hooked containsObject:className] == NO) {
        [hooked addObject:className];
        __block void (*original_method)(id self, SEL _cmd, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) = nil;
        MSHookMessageEx([sampleBufferDelegate class], @selector(captureOutput:didOutputSampleBuffer:fromConnection:), imp_implementationWithBlock(^(id self, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection){
            g_refreshPreviewByVideoDataOutputTime = ([[NSDate date] timeIntervalSince1970]) * 1000;
            CMSampleBufferRef newBuffer = [GetFrame getCurrentFrame:sampleBuffer :NO];
            NSString *previewType = @"buffer";
            g_photoOrientation = [connection videoOrientation];
            if (newBuffer != nil && g_previewLayer != nil && g_previewLayer.readyForMoreMediaData) {
                [g_previewLayer flush];
                [g_previewLayer enqueueSampleBuffer:newBuffer];
                previewType = @"buffer - preview";
            }
            static NSTimeInterval oldTime = 0;
            NSTimeInterval nowTime = g_refreshPreviewByVideoDataOutputTime;
            if (nowTime - oldTime > 3000) {
                oldTime = nowTime;
                CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
                CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
                NSDate *datenow = [NSDate date];
                NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
                [formatter setDateFormat:@"YYYY-MM-dd HH:mm:ss"];
                NSString *str = [NSString stringWithFormat:@"%@\n%@ - %@\nW:%d H:%d", [formatter stringFromDate:datenow], [NSProcessInfo processInfo].processName, [NSString stringWithFormat:@"%@ - %@", g_cameraPosition, previewType], dimensions.width, dimensions.height];
                NSData *data = [str dataUsingEncoding:NSUTF8StringEncoding];
                [g_pasteboard setString:[NSString stringWithFormat:@"CCVCAM%@", [data base64EncodedStringWithOptions:0]]];
            }
            return original_method(self, @selector(captureOutput:didOutputSampleBuffer:fromConnection:), output, newBuffer != nil? newBuffer: sampleBuffer, connection);
        }), (IMP*)&original_method);
    }
    %orig;
}
%end

// MARK: - 初始化与销毁
%ctor {
    if([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){15, 0, 0}]) g_isIOS15OrLater = YES;
    g_audioEngine = [[AVAudioEngine alloc] init];
    g_fileManager = [NSFileManager defaultManager];
    g_pasteboard = [UIPasteboard generalPasteboard];
    
    // 监听应用启动，确保悬浮窗在合适的时机出现
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [[VCAMFloatingManager sharedInstance] setupFloatingWindow];
    }];
    
    // 兜底创建（防止部分应用不发通知）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[VCAMFloatingManager sharedInstance] setupFloatingWindow];
    });
}

%dtor{
    g_fileManager = nil; g_pasteboard = nil;
    g_canReleaseBuffer = YES; g_bufferReload = YES;
    g_previewLayer = nil; g_refreshPreviewByVideoDataOutputTime = 0;
    g_cameraRunning = NO;
    g_floatingBtn = nil;
    g_floatWindow = nil;
}