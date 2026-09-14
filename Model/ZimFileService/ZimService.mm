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

#include <algorithm>
#include <cstdint>
#include <filesystem>
#include <unordered_map>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include "kiwix/book.h"
#include "kiwix/kiwix_config.h"
#include "zim/archive.h"
#include "zim/entry.h"
#include "zim/error.h"
#include "zim/item.h"
#include "kiwix/spelling_correction.h"
#pragma clang diagnostic pop

#import "ZimService.h"
#import "ZimFileMetaData.h"
#import "xapian.h"

namespace {
constexpr uint64_t arkFileSemanticProbeMaximumBytes = 4 * 1024;
constexpr uint64_t arkFileSemanticProbeMaximumEntries = 256;

bool arkFileItemHasReadablePrefix(zim::Entry entry) {
    try {
        zim::Item item = entry.getItem(entry.isRedirect());
        const uint64_t itemSize = item.getSize();
        if (itemSize == 0) {
            return false;
        }
        const uint64_t probeSize = std::min(
            itemSize,
            arkFileSemanticProbeMaximumBytes
        );
        zim::Blob prefix = item.getData(0, probeSize);
        return prefix.size() == probeSize;
    } catch (const std::exception &) {
        return false;
    }
}
} // namespace

@interface ZimService ()

@property (assign) std::unordered_map<std::string, zim::Archive> *archives; // (NSUUID_c: Archive)
@property (strong) NSMutableDictionary *fileURLs; // [NSUUID: URL]
@property (strong) NSMutableDictionary *logicalFileURLs; // [NSUUID: URL]
/// Preferred app alias for a registered physical path. Multiple aliases may
/// coexist briefly during cold-launch reconciliation; changing this pointer
/// never closes an archive that a search could still have pinned.
@property (strong) NSMutableDictionary<NSString *, NSUUID *> *preferredIdentifiersByPath;
@property (strong) NSMutableSet<NSUUID *> *securityScopedArchiveIDs;

- (void)stopSecurityScopeForArchive:(NSUUID *)zimFileID;
@end

@implementation ZimService

#pragma mark - init

- (instancetype)init {
    self = [super init];
    if (self) {
        // 16*1024*1024
        // as of:
        // https://github.com/kiwix/libkiwix/issues/1265#issuecomment-3817993025
        zim::setClusterCacheMaxSize(16777216);
        self.archives = new std::unordered_map<std::string, zim::Archive>();
        self.fileURLs = [[NSMutableDictionary alloc] init];
        self.logicalFileURLs = [[NSMutableDictionary alloc] init];
        self.preferredIdentifiersByPath = [[NSMutableDictionary alloc] init];
        self.securityScopedArchiveIDs = [[NSMutableSet alloc] init];
        self.libzimVersion = [[NSString alloc] initWithUTF8String:LIBZIM_VERSION];
        self.libkiwixVersion = [[NSString alloc] initWithUTF8String:LIBKIWIX_VERSION];
    }
    return self;
}

+ (ZimService *)sharedInstance {
    static ZimService *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[ZimService alloc] init];
    });
    return sharedInstance;
}

- (void)dealloc {
    delete self.archives;
    for (NSUUID *zimFileID in self.securityScopedArchiveIDs) {
        [self.fileURLs[zimFileID] stopAccessingSecurityScopedResource];
    }
}

#pragma mark - Reader Management

- (void)store:(NSURL *)url with:(NSUUID *)zimFileID {
    try {
        // if url does not ends with "zim", skip it
        NSString *pathExtension = [[url pathExtension] lowercaseString];
        if (![pathExtension isEqualToString:@"zim"]) {
            return;
        }
        @synchronized (self) {
            NSURL *oldURL = self.fileURLs[zimFileID];
            NSString *oldPath = [[[oldURL standardizedURL] URLByResolvingSymlinksInPath] path];
            if (oldPath != nil
                && [self.preferredIdentifiersByPath[oldPath] isEqual:zimFileID]) {
                [self.preferredIdentifiersByPath removeObjectForKey:oldPath];
            }
            self.fileURLs[zimFileID] = url;
            NSString *path = [[[url standardizedURL] URLByResolvingSymlinksInPath] path];
            if (path != nil) {
                // Latest explicit revalidation wins path lookup, but older
                // aliases/archives remain alive until their own owner closes
                // or unpins them.
                self.preferredIdentifiersByPath[path] = zimFileID;
            }
        }
    } catch (std::exception) {
        NSLog(@"Error opening zim file.");
    }
}

- (NSUUID *_Nullable)open:(NSUUID *)zimFileID {
    if ([self archiveBy:zimFileID] == nil) {
        return nil;
    }
    return zimFileID;
}

- (void)close:(NSUUID *)zimFileID {
    @synchronized (self) {
        NSURL *closingURL = self.fileURLs[zimFileID];
        NSString *closingPath = [[[closingURL standardizedURL] URLByResolvingSymlinksInPath] path];
        NSURL *logicalURL = self.logicalFileURLs[zimFileID];
        NSString *logicalPath = [[[logicalURL standardizedURL] URLByResolvingSymlinksInPath] path];
        self.archives->erase([self zimfileID_C: zimFileID]);
        [self stopSecurityScopeForArchive:zimFileID];
        [self.fileURLs removeObjectForKey:zimFileID];
        [self.logicalFileURLs removeObjectForKey:zimFileID];
        NSMutableSet<NSString *> *paths = [[NSMutableSet alloc] init];
        if (closingPath != nil) { [paths addObject:closingPath]; }
        if (logicalPath != nil) { [paths addObject:logicalPath]; }
        for (NSString *path in paths) {
            if (![self.preferredIdentifiersByPath[path] isEqual:zimFileID]) { continue; }
            [self.preferredIdentifiersByPath removeObjectForKey:path];
            for (NSUUID *candidateID in self.fileURLs) {
                NSURL *candidateURL = self.fileURLs[candidateID];
                NSString *candidatePath = [[
                    [candidateURL standardizedURL] URLByResolvingSymlinksInPath
                ] path];
                NSURL *candidateLogicalURL = self.logicalFileURLs[candidateID];
                NSString *candidateLogicalPath = [[
                    [candidateLogicalURL standardizedURL] URLByResolvingSymlinksInPath
                ] path];
                if ([candidatePath isEqualToString:path]
                    || [candidateLogicalPath isEqualToString:path]) {
                    self.preferredIdentifiersByPath[path] = candidateID;
                    break;
                }
            }
        }
    }
}

- (void)closeArchive:(NSUUID *)zimFileID {
    // Preserve the validated URL registration so the archive can be reopened
    // lazily on the next request without reparsing metadata or bookmarks.
    self.archives->erase([self zimfileID_C: zimFileID]);
    [self stopSecurityScopeForArchive:zimFileID];
}

- (Boolean)isArchiveOpen:(NSUUID *)zimFileID {
    // Callers uphold the global no-mutation-while-search-pinned invariant, so
    // this is a read-only lookup safe to use while SearchOperation reads the
    // same unordered_map off-actor.
    return [self findArchiveBy:zimFileID] != nil;
}

- (void)stopSecurityScopeForArchive:(NSUUID *)zimFileID {
    if ([self.securityScopedArchiveIDs containsObject:zimFileID]) {
        [self.fileURLs[zimFileID] stopAccessingSecurityScopedResource];
        [self.securityScopedArchiveIDs removeObject:zimFileID];
    }
}

- (NSArray *)getReaderIdentifiers {
    return [self.fileURLs allKeys];
}

- (nonnull void *) getArchives {
    NSLog(@"archives: %zu",  self.archives->size());
    return self.archives;
}

# pragma mark - Spelling
- (SpellingsDBWrapper *_Nullable)spellingsDBFor:(NSUUID *)zimFileID cachePath:(NSString *)contentPath {
    
    zim::Archive *archive = [self archiveBy: zimFileID];
    if (archive == nil) {
        NSLog(@"cannot find ZIM by ID: %@ (%@)", zimFileID.UUIDString, contentPath);
        return nil;
    }
    try {
        @synchronized (self) {
            NSLog(@"createSpellingIndex for:%@, in: %@", zimFileID.UUIDString, contentPath);
            // this should be safe for utf-8, it comes from swift URL.path(percentEncoded=True)
            std::filesystem::path path = std::filesystem::path([contentPath cStringUsingEncoding: NSUTF8StringEncoding]);
            auto db = std::make_unique<kiwix::SpellingsDB>(*archive, path);
            SpellingsDBWrapper *wrapper = [[SpellingsDBWrapper alloc] initWithDB: std::move(db)];
            return wrapper;
        }
    } catch (std::exception e) {
        NSLog(@"create spelling index exception: %s", e.what());
        return nil;
    } catch (Xapian::DatabaseError e) {
        NSLog(@"create spelling index exception no database found: %s", e.get_description().c_str());
        return nil;
    }
}

- (void) createSpellingIndex:(NSUUID *)zimFileID cachePath:(NSString *)contentPath {
    [self spellingsDBFor:zimFileID cachePath:contentPath];
}

# pragma mark - Metadata

+ (ZimFileMetaData *_Nullable)getMetaDataWithFileURL:(NSURL *)url {
    ZimFileMetaData *metaData = nil;
    [url startAccessingSecurityScopedResource];
    try {
        kiwix::Book book = kiwix::Book();
        book.update(zim::Archive([url fileSystemRepresentation]));
        // since we do have the ZIM file locally, we wan't the favicon as well
        metaData = [[ZimFileMetaData alloc] initWithBook: &book fetchFavicon: true];
    } catch (std::exception e) {
        [url stopAccessingSecurityScopedResource];
        return nil;
    }
    [url stopAccessingSecurityScopedResource];
    return metaData;
}

+ (Boolean)isSemanticallyReadableWithFileURL:(NSURL *)url {
    BOOL didStartSecurityScope = [url startAccessingSecurityScopedResource];
    Boolean isReadable = false;
    try {
        zim::Archive archive([url fileSystemRepresentation]);
        kiwix::Book book = kiwix::Book();
        book.update(archive);
        ZimFileMetaData *metaData = [[ZimFileMetaData alloc]
            initWithBook:&book
            fetchFavicon:false];
        if (metaData != nil && archive.getEntryCount() > 0) {
            // Force one cluster read without materializing an unbounded main
            // page or media object. A main entry is conventional but not
            // required, and an empty redirect target is not useful evidence,
            // so inspect a bounded number of user entries for a nonempty item.
            bool didReadRepresentativeContent = archive.hasMainEntry()
                && arkFileItemHasReadablePrefix(archive.getMainEntry());
            const uint64_t entriesToInspect = std::min(
                static_cast<uint64_t>(archive.getEntryCount()),
                arkFileSemanticProbeMaximumEntries
            );
            for (uint64_t index = 0;
                 !didReadRepresentativeContent && index < entriesToInspect;
                 ++index) {
                try {
                    didReadRepresentativeContent = arkFileItemHasReadablePrefix(
                        archive.getEntryByPath(index)
                    );
                } catch (const std::exception &) {
                    // A bad individual entry is not proof that every bounded
                    // representative is unreadable; continue the scan.
                }
            }
            isReadable = didReadRepresentativeContent;
        }
    } catch (std::exception) {
        isReadable = false;
    }
    if (didStartSecurityScope) {
        [url stopAccessingSecurityScopedResource];
    }
    return isReadable;
}

# pragma mark - URL Handling

- (NSURL *)getFileURL:(NSUUID *)zimFileID {
    @synchronized (self) {
        return self.fileURLs[zimFileID];
    }
}

- (void)setLogicalFileURL:(NSURL *)url forIdentifier:(NSUUID *)zimFileID {
    @synchronized (self) {
        NSURL *oldURL = self.logicalFileURLs[zimFileID];
        NSString *oldPath = [[[oldURL standardizedURL] URLByResolvingSymlinksInPath] path];
        if (oldPath != nil
            && [self.preferredIdentifiersByPath[oldPath] isEqual:zimFileID]) {
            [self.preferredIdentifiersByPath removeObjectForKey:oldPath];
        }
        self.logicalFileURLs[zimFileID] = url;
        NSString *path = [[[url standardizedURL] URLByResolvingSymlinksInPath] path];
        if (path != nil) {
            self.preferredIdentifiersByPath[path] = zimFileID;
        }
    }
}

- (NSUUID *_Nullable)registeredIdentifierForFileURL:(NSURL *)url {
    @synchronized (self) {
        NSString *targetPath = [[[url standardizedURL] URLByResolvingSymlinksInPath] path];
        if (targetPath == nil) { return nil; }
        NSUUID *preferred = self.preferredIdentifiersByPath[targetPath];
        if (preferred != nil && self.fileURLs[preferred] != nil) {
            return preferred;
        }
        for (NSUUID *candidateID in self.fileURLs) {
            NSURL *candidateURL = self.fileURLs[candidateID];
            NSString *candidatePath = [[
                [candidateURL standardizedURL] URLByResolvingSymlinksInPath
            ] path];
            NSURL *candidateLogicalURL = self.logicalFileURLs[candidateID];
            NSString *candidateLogicalPath = [[
                [candidateLogicalURL standardizedURL] URLByResolvingSymlinksInPath
            ] path];
            if ([candidatePath isEqualToString:targetPath]
                || [candidateLogicalPath isEqualToString:targetPath]) {
                self.preferredIdentifiersByPath[targetPath] = candidateID;
                return candidateID;
            }
        }
        return nil;
    }
}

- (NSString *_Nullable) getRedirectedPath:(NSUUID *_Nonnull)zimFileID contentPath:(NSString *_Nonnull)contentPath {
    zim::Archive *archive = [self archiveBy: zimFileID];
    if (archive == nil) { return nil; }
    try {
        const char *_Nullable contentPathC = [contentPath cStringUsingEncoding:NSUTF8StringEncoding];
        if (contentPathC != nil) {
            zim::Item item = archive->getEntryByPath(contentPathC).getRedirect();
            return [NSString stringWithUTF8String: item.getPath().c_str()];
        } else {
            return nil;
        }
    } catch (std::exception) {
        return nil;
    }
}

- (NSString *_Nullable)getMainPagePath:(NSUUID *)zimFileID {
    zim::Archive *archive = [self archiveBy: zimFileID];
    if (archive == nil) { return nil; }
    try {
        zim::Entry entry = archive->getMainEntry();
        zim::Item item = entry.getItem(entry.isRedirect());
        NSString *_Nullable pagePath = [NSString stringWithCString:item.getPath().c_str() encoding:NSUTF8StringEncoding];
        return pagePath;
    } catch (std::exception) {
        return nil;
    }
}

- (NSString *_Nullable)getRandomPagePath:(NSUUID *)zimFileID {
    zim::Archive *archive = [self archiveBy: zimFileID];
    if (archive == nil) { return nil; }
    try {
        zim::Entry entry = archive->getRandomEntry();
        zim::Item item = entry.getItem(entry.isRedirect());
        NSString *_Nullable pagePath = [NSString stringWithCString:item.getPath().c_str() encoding:NSUTF8StringEncoding];
        return pagePath;
    } catch (std::exception) {
        return nil;
    }
}

- (NSNumber* _Nullable)getContentSize:(NSUUID *)zimFileID contentPath:(NSString *)contentPath {
    try {
        zim::Item item = [self itemIn:zimFileID contentPath:contentPath];
        return [NSNumber numberWithUnsignedLongLong:item.getSize()];
    } catch (std::exception) {
        return nil;
    }
}

- (NSDictionary *)getMetaData:(NSUUID *)zimFileID contentPath:(NSString *)contentPath {
    try {
        zim::Item item = [self itemIn:zimFileID contentPath:contentPath];
        NSDate *modificationDate = [self getModificationDateOf: zimFileID];
        if(modificationDate == nil) {
            return nil;
        }
        return @{
            @"mime": [NSString stringWithUTF8String:item.getMimetype().c_str()],
            @"size": [NSNumber numberWithUnsignedLongLong:item.getSize()],
            @"title": [NSString stringWithUTF8String:item.getTitle().c_str()],
            @"zimFileDate": modificationDate
        };
    } catch (zim::EntryNotFound(EntryNotFound)) {
        return nil;
    } catch (std::exception) {
        return nil;
    }
}

- (NSDictionary *)getContent:(NSUUID *)zimFileID contentPath:(NSString *)contentPath
                       start:(NSUInteger)start end:(NSUInteger)end {
    try {
        zim::Item item = [self itemIn:zimFileID contentPath:contentPath];
        zim::Blob blob;
        if (start == 0 && end == 0) {
            blob = item.getData();
        } else if (end == 0) {
            blob = item.getData(start, item.getSize() - start);
        } else {
            blob = item.getData(start, fmin(item.getSize() - start, end - start + 1));
        }
        return @{
            @"data": [NSData dataWithBytes: blob.data() length:blob.size()],
            @"start": [NSNumber numberWithUnsignedLongLong:start],
            @"end": [NSNumber numberWithUnsignedLongLong:start + blob.size() - 1]
        };
    } catch (std::exception) {
        return nil;
    }
}

- (NSDictionary *_Nullable) getDirectAccess: (NSUUID *)zimFileID contentPath:(NSString *)contentPath {
    try {
        zim::Item item = [self itemIn:zimFileID contentPath: contentPath];
        zim::ItemDataDirectAccessInfo info = item.getDirectAccessInformation();
        return @{
            @"path": [NSString stringWithUTF8String: info.filename.c_str()],
            @"offset": [NSNumber numberWithUnsignedLong: info.offset]
        };
    } catch(std::exception) {
        return nil;
    }
}

# pragma mark - ZIM integrity check
- (Boolean) checkIntegrity: (NSUUID *_Nonnull) zimFileID {
    zim::Archive *archive = [self archiveBy: zimFileID];
    if (archive == nil) { return false; }
    return archive->checkIntegrity(zim::IntegrityCheck::CHECKSUM);
}

# pragma mark - private

/// Converts the UUID to a C representation
- (std::string) zimfileID_C: (NSUUID *_Nonnull) zimFileID {
    // should be safe for utf-8 encoding
    return [[[zimFileID UUIDString] lowercaseString] cStringUsingEncoding:NSUTF8StringEncoding];
}

/// Find or insert and return the archive by zimFileID
- (zim::Archive *_Nullable) archiveBy: (NSUUID *_Nonnull) zimFileID {
    zim::Archive *found = [self findArchiveBy:zimFileID];
    if(found == nil) {
        NSURL *url = self.fileURLs[zimFileID];
        if (url == nil) {
            return nil;
        }
        [self insertIntoArchives:url with:zimFileID];
        return [self findArchiveBy: zimFileID];
    } else {
        return found;
    }
}

/// Only find (no insertion of) the archive by zimFileID
- (zim::Archive *_Nullable) findArchiveBy: (NSUUID *_Nonnull) zimFileID {
    std::string zimFileID_C = [self zimfileID_C: zimFileID];
    auto found = self.archives->find(zimFileID_C);
    if (found == self.archives->end()) {
        return nil;
    }
    return &(found->second);
}

- (void) insertIntoArchives: (NSURL *_Nonnull) url with: (NSUUID *_Nonnull) zimFileID {
    BOOL didStartSecurityScope = [url startAccessingSecurityScopedResource];
    try {
        zim::Archive archive = zim::Archive([url fileSystemRepresentation]); // takes the longest time
        // The dictionary key is the stable app/Core Data UUID, not necessarily
        // the replacement archive's embedded UUID. This makes old tab URLs and
        // bookmarks reconstructible after relaunch from their retained file
        // bookmark while still reading the newly authoritative archive bytes.
        self.archives->insert_or_assign([self zimfileID_C:zimFileID], archive);
        if (didStartSecurityScope) {
            [self.securityScopedArchiveIDs addObject:zimFileID];
        }
    } catch (std::exception) {
        if (didStartSecurityScope) {
            [url stopAccessingSecurityScopedResource];
        }
        NSLog(@"cannot insert archive with: %@, %@", url.absoluteString, zimFileID.UUIDString);
    }
}

- (zim::Item) itemIn: (NSUUID *)zimFileID contentPath:(NSString *)contentPath {
    if ([contentPath hasPrefix:@"/"]) {
        contentPath = [contentPath substringFromIndex:1];
    }
    zim::Archive *archive = [self archiveBy: zimFileID];
    if (archive == nil) { throw std::exception(); }
    
    const char *_Nullable contentPath_c = [contentPath cStringUsingEncoding:NSUTF8StringEncoding];
    if (contentPath_c == nil) {
        throw std::exception();
    }
    zim::Entry entry = archive->getEntryByPath(contentPath_c);
    return entry.getItem(entry.isRedirect());
}

/// get the modification date of the ZIM file itself
- (NSDate *_Nullable) getModificationDateOf: (NSUUID *_Nonnull) zimFileID {
    NSURL *fileURL = [self getFileURL: zimFileID];
    if (fileURL == nil) {
        return nil;
    }
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    NSDictionary *fileAttributes = [fileManager attributesOfItemAtPath:[fileURL path] error:&error];
    if (fileAttributes) {
        return [fileAttributes objectForKey:NSFileModificationDate];
    } else {
        NSLog(@"Error retrieving file modification date: %@", [error localizedDescription]);
        return nil;
    }
}

@end
