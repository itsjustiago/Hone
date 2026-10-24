// HoneNowPlaying: the "now playing" source for the Island, loaded INTO /usr/bin/perl.
//
// Since macOS 15.4 the private MediaRemote framework only answers processes that
// carry an Apple entitlement; anyone else gets an empty dictionary. /usr/bin/perl
// is a platform binary (bundle id com.apple.perl) that is allowed to ask, so the
// Hone runs `perl -e <loader> <this dylib>` and the loader calls `hone_np_stream`
// through DynaLoader. This library is NOT linked into the Hone itself.
//
// Hone -> adapter (stdin, one command per line):
//   toggle | play | pause | next | previous | seek <seconds>
// EOF on stdin makes the adapter _exit(0): that is how it dies with the Hone, even
// if the Hone crashes.
//
// Adapter -> Hone (stdout, one JSON object per line, UTF-8, "\n"-terminated).
// This format is mirrored by NowPlayingProtocol.swift in the Hone; change both.
//   {"empty":true}                    nothing is playing
//   {"title":str, "artist":str, "album":str,   each omitted when unknown
//    "duration":sec,                  omitted when unknown, live or 0
//    "elapsed":sec,                   playback position as of "elapsedAt"
//    "elapsedAt":unixSec,             MediaRemote's own timestamp, else the read time
//    "rate":number,                   1 = normal speed, 0 = paused
//    "playing":bool,
//    "pid":int,                       now-playing app; omitted when 0
//    "bundleID":str,                  parent app for web content (Safari, Chrome),
//                                     else the client itself; omitted when unknown
//    "contentID":str,                 omitted when unknown
//    "artwork":base64}                only when the bytes changed since the last line
//                                     for this track (and always on a new track). At
//                                     most 300 px a side (bigger covers are shrunk and
//                                     sent as PNG); omitted if the image won't decode.
// The Hone's track id is contentID, or title + U+001F + artist when there is none;
// `trackKey` below must stay identical, because the artwork is re-sent exactly when
// that key changes.
//
// stderr carries diagnostics only. Fatal setup problem: one line and exit(3).

#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include <dlfcn.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include "HoneNowPlaying.h"

#if !__has_feature(objc_arc)
#error HoneNowPlaying.m must be built with ARC
#endif

// MRMediaRemoteCommand values (the private enum is not in any header).
enum { kHNPPlay = 0, kHNPPause = 1, kHNPToggle = 2, kHNPNext = 4, kHNPPrevious = 5 };

// Bursts of notifications (one track change fires several) become one read.
static const double kCoalesceSeconds = 0.1;
// A MediaRemote callback that never comes must not wedge the reader for good.
static const int64_t kFetchTimeoutNanos = 3 * NSEC_PER_SEC;
// ...but it is worth asking again: after a timeout the next read comes this much later.
static const int64_t kRetryAfterTimeoutNanos = 2 * NSEC_PER_SEC;
// The cover is drawn at a few dozen points. Originals can be many MB (4K, TIFF) and
// every line carries it as base64, so anything over this is shrunk before it is sent.
static const double kMaxArtworkPixels = 300;
static const NSUInteger kMaxArtworkBytes = 1024 * 1024;
// Refuse to decode anything bigger than this (a decompression bomb).
static const double kMaxArtworkSourcePixels = 64e6;

static void (*gRegister)(dispatch_queue_t);
static void (*gGetInfo)(dispatch_queue_t, void (^)(CFDictionaryRef));
static void (*gGetIsPlaying)(dispatch_queue_t, void (^)(Boolean));
static void (*gGetPID)(dispatch_queue_t, void (^)(int));
static Boolean (*gSendCommand)(int, id);
static void (*gSetElapsed)(double);
// Optional: without them the Hone resolves the app from the pid.
static void (*gGetClient)(dispatch_queue_t, void (^)(id));
static CFStringRef (*gClientBundle)(CFTypeRef);
static CFStringRef (*gClientParentBundle)(CFTypeRef);

static dispatch_semaphore_t gWake;

// Only the reader thread touches these.
static NSString *gLastKey;
static NSData *gLastArtwork;
static NSData *gLastBody;

static void fail(const char *what) {
    fprintf(stderr, "HoneNowPlaying: MediaRemote has no %s\n", what);
    exit(3);
}

static void *need(void *lib, const char *name) {
    void *p = dlsym(lib, name);
    if (!p) fail(name);
    return p;
}

static NSString *needName(void *lib, const char *name) {
    CFStringRef *p = (CFStringRef *)need(lib, name);
    return (__bridge NSString *)*p;
}

static NSString *text(NSDictionary *info, NSString *key) {
    id v = info[key];
    return ([v isKindOfClass:[NSString class]] && [v length] > 0) ? v : nil;
}

static NSNumber *number(NSDictionary *info, NSString *key) {
    id v = info[key];
    if (![v isKindOfClass:[NSNumber class]] || !isfinite([v doubleValue])) return nil;
    return v;
}

// Mirrors NowPlayingTrack.id in the Hone (see the header comment).
static NSString *trackKey(NSString *contentID, NSString *title, NSString *artist) {
    if (contentID.length > 0) return contentID;
    return [@[title ?: @"", artist ?: @""] componentsJoinedByString:@"\x1f"];
}

static void writeLine(NSData *json) {
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
    // The Hone went away (or closed the pipe): nobody is listening any more. _exit,
    // not exit: this runs on a secondary thread, possibly while another one is
    // leaving too, and exit() running the atexit handlers twice at once is undefined.
    if (ferror(stdout)) _exit(0);
}

static NSData *serialize(NSDictionary *object) {
    NSError *error = nil;
    // Sorted keys keep the body byte-identical between reads, which the dedupe needs.
    NSData *json = [NSJSONSerialization dataWithJSONObject:object
                                                   options:NSJSONWritingSortedKeys
                                                     error:&error];
    if (!json) fprintf(stderr, "HoneNowPlaying: JSON failed: %s\n", error.localizedDescription.UTF8String);
    return json;
}

static void emitEmpty(void) {
    // Forget the track so the same one coming back gets its artwork again.
    gLastKey = nil;
    gLastArtwork = nil;
    NSData *body = serialize(@{ @"empty": @YES });
    if (body && ![body isEqualToData:gLastBody]) {
        gLastBody = body;
        writeLine(body);
    }
}

// The bytes to send for a cover: the original when it is already small, else a PNG
// thumbnail of at most kMaxArtworkPixels. nil when the image does not decode (or is
// absurdly big): better no cover than megabytes the Hone cannot use.
static NSData *artworkForWire(NSData *original) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)original, NULL);
    if (!source) return nil;
    NSData *result = nil;
    if (CGImageSourceGetCount(source) > 0) {
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
        NSNumber *width = properties[(__bridge id)kCGImagePropertyPixelWidth];
        NSNumber *height = properties[(__bridge id)kCGImagePropertyPixelHeight];
        double w = [width isKindOfClass:[NSNumber class]] ? width.doubleValue : 0;
        double h = [height isKindOfClass:[NSNumber class]] ? height.doubleValue : 0;
        if (w >= 1 && h >= 1 && w * h <= kMaxArtworkSourcePixels) {
            if (fmax(w, h) <= kMaxArtworkPixels && original.length <= kMaxArtworkBytes) {
                result = original;
            } else {
                NSDictionary *options = @{
                    (__bridge id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                    (__bridge id)kCGImageSourceThumbnailMaxPixelSize: @(kMaxArtworkPixels),
                    (__bridge id)kCGImageSourceCreateThumbnailWithTransform: @YES,
                };
                CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(
                    source, 0, (__bridge CFDictionaryRef)options);
                if (thumbnail) {
                    NSMutableData *png = [NSMutableData data];
                    CGImageDestinationRef destination = CGImageDestinationCreateWithData(
                        (__bridge CFMutableDataRef)png, CFSTR("public.png"), 1, NULL);
                    if (destination) {
                        CGImageDestinationAddImage(destination, thumbnail, NULL);
                        if (CGImageDestinationFinalize(destination) && png.length > 0) result = png;
                        CFRelease(destination);
                    }
                    CGImageRelease(thumbnail);
                }
            }
        }
    }
    CFRelease(source);
    return result;
}

static void emit(NSDictionary *info, BOOL playing, int pid, NSString *bundleID) {
    NSString *title = text(info, @"kMRMediaRemoteNowPlayingInfoTitle");
    NSString *artist = text(info, @"kMRMediaRemoteNowPlayingInfoArtist");
    NSString *album = text(info, @"kMRMediaRemoteNowPlayingInfoAlbum");
    if (title == nil && artist == nil) { emitEmpty(); return; }

    NSString *contentID = text(info, @"kMRMediaRemoteNowPlayingInfoContentItemIdentifier");
    NSString *key = trackKey(contentID, title, artist);
    if (![key isEqualToString:gLastKey]) {
        gLastKey = key;
        gLastArtwork = nil;
    }

    NSMutableDictionary *line = [NSMutableDictionary dictionary];
    if (title) line[@"title"] = title;
    if (artist) line[@"artist"] = artist;
    if (album) line[@"album"] = album;
    if (contentID) line[@"contentID"] = contentID;
    if (bundleID.length > 0) line[@"bundleID"] = bundleID;
    if (pid > 0) line[@"pid"] = @(pid);

    NSNumber *duration = number(info, @"kMRMediaRemoteNowPlayingInfoDuration");
    if (duration && duration.doubleValue > 0) line[@"duration"] = duration;
    line[@"elapsed"] = number(info, @"kMRMediaRemoteNowPlayingInfoElapsedTime") ?: @0;
    NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    if (![stamp isKindOfClass:[NSDate class]]) stamp = [NSDate date];
    line[@"elapsedAt"] = @(stamp.timeIntervalSince1970);
    line[@"rate"] = number(info, @"kMRMediaRemoteNowPlayingInfoPlaybackRate") ?: @(playing ? 1 : 0);
    line[@"playing"] = @(playing);

    NSData *body = serialize(line);
    if (!body) return;

    NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    BOOL newArtwork = [art isKindOfClass:[NSData class]] && art.length > 0
        && ![art isEqualToData:gLastArtwork];
    if (!newArtwork && [body isEqualToData:gLastBody]) return;

    gLastBody = body;
    if (newArtwork) {
        // Remember the ORIGINAL bytes: that is what the next read is compared with, so
        // a cover is shrunk once, not on every update (and a bad one is not retried).
        gLastArtwork = art;
        NSData *cover = artworkForWire(art);
        if (cover) {
            line[@"artwork"] = [cover base64EncodedStringWithOptions:0];
            body = serialize(line);
            if (!body) return;
        }
    }
    writeLine(body);
}

// Reads everything MediaRemote knows and writes at most one line.
static void refresh(void) {
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    dispatch_group_t group = dispatch_group_create();
    __block NSDictionary *info = nil;
    __block BOOL playing = NO;
    __block int pid = 0;
    __block NSString *bundleID = nil;

    dispatch_group_enter(group);
    gGetInfo(queue, ^(CFDictionaryRef dict) {
        info = dict ? [(__bridge NSDictionary *)dict copy] : nil;
        dispatch_group_leave(group);
    });
    dispatch_group_enter(group);
    gGetIsPlaying(queue, ^(Boolean value) {
        playing = value;
        dispatch_group_leave(group);
    });
    dispatch_group_enter(group);
    gGetPID(queue, ^(int value) {
        pid = value;
        dispatch_group_leave(group);
    });
    if (gGetClient && gClientBundle && gClientParentBundle) {
        dispatch_group_enter(group);
        gGetClient(queue, ^(id client) {
            if (client) {
                NSString *parent = (__bridge NSString *)gClientParentBundle((__bridge CFTypeRef)client);
                NSString *own = (__bridge NSString *)gClientBundle((__bridge CFTypeRef)client);
                // The parent app is what the user sees (Safari, not WebKit.WebContent).
                bundleID = parent.length > 0 ? parent : own;
            }
            dispatch_group_leave(group);
        });
    }

    if (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, kFetchTimeoutNanos)) != 0) {
        fprintf(stderr, "HoneNowPlaying: MediaRemote did not answer in time\n");
        // Nothing else would wake the reader (it waits for notifications), so ask
        // again later; the delay plus the timeout keeps this from becoming a tight loop.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kRetryAfterTimeoutNanos), queue, ^{
            dispatch_semaphore_signal(gWake);
        });
        return;
    }
    if (info.count == 0) emitEmpty();
    else emit(info, playing, pid, bundleID);
}

static void readerLoop(void) {
    for (;;) {
        dispatch_semaphore_wait(gWake, DISPATCH_TIME_FOREVER);
        [NSThread sleepForTimeInterval:kCoalesceSeconds];
        while (dispatch_semaphore_wait(gWake, DISPATCH_TIME_NOW) == 0) {}
        @autoreleasepool { refresh(); }
    }
}

static void runCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *name = parts.firstObject;
    int command = -1;
    if ([name isEqualToString:@"toggle"]) command = kHNPToggle;
    else if ([name isEqualToString:@"play"]) command = kHNPPlay;
    else if ([name isEqualToString:@"pause"]) command = kHNPPause;
    else if ([name isEqualToString:@"next"]) command = kHNPNext;
    else if ([name isEqualToString:@"previous"]) command = kHNPPrevious;

    if (command >= 0) {
        // MediaRemote is happiest on the thread that registered for notifications.
        dispatch_async(dispatch_get_main_queue(), ^{ gSendCommand(command, nil); });
    } else if ([name isEqualToString:@"seek"] && parts.count == 2) {
        // strtod, not -doubleValue: that answers 0 for garbage, and 0 is a valid seek.
        const char *argument = parts[1].UTF8String;
        char *end = NULL;
        double seconds = strtod(argument, &end);
        if (end == argument || *end != '\0' || !isfinite(seconds) || seconds < 0) {
            fprintf(stderr, "HoneNowPlaying: bad seek value: %s\n", line.UTF8String);
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ gSetElapsed(seconds); });
    } else {
        fprintf(stderr, "HoneNowPlaying: unknown command: %s\n", line.UTF8String);
        return;
    }
    // A command usually changes what is playing; the notification may be late.
    dispatch_semaphore_signal(gWake);
}

static void commandLoop(void) {
    char *buffer = NULL;
    size_t capacity = 0;
    while (getline(&buffer, &capacity, stdin) != -1) {
        @autoreleasepool {
            NSString *line = [NSString stringWithUTF8String:buffer];
            line = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (line.length > 0) runCommand(line);
        }
    }
    // EOF: the Hone is gone. _exit for the same reason as in writeLine.
    _exit(0);
}

__attribute__((visibility("default")))
void hone_np_stream(void *perl, void *cv) {
    (void)perl; (void)cv;
    // A write to a pipe nobody reads must fail with an error, not kill us mid-line.
    signal(SIGPIPE, SIG_IGN);

    void *lib = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!lib) fail("framework (dlopen failed)");

    gRegister = need(lib, "MRMediaRemoteRegisterForNowPlayingNotifications");
    gGetInfo = need(lib, "MRMediaRemoteGetNowPlayingInfo");
    gGetIsPlaying = need(lib, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    gGetPID = need(lib, "MRMediaRemoteGetNowPlayingApplicationPID");
    gSendCommand = need(lib, "MRMediaRemoteSendCommand");
    gSetElapsed = need(lib, "MRMediaRemoteSetElapsedTime");
    gGetClient = dlsym(lib, "MRMediaRemoteGetNowPlayingClient");
    gClientBundle = dlsym(lib, "MRNowPlayingClientGetBundleIdentifier");
    gClientParentBundle = dlsym(lib, "MRNowPlayingClientGetParentAppBundleIdentifier");

    NSArray<NSString *> *names = @[
        needName(lib, "kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
        needName(lib, "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
        needName(lib, "kMRMediaRemoteNowPlayingApplicationDidChangeNotification"),
    ];

    gWake = dispatch_semaphore_create(0);
    for (NSString *name in names) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(NSNotification *note) {
            dispatch_semaphore_signal(gWake);
        }];
    }
    gRegister(dispatch_get_main_queue());

    // First read at launch; later ones come from the notifications.
    dispatch_semaphore_signal(gWake);
    [NSThread detachNewThreadWithBlock:^{ readerLoop(); }];
    [NSThread detachNewThreadWithBlock:^{ commandLoop(); }];

    // CFRunLoopRun returns at once when the loop has no source or timer; a far-off
    // timer keeps it alive without ever waking the process.
    [NSTimer scheduledTimerWithTimeInterval:86400 repeats:YES block:^(NSTimer *timer) {}];
    CFRunLoopRun();
    // Contract: never return into Perl.
    dispatch_main();
}
