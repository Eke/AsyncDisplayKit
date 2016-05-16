//
//  ASVideoPlayerNode.m
//  AsyncDisplayKit
//
//  Created by Erekle on 5/6/16.
//  Copyright © 2016 Facebook. All rights reserved.
//

#import "ASVideoPlayerNode.h"
#import "ASDefaultPlaybackButton.h"

static void *ASVideoPlayerNodeContext = &ASVideoPlayerNodeContext;

@interface ASVideoPlayerNode() <ASVideoNodeDelegate>
{
  ASDN::RecursiveMutex _videoPlayerLock;

  __weak id<ASVideoPlayerNodeDelegate> _delegate;

  struct {
    unsigned int delegateNeededControls:1;
    unsigned int delegatePlaybackButtonTint:1;
    unsigned int delegateScrubberMaximumTrackTintColor:1;
    unsigned int delegateScrubberMinimumTrackTintColor:1;
    unsigned int delegateScrubberThumbTintColor:1;
    unsigned int delegateScrubberThumbImage:1;
    unsigned int delegateTimeLabelAttributes:1;
    unsigned int delegateTimeLabelAttributedString:1;
    unsigned int delegateLayoutSpecForControls:1;
    unsigned int delegateVideoNodeDidPlayToTime:1;
    unsigned int delegateVideoNodeWillChangeState:1;
    unsigned int delegateVideoNodeShouldChangeState:1;
    unsigned int delegateVideoNodePlaybackDidFinish:1;
    unsigned int delegateVideoNodeTapped:1;
  } _delegateFlags;
  
  NSURL *_url;
  AVAsset *_asset;
  
  ASVideoNode *_videoNode;

  NSArray *_neededControls;

  NSMutableDictionary *_cachedControls;

  ASDefaultPlaybackButton *_playbackButtonNode;
  ASTextNode  *_elapsedTextNode;
  ASTextNode  *_durationTextNode;
  ASDisplayNode *_scrubberNode;
  ASStackLayoutSpec *_controlFlexGrowSpacerSpec;

  BOOL _isSeeking;
  CMTime _duration;

  BOOL _disableControls;

  BOOL _shouldAutoplay;
  BOOL _shouldAutorepeat;
  BOOL _muted;
  int32_t _periodicTimeObserverTimescale;
  NSString *_gravity;

  UIColor *_defaultControlsColor;
}

@end

@implementation ASVideoPlayerNode
- (instancetype)init
{
  if (!(self = [super init])) {
    return nil;
  }

  [self privateInit];

  return self;
}

- (instancetype)initWithUrl:(NSURL*)url
{
  if (!(self = [super init])) {
    return nil;
  }
  
  _url = url;
  _asset = [AVAsset assetWithURL:_url];
  
  [self privateInit];
  
  return self;
}

- (instancetype)initWithAsset:(AVAsset *)asset
{
  if (!(self = [super init])) {
    return nil;
  }

  _asset = asset;
  _disableControls = NO;

  [self privateInit];

  return self;
}

- (void)privateInit
{

  _defaultControlsColor = [UIColor whiteColor];
  _cachedControls = [[NSMutableDictionary alloc] init];

  _videoNode = [[ASVideoNode alloc] init];
  _videoNode.asset = _asset;
  _videoNode.delegate = self;
  [self addSubnode:_videoNode];

  [self addObservers];
}

- (void)didLoad
{
  [super didLoad];
  {
    ASDN::MutexLocker l(_videoPlayerLock);
    [self createControls];
  }
}

- (NSArray*)createControlElementArray
{
  if (_delegateFlags.delegateNeededControls) {
    return [_delegate videoPlayerNodeNeededControls:self];
  }

  return @[ @(ASVideoPlayerNodeControlTypePlaybackButton),
            @(ASVideoPlayerNodeControlTypeElapsedText),
            @(ASVideoPlayerNodeControlTypeScrubber),
            @(ASVideoPlayerNodeControlTypeDurationText) ];
}

- (void)addObservers
{

}

- (void)removeObservers
{

}

#pragma mark - UI
- (void)createControls
{
  ASDN::MutexLocker l(_videoPlayerLock);

  if (_disableControls) {
    return;
  }

  if (_neededControls == nil) {
    _neededControls = [self createControlElementArray];
  }

  if (_cachedControls == nil) {
    _cachedControls = [[NSMutableDictionary alloc] init];
  }

  for (int i = 0; i < _neededControls.count; i++) {
    ASVideoPlayerNodeControlType type = (ASVideoPlayerNodeControlType)[[_neededControls objectAtIndex:i] integerValue];
    switch (type) {
      case ASVideoPlayerNodeControlTypePlaybackButton:
        [self createPlaybackButton];
        break;
      case ASVideoPlayerNodeControlTypeElapsedText:
        [self createElapsedTextField];
        break;
      case ASVideoPlayerNodeControlTypeDurationText:
        [self createDurationTextField];
        break;
      case ASVideoPlayerNodeControlTypeScrubber:
        [self createScrubber];
        break;
      case ASVideoPlayerNodeControlTypeFlexGrowSpacer:
        [self createControlFlexGrowSpacer];
        break;
      default:
        break;
    }
  }

  ASPerformBlockOnMainThread(^{
    ASDN::MutexLocker l(_videoPlayerLock);
    [self setNeedsLayout];
  });
}

- (void)removeControls
{
  NSArray *controls = [_cachedControls allValues];
  [controls enumerateObjectsUsingBlock:^(ASDisplayNode   *_Nonnull node, NSUInteger idx, BOOL * _Nonnull stop) {
    [node removeFromSupernode];
  }];

  [self cleanCachedControls];
}

- (void)cleanCachedControls
{
  [_cachedControls removeAllObjects];

  _playbackButtonNode = nil;
  _elapsedTextNode = nil;
  _durationTextNode = nil;
  _scrubberNode = nil;
}

- (void)createPlaybackButton
{
  if (_playbackButtonNode == nil) {
    _playbackButtonNode = [[ASDefaultPlaybackButton alloc] init];
    _playbackButtonNode.preferredFrameSize = CGSizeMake(16.0, 22.0);
    if (_delegateFlags.delegatePlaybackButtonTint) {
      _playbackButtonNode.tintColor = [_delegate videoPlayerNodePlaybackButtonTint:self];
    } else {
      _playbackButtonNode.tintColor = _defaultControlsColor;
    }
    [_playbackButtonNode addTarget:self action:@selector(playbackButtonTapped:) forControlEvents:ASControlNodeEventTouchUpInside];
    [_cachedControls setObject:_playbackButtonNode forKey:@(ASVideoPlayerNodeControlTypePlaybackButton)];
  }

  [self addSubnode:_playbackButtonNode];
}

- (void)createElapsedTextField
{
  if (_elapsedTextNode == nil) {
    _elapsedTextNode = [[ASTextNode alloc] init];
    _elapsedTextNode.attributedString = [self timeLabelAttributedStringForString:@"00:00" forControlType:ASVideoPlayerNodeControlTypeElapsedText];

    [_cachedControls setObject:_elapsedTextNode forKey:@(ASVideoPlayerNodeControlTypeElapsedText)];
  }
  [self addSubnode:_elapsedTextNode];
}

- (void)createDurationTextField
{
  if (_durationTextNode == nil) {
    _durationTextNode = [[ASTextNode alloc] init];
    _durationTextNode.attributedString = [self timeLabelAttributedStringForString:@"00:00" forControlType:ASVideoPlayerNodeControlTypeDurationText];

    [_cachedControls setObject:_durationTextNode forKey:@(ASVideoPlayerNodeControlTypeDurationText)];
  }
  [self addSubnode:_durationTextNode];
}

- (void)createScrubber
{
  if (_scrubberNode == nil) {
    _scrubberNode = [[ASDisplayNode alloc] initWithViewBlock:^UIView * _Nonnull{
      UISlider *slider = [[UISlider alloc] initWithFrame:CGRectZero];
      slider.minimumValue = 0.0;
      slider.maximumValue = 1.0;

      if (_delegateFlags.delegateScrubberMinimumTrackTintColor) {
        slider.minimumTrackTintColor  = [_delegate videoPlayerNodeScrubberMinimumTrackTint:self];
      }

      if (_delegateFlags.delegateScrubberMaximumTrackTintColor) {
        slider.maximumTrackTintColor  = [_delegate videoPlayerNodeScrubberMaximumTrackTint:self];
      }

      if (_delegateFlags.delegateScrubberThumbTintColor) {
        slider.thumbTintColor  = [_delegate videoPlayerNodeScrubberThumbTint:self];
      }

      if (_delegateFlags.delegateScrubberThumbImage) {
        UIImage *thumbImage = [_delegate videoPlayerNodeScrubberThumbImage:self];
        [slider setThumbImage:thumbImage forState:UIControlStateNormal];
      }


      [slider addTarget:self action:@selector(beganSeek) forControlEvents:UIControlEventTouchDown];
      [slider addTarget:self action:@selector(endedSeek) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];
      [slider addTarget:self action:@selector(changedSeekValue:) forControlEvents:UIControlEventValueChanged];

      return slider;
    }];

    _scrubberNode.flexShrink = YES;

    [_cachedControls setObject:_scrubberNode forKey:@(ASVideoPlayerNodeControlTypeScrubber)];
  }

  [self addSubnode:_scrubberNode];
}

- (void)createControlFlexGrowSpacer
{
  if (_controlFlexGrowSpacerSpec == nil) {
    _controlFlexGrowSpacerSpec = [[ASStackLayoutSpec alloc] init];
    _controlFlexGrowSpacerSpec.flexGrow = YES;
  }

  [_cachedControls setObject:_controlFlexGrowSpacerSpec forKey:@(ASVideoPlayerNodeControlTypeFlexGrowSpacer)];
}

- (void)updateDurationTimeLabel
{
  NSString *formatedDuration = [self timeStringForCMTime:_duration forTimeLabelType:ASVideoPlayerNodeControlTypeDurationText];
  _durationTextNode.attributedString = [self timeLabelAttributedStringForString:formatedDuration forControlType:ASVideoPlayerNodeControlTypeDurationText];
}

- (void)updateElapsedTimeLabel:(NSTimeInterval)seconds
{
  NSString *formatedDuration = [self timeStringForCMTime:CMTimeMakeWithSeconds( seconds, _videoNode.periodicTimeObserverTimescale ) forTimeLabelType:ASVideoPlayerNodeControlTypeElapsedText];
  _elapsedTextNode.attributedString = [self timeLabelAttributedStringForString:formatedDuration forControlType:ASVideoPlayerNodeControlTypeElapsedText];
}

- (NSAttributedString*)timeLabelAttributedStringForString:(NSString*)string forControlType:(ASVideoPlayerNodeControlType)controlType
{
  NSDictionary *options;
  if (_delegateFlags.delegateTimeLabelAttributes) {
    options = [_delegate videoPlayerNodeTimeLabelAttributes:self timeLabelType:controlType];
  } else {
    options = @{
                NSFontAttributeName : [UIFont systemFontOfSize:12.0],
                NSForegroundColorAttributeName: _defaultControlsColor
                };
  }


  NSAttributedString *attributedString = [[NSAttributedString alloc] initWithString:string attributes:options];

  return attributedString;
}

#pragma mark - ASVideoNodeDelegate
- (void)videoNode:(ASVideoNode *)videoNode willChangePlayerState:(ASVideoNodePlayerState)state toState:(ASVideoNodePlayerState)toState
{
  if (_delegateFlags.delegateVideoNodeWillChangeState) {
    [_delegate videoPlayerNode:self willChangeVideoNodeState:state toVideoNodeState:toState];
  }

  if (toState == ASVideoNodePlayerStateReadyToPlay && _durationTextNode) {
    _duration = _videoNode.currentItem.duration;
    [self updateDurationTimeLabel];
  }

  if (toState == ASVideoNodePlayerStatePlaying) {
    _playbackButtonNode.buttonType = ASDefaultPlaybackButtonTypePause;
  } else {
    _playbackButtonNode.buttonType = ASDefaultPlaybackButtonTypePlay;
  }
}

- (BOOL)videoNode:(ASVideoNode *)videoNode shouldChangePlayerStateTo:(ASVideoNodePlayerState)state
{
  if (_delegateFlags.delegateVideoNodeShouldChangeState) {
    return [_delegate videoPlayerNode:self shouldChangeVideoNodeStateTo:state];
  }
  return YES;
}

- (void)videoNode:(ASVideoNode *)videoNode didPlayToSecond:(NSTimeInterval)second
{
  //TODO: ask Max about CMTime problem in ASVideoNode Header file
  //as we said yesterday, we must use CMTime in ASVideoNode instead of NSTimeInterval
  //when this will be done, must just proxy value to delegate
  if (_delegateFlags.delegateVideoNodeDidPlayToTime) {
    [_delegate videoPlayerNode:self didPlayToTime:_videoNode.player.currentTime];
  }

  if (_isSeeking) {
    return;
  }

  if (_elapsedTextNode) {
    [self updateElapsedTimeLabel:second];
  }

  if (_scrubberNode) {
    [(UISlider*)_scrubberNode.view setValue:(second/ CMTimeGetSeconds(_duration) ) animated:NO];
  }
}

- (void)videoPlaybackDidFinish:(ASVideoNode *)videoNode
{
  if (_delegateFlags.delegateVideoNodePlaybackDidFinish) {
    [_delegate videoPlayerNodeDidPlayToEnd:self];
  }
}

- (void)videoNodeWasTapped:(ASVideoNode *)videoNode
{
  if (_delegateFlags.delegateVideoNodeTapped) {
    [_delegate videoPlayerNodeWasTapped:self];
  } else {
    if (videoNode.playerState == ASVideoNodePlayerStatePlaying) {
      [videoNode pause];
    } else {
      [videoNode play];
    }
  }
}

#pragma mark - Actions
- (void)playbackButtonTapped:(ASControlNode*)node
{
  if (_videoNode.playerState == ASVideoNodePlayerStatePlaying) {
    [_videoNode pause];
  } else {
    [_videoNode play];
  }
}

- (void)beganSeek
{
  _isSeeking = YES;
}

- (void)endedSeek
{
  _isSeeking = NO;
}

- (void)changedSeekValue:(UISlider*)slider
{
  CGFloat percentage = slider.value * 100;
  [self seekToTime:percentage];
}

#pragma mark - Public API
- (void)seekToTime:(CGFloat)percentComplete
{
  CGFloat seconds = ( CMTimeGetSeconds(_duration) * percentComplete ) / 100;

  [self updateElapsedTimeLabel:seconds];
  [_videoNode.player seekToTime:CMTimeMakeWithSeconds(seconds, _videoNode.periodicTimeObserverTimescale)];

  if (_videoNode.playerState != ASVideoNodePlayerStatePlaying) {
    [_videoNode play];
  }
}

- (void)play
{
  [_videoNode play];
}

- (void)pause
{
  [_videoNode pause];
}

- (BOOL)isPlaying
{
  return [_videoNode isPlaying];
}

- (NSArray *)controlsForLayoutSpec
{
  NSMutableArray *controls = [[NSMutableArray alloc] initWithCapacity:_cachedControls.count];

  if (_cachedControls[ @(ASVideoPlayerNodeControlTypePlaybackButton) ]) {
    [controls addObject:_cachedControls[ @(ASVideoPlayerNodeControlTypePlaybackButton) ]];
  }

  if (_cachedControls[ @(ASVideoPlayerNodeControlTypeElapsedText) ]) {
    [controls addObject:_cachedControls[ @(ASVideoPlayerNodeControlTypeElapsedText) ]];
  }

  if (_cachedControls[ @(ASVideoPlayerNodeControlTypeScrubber) ]) {
    [controls addObject:_cachedControls[ @(ASVideoPlayerNodeControlTypeScrubber) ]];
  }

  if (_cachedControls[ @(ASVideoPlayerNodeControlTypeDurationText) ]) {
    [controls addObject:_cachedControls[ @(ASVideoPlayerNodeControlTypeDurationText) ]];
  }

  return controls;
}

#pragma mark - Layout
- (ASLayoutSpec*)layoutSpecThatFits:(ASSizeRange)constrainedSize
{
  CGSize maxSize = constrainedSize.max;
  if (!CGSizeEqualToSize(self.preferredFrameSize, CGSizeZero)) {
    maxSize = self.preferredFrameSize;
  }

  // Prevent crashes through if infinite width or height
  if (isinf(maxSize.width) || isinf(maxSize.height)) {
    ASDisplayNodeAssert(NO, @"Infinite width or height in ASVideoPlayerNode");
    maxSize = CGSizeZero;
  }
  _videoNode.preferredFrameSize = maxSize;

  ASLayoutSpec *layoutSpec;

  if (_delegateFlags.delegateLayoutSpecForControls) {
    layoutSpec = [_delegate videoPlayerNodeLayoutSpec:self forControls:_cachedControls forMaximumSize:maxSize];
  } else {
    layoutSpec = [self defaultLayoutSpecThatFits:maxSize];
  }

  ASOverlayLayoutSpec *overlaySpec = [ASOverlayLayoutSpec overlayLayoutSpecWithChild:_videoNode overlay:layoutSpec];
  overlaySpec.sizeRange = ASRelativeSizeRangeMakeWithExactCGSize(maxSize);

  return [ASStaticLayoutSpec staticLayoutSpecWithChildren:@[overlaySpec]];
}

- (ASLayoutSpec*)defaultLayoutSpecThatFits:(CGSize)maxSize
{
  _scrubberNode.preferredFrameSize = CGSizeMake(maxSize.width, 44.0);

  ASLayoutSpec *spacer = [[ASLayoutSpec alloc] init];
  spacer.flexGrow = YES;

  ASStackLayoutSpec *controlbarSpec = [ASStackLayoutSpec stackLayoutSpecWithDirection:ASStackLayoutDirectionHorizontal
                                                                            spacing:10.0
                                                                     justifyContent:ASStackLayoutJustifyContentStart
                                                                         alignItems:ASStackLayoutAlignItemsCenter
                                                                           children: [self controlsForLayoutSpec] ];
  controlbarSpec.alignSelf = ASStackLayoutAlignSelfStretch;

  UIEdgeInsets insets = UIEdgeInsetsMake(10.0, 10.0, 10.0, 10.0);

  ASInsetLayoutSpec *controlbarInsetSpec = [ASInsetLayoutSpec insetLayoutSpecWithInsets:insets child:controlbarSpec];

  controlbarInsetSpec.alignSelf = ASStackLayoutAlignSelfStretch;

  ASStackLayoutSpec *mainVerticalStack = [ASStackLayoutSpec stackLayoutSpecWithDirection:ASStackLayoutDirectionVertical
                                                                                 spacing:0.0
                                                                          justifyContent:ASStackLayoutJustifyContentStart
                                                                              alignItems:ASStackLayoutAlignItemsStart
                                                                                children:@[spacer,controlbarInsetSpec]];

  return mainVerticalStack;
}

#pragma mark - Properties
- (id<ASVideoPlayerNodeDelegate>)delegate{
  return _delegate;
}

- (void)setDelegate:(id<ASVideoPlayerNodeDelegate>)delegate
{
  _delegate = delegate;
  
  if (_delegate == nil) {
    memset(&_delegateFlags, 0, sizeof(_delegateFlags));
  } else {
    _delegateFlags.delegateNeededControls = [_delegate respondsToSelector:@selector(videoPlayerNodeNeededControls:)];
    _delegateFlags.delegateScrubberMaximumTrackTintColor = [_delegate respondsToSelector:@selector(videoPlayerNodeScrubberMaximumTrackTint:)];
    _delegateFlags.delegateScrubberMinimumTrackTintColor = [_delegate respondsToSelector:@selector(videoPlayerNodeScrubberMinimumTrackTint:)];
    _delegateFlags.delegateScrubberThumbTintColor = [_delegate respondsToSelector:@selector(videoPlayerNodeScrubberThumbTint:)];
    _delegateFlags.delegateScrubberThumbImage = [_delegate respondsToSelector:@selector(videoPlayerNodeScrubberThumbImage:)];
    _delegateFlags.delegateTimeLabelAttributes = [_delegate respondsToSelector:@selector(videoPlayerNodeTimeLabelAttributes:timeLabelType:)];
    _delegateFlags.delegateLayoutSpecForControls = [_delegate respondsToSelector:@selector(videoPlayerNodeLayoutSpec:forControls:forMaximumSize:)];
    _delegateFlags.delegateVideoNodeDidPlayToTime = [_delegate respondsToSelector:@selector(videoPlayerNode:didPlayToTime:)];
    _delegateFlags.delegateVideoNodeWillChangeState = [_delegate respondsToSelector:@selector(videoPlayerNode:willChangeVideoNodeState:toVideoNodeState:)];
    _delegateFlags.delegateVideoNodePlaybackDidFinish = [_delegate respondsToSelector:@selector(videoPlayerNodeDidPlayToEnd:)];
    _delegateFlags.delegateVideoNodeShouldChangeState = [_delegate respondsToSelector:@selector(videoPlayerNode:shouldChangeVideoNodeStateTo:)];
    _delegateFlags.delegateTimeLabelAttributedString = [_delegate respondsToSelector:@selector(videoPlayerNode:timeStringForTimeLabelType:forTime:)];
    _delegateFlags.delegatePlaybackButtonTint = [_delegate respondsToSelector:@selector(videoPlayerNodePlaybackButtonTint:)];
    _delegateFlags.delegateVideoNodeTapped = [_delegate respondsToSelector:@selector(videoPlayerNodeWasTapped:)];
  }
}

- (void)setDisableControls:(BOOL)disableControls
{
  _disableControls = disableControls;

  if (_disableControls && _cachedControls.count > 0) {
    [self removeControls];
  } else if (!_disableControls) {
    [self createControls];
  }
}

- (void)setShouldAutoplay:(BOOL)shouldAutoplay
{
  _shouldAutoplay = shouldAutoplay;
  _videoNode.shouldAutoplay = _shouldAutoplay;
}

- (void)setShouldAutorepeat:(BOOL)shouldAutorepeat
{
  _shouldAutorepeat = shouldAutorepeat;
  _videoNode.shouldAutorepeat = YES;
}

- (void)setMuted:(BOOL)muted
{
  _muted = muted;
  _videoNode.muted = _muted;
}

- (void)setPeriodicTimeObserverTimescale:(int32_t)periodicTimeObserverTimescale
{
  _periodicTimeObserverTimescale = periodicTimeObserverTimescale;
  _videoNode.periodicTimeObserverTimescale = _periodicTimeObserverTimescale;
}

- (NSString*)gravity
{
  if (_gravity == nil) {
    _gravity = _videoNode.gravity;
  }
  return _gravity;
}

- (void)setGravity:(NSString *)gravity
{
  _gravity = gravity;
  _videoNode.gravity = _gravity;
}

- (ASVideoNodePlayerState)playerState
{
  return _videoNode.playerState;
}

#pragma mark - Helpers
- (NSString *)timeStringForCMTime:(CMTime)time forTimeLabelType:(ASVideoPlayerNodeControlType)type
{
  if (_delegateFlags.delegateTimeLabelAttributedString) {
    return [_delegate videoPlayerNode:self timeStringForTimeLabelType:type forTime:time];
  }

  NSUInteger dTotalSeconds = CMTimeGetSeconds(time);

  NSUInteger dHours = floor(dTotalSeconds / 3600);
  NSUInteger dMinutes = floor(dTotalSeconds % 3600 / 60);
  NSUInteger dSeconds = floor(dTotalSeconds % 3600 % 60);

  NSString *videoDurationText;
  if (dHours > 0) {
    videoDurationText = [NSString stringWithFormat:@"%i:%02i:%02i", (int)dHours, (int)dMinutes, (int)dSeconds];
  } else {
    videoDurationText = [NSString stringWithFormat:@"%02i:%02i", (int)dMinutes, (int)dSeconds];
  }
  return videoDurationText;
}

#pragma mark - Lifecycle

- (void)dealloc
{
  [self removeObservers];
}

@end
