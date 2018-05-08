/*
 * Copyright 2017 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "Firestore/Source/Local/FSTMemoryPersistence.h"

#include <unordered_map>

#include "absl/memory/memory.h"
#import "Firestore/Source/Core/FSTListenSequence.h"
#import "Firestore/Source/Local/FSTLRUGarbageCollector.h"
#import "Firestore/Source/Local/FSTMemoryMutationQueue.h"
#import "Firestore/Source/Local/FSTMemoryQueryCache.h"
#import "Firestore/Source/Local/FSTMemoryRemoteDocumentCache.h"
#import "Firestore/Source/Local/FSTReferenceSet.h"
#import "Firestore/Source/Util/FSTAssert.h"

#import "FSTDocument.h"
#import "FSTFieldValue.h"
#include "Firestore/core/src/firebase/firestore/auth/user.h"
#include "Firestore/core/src/firebase/firestore/model/database_id.h"
#include "Firestore/core/src/firebase/firestore/model/document_key.h"
#include "Firestore/core/src/firebase/firestore/model/resource_path.h"
#import "FSTEagerGarbageCollector.h"

using firebase::firestore::auth::HashUser;
using firebase::firestore::auth::User;
using firebase::firestore::model::DatabaseId;
using firebase::firestore::model::DocumentKey;
using firebase::firestore::model::ResourcePath;

NS_ASSUME_NONNULL_BEGIN

using MutationQueues = std::unordered_map<User, FSTMemoryMutationQueue *, HashUser>;

@interface FSTMemoryPersistence ()
@property(nonatomic, assign, getter=isStarted) BOOL started;

- (const MutationQueues &)mutationQueues;

@end

@implementation FSTMemoryPersistence {
  /**
   * The FSTQueryCache representing the persisted cache of queries.
   *
   * Note that this is retained here to make it easier to write tests affecting both the in-memory
   * and LevelDB-backed persistence layers. Tests can create a new FSTLocalStore wrapping this
   * FSTPersistence instance and this will make the in-memory persistence layer behave as if it
   * were actually persisting values.
   */
  FSTMemoryQueryCache *_queryCache;

  /** The FSTRemoteDocumentCache representing the persisted cache of remote documents. */
  FSTMemoryRemoteDocumentCache *_remoteDocumentCache;

  MutationQueues _mutationQueues;

  FSTTransactionRunner _transactionRunner;

  id<FSTReferenceDelegate> _referenceDelegate;
}

+ (instancetype)persistenceWithNoGC {
  return [[FSTMemoryPersistence alloc] initWithReferenceBlock:^id <FSTReferenceDelegate>(FSTMemoryPersistence *persistence) {
    return nil;
  }];
}

+ (instancetype)persistenceWithEagerGC {
  return [[FSTMemoryPersistence alloc] initWithReferenceBlock:^id <FSTReferenceDelegate>(FSTMemoryPersistence *persistence) {
    return [[FSTMemoryEagerReferenceDelegate alloc] initWithPersistence:persistence];
  }];
}

+ (instancetype)persistenceWithLRUGC {
  return [[FSTMemoryPersistence alloc] initWithReferenceBlock:^id <FSTReferenceDelegate>(FSTMemoryPersistence *persistence) {
    return [[FSTMemoryLRUReferenceDelegate alloc] initWithPersistence:persistence];
  }];
}

+ (size_t)valueSizeInMemory:(FSTFieldValue *)fieldValue {
  Class fieldClass = [fieldValue class];
  if (fieldClass == [FSTNullValue class]) {
    return 0;
  } else if (fieldClass == [FSTBooleanValue class]) {
    return sizeof(bool);
  } else if (fieldClass == [FSTIntegerValue class]) {
    return sizeof(int64_t);
  } else if (fieldClass == [FSTDoubleValue class]) {
    return sizeof(double);
  } else if (fieldClass == [FSTStringValue class]) {
    return [fieldValue.value length];
  } else if (fieldClass == [FSTTimestampValue class]) {
    return sizeof(int64_t) + sizeof(int32_t);
  } else if (fieldClass == [FSTGeoPointValue class]) {
    return 2 * sizeof(double);
  } else if (fieldClass == [FSTBlobValue class]) {
    return ((NSData *)fieldValue.value).length;
  } else if (fieldClass == [FSTReferenceValue class]) {
    return sizeof(DatabaseId) +
           [FSTMemoryPersistence pathSizeInMemory:((FSTDocumentKey *)fieldValue.value).path];
  } else if (fieldClass == [FSTObjectValue class]) {
    return [FSTMemoryPersistence objectValueSizeInMemory:(FSTObjectValue *)fieldValue];
  } else if (fieldClass == [FSTArrayValue class]) {
    size_t result = 0;
    NSArray<FSTFieldValue *> *elems = (NSArray<FSTFieldValue *> *)fieldValue.value;
    for (FSTFieldValue *elem in elems) {
      result += [FSTMemoryPersistence valueSizeInMemory:elem];
    }
    return result;
  }
  FSTFail(@"Unknown FieldValue type: %@", fieldClass);
}

+ (size_t)objectValueSizeInMemory:(FSTObjectValue *)object {
  __block size_t result = 0;
  [object.internalValue
      enumerateKeysAndObjectsUsingBlock:^(NSString *key, FSTFieldValue *value, BOOL *stop) {
        result += key.length;
        result += [FSTMemoryPersistence valueSizeInMemory:value];
      }];
  return result;
}

+ (size_t)docSizeInMemory:(FSTMaybeDocument *)doc {
  size_t result = [FSTMemoryPersistence pathSizeInMemory:doc.key.path()];
  if ([doc isKindOfClass:[FSTDocument class]]) {
    FSTObjectValue *value = ((FSTDocument *)doc).data;
    result += [FSTMemoryPersistence objectValueSizeInMemory:value];
  }
  return result;
}

+ (size_t)pathSizeInMemory:(const ResourcePath &)path {
  size_t result = 0;
  for (auto it = path.begin(); it != path.end(); it++) {
    result += it->size();
  }
  return result;
}

- (instancetype)initWithReferenceBlock:(id<FSTReferenceDelegate> (^)(FSTMemoryPersistence *persistence))block {
  if (self = [super init]) {
    _queryCache = [[FSTMemoryQueryCache alloc] initWithPersistence:self];
    _referenceDelegate = block(self);
    _remoteDocumentCache = [[FSTMemoryRemoteDocumentCache alloc] init];
    id delegate = _referenceDelegate;
    if ([delegate conformsToProtocol:@protocol(FSTTransactional)]) {
      _transactionRunner.SetBackingPersistence((id<FSTTransactional>)_referenceDelegate);
    }
  }
  return self;
}

- (BOOL)start:(NSError **)error {
  // No durable state to read on startup.
  FSTAssert(!self.isStarted, @"FSTMemoryPersistence double-started!");
  self.started = YES;
  return YES;
}

- (void)shutdown {
  // No durable state to ensure is closed on shutdown.
  FSTAssert(self.isStarted, @"FSTMemoryPersistence shutdown without start!");
  self.started = NO;
  _referenceDelegate = nil;
}

- (const FSTTransactionRunner &)run {
  return _transactionRunner;
}

- (id<FSTReferenceDelegate>)referenceDelegate {
  return _referenceDelegate;
}

- (id<FSTMutationQueue>)mutationQueueForUser:(const User &)user {
  id<FSTMutationQueue> queue = _mutationQueues[user];
  if (!queue) {
    queue = [[FSTMemoryMutationQueue alloc] initWithPersistence:self];
    _mutationQueues[user] = queue;
  }
  return queue;
}

- (const std::unordered_map<User, FSTMemoryMutationQueue *, HashUser>&)mutationQueues {
  return _mutationQueues;
}

- (id<FSTQueryCache>)queryCache {
  return _queryCache;
}

- (id<FSTRemoteDocumentCache>)remoteDocumentCache {
  return _remoteDocumentCache;
}

- (long)byteSize {
  long bytes = [_queryCache byteSize] + [_remoteDocumentCache byteSize];
  for (auto it = _mutationQueues.begin(); it != _mutationQueues.end(); ++it) {
    bytes += [it->second byteSize];
  }
  return bytes;
}

@end

@implementation FSTMemoryLRUReferenceDelegate {
  FSTMemoryPersistence *_persistence;
  NSMutableDictionary<FSTDocumentKey *, NSNumber *> *_sequenceNumbers;
  FSTReferenceSet *_additionalReferences;
  FSTLRUGarbageCollector *_gc;
  FSTListenSequenceNumber _currentSequenceNumber;
  FSTListenSequence *_listenSequence;
}

- (instancetype)initWithPersistence:(FSTMemoryPersistence *)persistence {
  if (self = [super init]) {
    _sequenceNumbers = [NSMutableDictionary dictionary];
    _persistence = persistence;
    _gc = [[FSTLRUGarbageCollector alloc] initWithQueryCache:[_persistence queryCache]
                                                    delegate:self
                                                  thresholds:FSTLRUThreshold::Defaults()
                                                         now:0];
    _currentSequenceNumber = kFSTListenSequenceNumberInvalid;
    FSTListenSequenceNumber highestSequenceNumber = _persistence.queryCache.highestListenSequenceNumber;
    _listenSequence = [[FSTListenSequence alloc] initStartingAfter:highestSequenceNumber];
  }
  return self;
}

- (FSTLRUGarbageCollector *)gc {
  return _gc;
}

- (void)addInMemoryPins:(FSTReferenceSet *)set {
  // Technically can't assert this, due to restartWithNoopGarbageCollector (for now...)
  //FSTAssert(_additionalReferences == nil, @"Overwriting additional references");
  _additionalReferences = set;
}

- (void)removeTarget:(FSTQueryData *)queryData {
  FSTQueryData *updated = [queryData queryDataByReplacingSnapshotVersion:queryData.snapshotVersion
                                                             resumeToken:queryData.resumeToken
                                                          sequenceNumber:[self sequenceNumber]];
  [_persistence.queryCache updateQueryData:updated];
}

- (void)limboDocumentUpdated:(FSTDocumentKey *)key {
  _sequenceNumbers[key] = @([self sequenceNumber]);
  // TODO(gsoltis): probably need to implement this
  // Need to bump sequence number?
}


- (void)startTransaction:(absl::string_view __unused)label {
  FSTAssert(_currentSequenceNumber == kFSTListenSequenceNumberInvalid, @"Previous sequence number is still in effect");
  _currentSequenceNumber = [_listenSequence next];
}

- (void)commitTransaction {
  _currentSequenceNumber = kFSTListenSequenceNumberInvalid;
}

- (FSTListenSequenceNumber)sequenceNumber {
  FSTAssert(_currentSequenceNumber != kFSTListenSequenceNumberInvalid, @"Asking for a sequence number outside of a transaction");
  return _currentSequenceNumber;
}

- (void)enumerateTargetsUsingBlock:(void (^)(FSTQueryData *queryData, BOOL *stop))block {
  return [_persistence.queryCache enumerateTargetsUsingBlock:block];
}

- (void)enumerateMutationsUsingBlock:(void (^)(FSTDocumentKey *key, FSTListenSequenceNumber sequenceNumber, BOOL *stop))block {
  [_sequenceNumbers enumerateKeysAndObjectsUsingBlock:^(FSTDocumentKey *key, NSNumber *seq, BOOL *stop) {
    FSTListenSequenceNumber sequenceNumber = [seq longLongValue];
    if (![self->_persistence.queryCache containsKey:key]) {
      block(key, sequenceNumber, stop);
    }
  }];
}

- (NSUInteger)removeQueriesThroughSequenceNumber:(FSTListenSequenceNumber)sequenceNumber
                                     liveQueries:(NSDictionary<NSNumber *, FSTQueryData *> *)liveQueries {
  return [_persistence.queryCache removeQueriesThroughSequenceNumber:sequenceNumber liveQueries:liveQueries];
}

- (NSUInteger)removeOrphanedDocumentsThroughSequenceNumber:(FSTListenSequenceNumber)upperBound {
  return [(FSTMemoryRemoteDocumentCache *)_persistence.remoteDocumentCache removeOrphanedDocuments:self
                                                                             throughSequenceNumber:upperBound];
}

- (void)addReference:(FSTDocumentKey *)key target:(FSTTargetID)targetID {
  _sequenceNumbers[key] = @([self sequenceNumber]);
}

- (void)removeReference:(FSTDocumentKey *)key target:(FSTTargetID)targetID {
  // No-op. LRU doesn't care when references are removed.
}


- (BOOL)mutationQueuesContainKey:(FSTDocumentKey *)key {
  const MutationQueues& queues = [_persistence mutationQueues];
  for (auto it = queues.begin(); it != queues.end(); ++it) {
    if ([it->second containsKey:key]) {
      return YES;
    }
  }
  return NO;
}

- (void)removeMutationReference:(FSTDocumentKey *)key {
  _sequenceNumbers[key] = @([self sequenceNumber]);
}

- (BOOL)isPinnedAtSequenceNumber:(FSTListenSequenceNumber)upperBound document:(FSTDocumentKey *)key {
  if ([self mutationQueuesContainKey:key]) {
    return YES;
  }
  if ([_additionalReferences containsKey:key]) {
    return YES;
  }
  if ([_persistence.queryCache containsKey:key]) {
    return YES;
  }
  NSNumber *orphaned = _sequenceNumbers[key];
  if (orphaned && [orphaned longLongValue] > upperBound) {
    return YES;
  }
  return NO;
}


@end

@implementation FSTMemoryEagerReferenceDelegate {
  std::unique_ptr<std::set<FSTDocumentKey *> > _orphaned;
  FSTMemoryPersistence *_persistence;
  FSTReferenceSet *_additionalReferences;
}

- (instancetype)initWithPersistence:(FSTMemoryPersistence *)persistence {
  if (self = [super init]) {
    _persistence = persistence;
  }
  return self;
}

- (void)addInMemoryPins:(FSTReferenceSet *)set {
  // Technically can't assert this, due to restartWithNoopGarbageCollector (for now...)
  //FSTAssert(_additionalReferences == nil, @"Overwriting additional references");
  _additionalReferences = set;
}

- (void)removeTarget:(FSTQueryData *)queryData {
  for (const DocumentKey &docKey : [_persistence.queryCache matchingKeysForTargetID:queryData.targetID]) {
    FSTDocumentKey *key = docKey;
    self->_orphaned->insert(key);
  }
  [_persistence.queryCache removeQueryData:queryData];
}


- (void)addReference:(FSTDocumentKey *)key
              target:(__unused FSTTargetID)targetID {
  _orphaned->erase(key);
}

- (void)removeReference:(FSTDocumentKey *)key
                 target:(__unused FSTTargetID)targetID {
  _orphaned->insert(key);
}

- (void)removeMutationReference:(FSTDocumentKey *)key {
  _orphaned->insert(key);
}

- (BOOL)isReferenced:(FSTDocumentKey *)key {
  if ([[_persistence queryCache] containsKey:key]) {
    return YES;
  }
  if ([self mutationQueuesContainKey:key]) {
    return YES;
  }
  if ([_additionalReferences containsKey:key]) {
    return YES;
  }
  return NO;
}

- (void)limboDocumentUpdated:(FSTDocumentKey *)key {
  if ([self isReferenced:key]) {
    _orphaned->erase(key);
  } else {
    _orphaned->insert(key);
  }
}


- (void)startTransaction:(__unused absl::string_view)label {
  _orphaned = absl::make_unique<std::set<FSTDocumentKey *> >();
}

- (BOOL)mutationQueuesContainKey:(FSTDocumentKey *)key {
  const MutationQueues& queues = [_persistence mutationQueues];
  for (auto it = queues.begin(); it != queues.end(); ++it) {
    if ([it->second containsKey:key]) {
      return YES;
    }
  }
  return NO;
}

- (void)commitTransaction {
  for (auto it = _orphaned->begin(); it != _orphaned->end(); ++it) {
    FSTDocumentKey *key = *it;
    if (![self isReferenced:key]) {
      [[_persistence remoteDocumentCache] removeEntryForKey:key];
    }
  }
  _orphaned.reset();
}

@end

NS_ASSUME_NONNULL_END
