// This file is part of Kiwix for iOS & macOS.
//
// Kiwix is free software; you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3 of the License, or
// any later version.
//
// Kiwix is distributed in the hope that it will be useful, but
// WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
// General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Kiwix; If not, see https://www.gnu.org/licenses/.

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#pragma clang diagnostic pop

#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#include <arpa/inet.h>
#import "KiwixHotspot.h"
#import "zim/archive.h"
#import "kiwix/library.h"
#import "kiwix/book.h"
#import "kiwix/server.h"
#import "ZimService.h"


@interface KiwixHotspot ()

@property kiwix::LibraryPtr library;
@property std::shared_ptr<kiwix::Server> server;

@end

@implementation KiwixHotspot

- (KiwixHotspot *_Nonnull) init {
    self = [super init];
    self.library = kiwix::Library::create();
    self.server = std::make_shared<kiwix::Server>(self.library);
    // Local Sharing is intentionally open on the selected LAN, but it should
    // remain a small phone-hosted reader rather than an unbounded web service.
    self.server->setNbThreads(4);
    self.server->setIpConnectionLimit(8);
    self.server->setMultiZimSearchLimit(25);
    self.server->setTaskbar(false, false);
    return self;
}

- (Boolean) startFor: (nonnull NSSet *) zimFileIDs onPort: (int) port {
    #if TARGET_OS_IOS
    // Keep the broad upstream overload out of the iOS runtime entirely. iOS
    // must enter through the explicit-address selector below. Clear any prior
    // listener before refusing the request so a failed replacement can never
    // leave stale content reachable.
    self.server->stop();
    [self removeAllBooksFromLibrary];
    NSLog(@"refusing to start the iOS hotspot without an explicit address");
    return false;
    #else
    // The macOS path retains upstream's all-interface behavior. Always reset
    // the address explicitly because the same server object may previously
    // have hosted an iOS-style scoped session.
    return [self startFor:zimFileIDs onAddress:@"" onPort:port];
    #endif
}

- (Boolean) startFor: (nonnull NSSet *) zimFileIDs
            onAddress: (nonnull NSString *) address
                onPort: (int) port {
    self.server->stop();
    [self removeAllBooksFromLibrary];
    #if TARGET_OS_IOS
    struct in_addr parsedAddress;
    const char *addressCString = [address UTF8String];
    if(addressCString == nullptr
       || inet_pton(AF_INET, addressCString, &parsedAddress) != 1
       || parsedAddress.s_addr == htonl(INADDR_ANY)
       || (ntohl(parsedAddress.s_addr) >> 24) == 127) {
        NSLog(@"refusing unsafe iOS hotspot bind address: %@", address);
        return false;
    }
    #endif
    bool loadedEverySelectedArchive = true;
    for (NSUUID *zimFileID in zimFileIDs) {
        try {
            // Hotspot.start is preceded by ZimFileService.openArchive on the
            // ZimActor. Never lazily insert here: SearchOperation may be
            // reading the shared archive map off-actor.
            zim::Archive * _Nullable archive = [[ZimService sharedInstance] findArchiveBy: zimFileID];
            if(archive != nullptr) {
                kiwix::Book book = kiwix::Book();
                book.update(*archive);
                // Keep the raw server's Book ID equal to the archive's
                // embedded UUID. ArkFile's stable app/Core Data alias is only
                // the lookup key used to select this registered archive.
                self.library->addBook(book);
            } else {
                NSLog(@"couldn't add to hotspot zimFileID: %@", zimFileID);
                loadedEverySelectedArchive = false;
            }
        } catch (std::exception &e) {
            NSLog(@"couldn't add zimFile to Hotspot: %@ because: %s", zimFileID, e.what());
            loadedEverySelectedArchive = false;
        }
    }
    if(loadedEverySelectedArchive
       && self.library->getBooksIds().size() == zimFileIDs.count
       && self.library->getBooksIds().size() > 0) {
        // An empty address resets libkiwix to its upstream AUTO/all-interface
        // behavior. iOS never calls this overload with an empty value: it
        // supplies one enumerated, approved IPv4 address for every start and
        // retry so a prior binding can never leak into a replacement session.
        self.server->setAddress([address UTF8String]);
        self.server->setPort(port);
        return self.server->start(); // this returns false if the port is occupied
    } else {
        NSLog(@"hotspot requires every selected registered ZIM archive");
        self.server->stop();
        [self removeAllBooksFromLibrary];
        return false;
    }
}

- (NSString *_Nullable) address {
    std::vector<std::string> urls = self.server->getServerAccessUrls();
    if (urls.size() > 0) {
        return [NSString stringWithUTF8String: urls[0].c_str()];
    } else {
        NSLog(@"no hotspot url was found");
        return nil;
    }
}

- (void) stop {
    self.server->stop();
    [self removeAllBooksFromLibrary];
}

- (void) removeAllBooksFromLibrary {
    for (std::string identifierC: self.library->getBooksIds()) {
        self.library->removeBookById(identifierC);
    }
}

@end
