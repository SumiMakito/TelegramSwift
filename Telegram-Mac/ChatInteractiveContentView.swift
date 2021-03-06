//
//  ChatMessagePhotoContent.swift
//  Telegram-Mac
//
//  Created by keepcoder on 18/09/16.
//  Copyright © 2016 Telegram. All rights reserved.
//

import Cocoa
import SwiftSignalKitMac
import PostboxMac
import TelegramCoreMac
import TGUIKit


class ChatInteractiveContentView: ChatMediaContentView {

    private let image:TransformImageView = TransformImageView()
    private var videoAccessory: ChatVideoAccessoryView? = nil
    private var progressView:RadialProgressView?
    private var timableProgressView: TimableProgressView? = nil
    private let statusDisposable = MetaDisposable()
    private let fetchDisposable = MetaDisposable()
    
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    required init(frame frameRect: NSRect) {
        super.init(frame:frameRect)
        self.addSubview(image)
    }
    
    
    override func open() {
        if let parent = parent, let account = account {
            let parameters = self.parameters as? ChatMediaGalleryParameters
            var type:GalleryAppearType = .history
            if let parameters = parameters, parameters.isWebpage {
                type = .alone
            } else if parent.containsSecretMedia {
                type = .secret
            }
            showChatGallery(account: account,message: parent, table, parameters, type: type)
        }
    }
    
    

    override func layout() {
        super.layout()
        progressView?.center()
        timableProgressView?.center()
        videoAccessory?.setFrameOrigin(5, 5)

        self.image.setFrameSize(frame.size)
    }

    override func update(with media: Media, size:NSSize, account:Account, parent:Message?, table:TableView?, parameters:ChatMediaLayoutParameters? = nil, animated: Bool) {
        
        let mediaUpdated = true//self.media == nil || !self.media!.isEqual(media)
        
        super.update(with: media, size: size, account: account, parent:parent, table:table, parameters:parameters)


        var updateImageSignal: Signal<(TransformImageArguments) -> DrawingContext?, NoError>?
        var updatedStatusSignal: Signal<MediaResourceStatus, NoError>?
        
        if mediaUpdated {
            
            var dimensions: NSSize = size
            
            if let image = media as? TelegramMediaImage {
                videoAccessory?.removeFromSuperview()
                videoAccessory = nil
                dimensions = image.representationForDisplayAtSize(size)?.dimensions ?? size
                
                if let parent = parent, parent.containsSecretMedia {
                    updateImageSignal = chatSecretPhoto(account: account, photo: image, scale: backingScaleFactor)
                } else {
                    updateImageSignal = chatMessagePhoto(account: account, photo: image, scale: backingScaleFactor)
                }
                
                if let parent = parent, parent.flags.contains(.Unsent) && !parent.flags.contains(.Failed) {
                    updatedStatusSignal = combineLatest(chatMessagePhotoStatus(account: account, photo: image), account.pendingMessageManager.pendingMessageStatus(parent.id))
                        |> map { resourceStatus, pendingStatus -> MediaResourceStatus in
                            if let pendingStatus = pendingStatus {
                                return .Fetching(isActive: true, progress: pendingStatus.progress)
                            } else {
                                return resourceStatus
                            }
                    } |> deliverOnMainQueue
                } else {
                    updatedStatusSignal = chatMessagePhotoStatus(account: account, photo: image) |> deliverOnMainQueue
                }
            
            } else if let file = media as? TelegramMediaFile {
                
                if file.isVideo {
                    if videoAccessory == nil {
                        videoAccessory = ChatVideoAccessoryView(frame: NSZeroRect)
                        addSubview(videoAccessory!)
                    }
                    videoAccessory?.updateText(String.durationTransformed(elapsed: file.videoDuration) + ", \(String.prettySized(with: file.size ?? 0))", maxWidth: size.width - 20)
                } else {
                    videoAccessory?.removeFromSuperview()
                    videoAccessory = nil
                }
                
                if let parent = parent, parent.containsSecretMedia {
                    updateImageSignal = chatSecretMessageVideo(account: account, video: file, scale: backingScaleFactor)
                } else {
                    updateImageSignal = chatMessageVideo(account: account, video: file, scale: backingScaleFactor)
                }
                
                dimensions = file.dimensions ?? size
                
                if let parent = parent, parent.flags.contains(.Unsent) && !parent.flags.contains(.Failed) {
                    updatedStatusSignal = combineLatest(chatMessageFileStatus(account: account, file: file), account.pendingMessageManager.pendingMessageStatus(parent.id))
                        |> map { resourceStatus, pendingStatus -> MediaResourceStatus in
                            if let pendingStatus = pendingStatus {
                                return .Fetching(isActive: true, progress: pendingStatus.progress)
                            } else {
                                return resourceStatus
                            }
                        } |> deliverOnMainQueue
                } else {
                    updatedStatusSignal = chatMessageFileStatus(account: account, file: file) |> deliverOnMainQueue
                }
            }
            
            let arguments = TransformImageArguments(corners: ImageCorners(radius:.cornerRadius), imageSize: dimensions, boundingSize: frame.size, intrinsicInsets: NSEdgeInsets())
            
             self.image.set(arguments: arguments)
            
            if !animated {
                self.image.setSignal(signal: cachedMedia(media: media, size: arguments.imageSize, scale: backingScaleFactor))
            }
            
            if let updateImageSignal = updateImageSignal {
                self.image.setSignal(account: account, signal: updateImageSignal, clearInstantly: false, animate: true, cacheImage: { [weak self] image in
                    if let strongSelf = self {
                        return cacheMedia(signal: image, media: media, size: arguments.imageSize, scale: strongSelf.backingScaleFactor)
                    } else {
                        return .complete()
                    }
                })
            }
        }
        
        

        
        if let updateStatusSignal = updatedStatusSignal {
            self.statusDisposable.set(updateStatusSignal.start(next: { [weak self] (status) in
                
                if let strongSelf = self {
                    strongSelf.fetchStatus = status
                    
                    var containsSecretMedia:Bool = false
                    
                    if let message = parent {
                        containsSecretMedia = message.containsSecretMedia
                    }
                    
                    if let _ = parent?.autoremoveAttribute?.countdownBeginTime {
                        strongSelf.progressView?.removeFromSuperview()
                        strongSelf.progressView = nil
                        if strongSelf.timableProgressView == nil {
                            strongSelf.timableProgressView = TimableProgressView()
                            strongSelf.addSubview(strongSelf.timableProgressView!)
                        }
                    } else {
                        strongSelf.timableProgressView?.removeFromSuperview()
                        strongSelf.timableProgressView = nil
                        
                        if case .Local = status, media is TelegramMediaImage, !containsSecretMedia {
                            self?.image.animatesAlphaOnFirstTransition = false
                            
                            if let progressView = strongSelf.progressView {
                                progressView.state = .Fetching(progress:1.0, force: false)
                                progressView.layer?.animateAlpha(from: 1, to: 0, duration: 0.2, removeOnCompletion:false, completion: { [weak strongSelf] (completion) in
                                    if completion {
                                        progressView.removeFromSuperview()
                                        strongSelf?.progressView = nil
                                    }
                                })
                            }
                        } else {
                            self?.image.animatesAlphaOnFirstTransition = true
                            strongSelf.progressView?.layer?.removeAllAnimations()
                            if strongSelf.progressView == nil {
                                let progressView = RadialProgressView(theme:RadialProgressTheme(backgroundColor: .blackTransparent, foregroundColor: .white, icon: playerPlayThumb))
                                progressView.frame = CGRect(origin: CGPoint(), size: CGSize(width: 40.0, height: 40.0))
                                strongSelf.progressView = progressView
                                strongSelf.addSubview(progressView)
                                strongSelf.progressView?.center()
                                progressView.fetchControls = strongSelf.fetchControls
                            }
                        }
                    }
                    
                    
                    
                    
                    switch status {
                    case let .Fetching(_, progress):
                        strongSelf.progressView?.state = .Fetching(progress: progress, force: false)
                    case .Local:
                        var state: RadialProgressState = .None
                        if containsSecretMedia {
                            state = .Icon(image: theme.icons.chatSecretThumb, mode:.destinationOut)
                            
                            if let attribute = parent?.autoremoveAttribute, let countdownBeginTime = attribute.countdownBeginTime {
                                let difference:TimeInterval = TimeInterval((countdownBeginTime + attribute.timeout)) - (CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970)
                                let start = difference / Double(attribute.timeout) * 100.0
                                strongSelf.timableProgressView?.theme = TimableProgressTheme(outer: 3, seconds: difference, start: start, border: false)
                                strongSelf.timableProgressView?.progress = 0
                                strongSelf.timableProgressView?.startAnimation()
                                
                            }
                        } else {
                            if let file = media as? TelegramMediaFile {
                                if file.isVideo {
                                    state = .Play
                                }
                            }
                        }
                        
                        strongSelf.progressView?.state = state
                    case .Remote:
                        strongSelf.progressView?.state = .Remote
                    }
                    strongSelf.needsLayout = true
                }
                
            }))
           
            if media is TelegramMediaImage {
                fetch()
            }
        }
        
    }
    
    override func setContent(size: NSSize) {
        super.setContent(size: size)
    }
    
    override func clean() {
        statusDisposable.dispose()
    }
    
    override func cancel() {
        fetchDisposable.set(nil)
        statusDisposable.set(nil)
    }
    
    override func cancelFetching() {
        if let account = account {
            if let media = media as? TelegramMediaFile {
                chatMessageFileCancelInteractiveFetch(account: account, file: media)
            } else if let media = media as? TelegramMediaImage {
                chatMessagePhotoCancelInteractiveFetch(account: account, photo: media)
            }
        }
        
    }
    override func fetch() {
        if let account = account {
            if let media = media as? TelegramMediaFile {
                fetchDisposable.set(chatMessageFileInteractiveFetched(account: account, file: media).start())
            } else if let media = media as? TelegramMediaImage {
                fetchDisposable.set(chatMessagePhotoInteractiveFetched(account: account, photo: media).start())
            }
        }
    }
    
    
    override func copy() -> Any {
        return image.copy()
    }
    
    
}
