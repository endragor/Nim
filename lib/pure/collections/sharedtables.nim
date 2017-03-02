#
#
#            Nim's Runtime Library
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Shared table support for Nim. Use plain old non GC'ed keys and values or
## you'll be in trouble. Uses a single lock to protect the table, lockfree
## implementations welcome but if lock contention is so high that you need a
## lockfree hash table, you're doing it wrong.

import
  hashes, math, locks, options

include "system/inclrtl"

type
  KeyValuePair[A, B] = tuple[hcode: Hash, key: A, val: B]
  KeyValuePairSeq[A, B] = ptr array[10_000_000, KeyValuePair[A, B]]
  SharedTable* [A, B] = object ## generic hash SharedTable
    data: KeyValuePairSeq[A, B]
    counter, dataLen: int
    lock: Lock

  ComputeAction* {.pure.} = enum
    Keep,
    Del

template maxHash(t): expr = t.dataLen-1

include tableimpl

proc enlarge[A, B](t: var SharedTable[A, B]) =
  let oldSize = t.dataLen
  let size = oldSize * growthFactor
  var n = cast[KeyValuePairSeq[A, B]](allocShared0(
                                      sizeof(KeyValuePair[A, B]) * size))
  t.dataLen = size
  swap(t.data, n)
  for i in 0..<oldSize:
    let eh = n[i].hcode
    if isFilled(eh):
      var j: Hash = eh and maxHash(t)
      while isFilled(t.data[j].hcode):
        j = nextTry(j, maxHash(t))
      rawInsert(t, t.data, n[i].key, n[i].val, eh, j)
  deallocShared(n)

template withLock(t, x: untyped) =
  acquire(t.lock)
  x
  release(t.lock)

template withValue*[A, B](t: var SharedTable[A, B], key: A,
                          value, body: untyped) =
  ## retrieves the value at ``t[key]``.
  ## `value` can be modified in the scope of the ``withValue`` call.
  ##
  ## .. code-block:: nim
  ##
  ##   sharedTable.withValue(key, value) do:
  ##     # block is executed only if ``key`` in ``t``
  ##     # value is threadsafe in block
  ##     value.name = "username"
  ##     value.uid = 1000
  ##
  acquire(t.lock)
  try:
    var hc: Hash
    var index = rawGet(t, key, hc)
    let hasKey = index >= 0
    if hasKey:
      var value {.inject.} = addr(t.data[index].val)
      body
  finally:
    release(t.lock)

template withValue*[A, B](t: var SharedTable[A, B], key: A,
                          value, body1, body2: untyped) =
  ## retrieves the value at ``t[key]``.
  ## `value` can be modified in the scope of the ``withValue`` call.
  ##
  ## .. code-block:: nim
  ##
  ##   sharedTable.withValue(key, value) do:
  ##     # block is executed only if ``key`` in ``t``
  ##     # value is threadsafe in block
  ##     value.name = "username"
  ##     value.uid = 1000
  ##   do:
  ##     # block is executed when ``key`` not in ``t``
  ##     raise newException(KeyError, "Key not found")
  ##
  acquire(t.lock)
  try:
    var hc: Hash
    var index = rawGet(t, key, hc)
    let hasKey = index >= 0
    if hasKey:
      var value {.inject.} = addr(t.data[index].val)
      body1
    else:
      body2
  finally:
    release(t.lock)

proc mget*[A, B](t: var SharedTable[A, B], key: A): var B =
  ## retrieves the value at ``t[key]``. The value can be modified.
  ## If `key` is not in `t`, the ``KeyError`` exception is raised.
  withLock t:
    var hc: Hash
    var index = rawGet(t, key, hc)
    let hasKey = index >= 0
    if hasKey: result = t.data[index].val
  if not hasKey:
    when compiles($key):
      raise newException(KeyError, "key not found: " & $key)
    else:
      raise newException(KeyError, "key not found")

proc mgetOrPut*[A, B](t: var SharedTable[A, B], key: A, val: B): var B =
  ## retrieves value at ``t[key]`` or puts ``val`` if not present, either way
  ## returning a value which can be modified. **Note**: This is inherently
  ## unsafe in the context of multi-threading since it returns a pointer
  ## to ``B``.
  withLock t:
    mgetOrPutImpl(enlarge)

proc hasKeyOrPut*[A, B](t: var SharedTable[A, B], key: A, val: B): bool =
  ## returns true iff `key` is in the table, otherwise inserts `value`.
  withLock t:
    hasKeyOrPutImpl(enlarge)

proc compute*[A, B](t: var SharedTable[A, B], key: A,
                    mapper: proc(key: A, val: Option[B]):
                      (Option[B], ComputeAction)): Option[B] =
  ## Computes a new mapping for the ``key`` with the specified ``mapper``
  ## procedure.
  ##
  ## The ``mapper`` takes the key and the current value (if present) as
  ## parameters and returns a pair of a new value and an action.
  ## If the action is ``ComputeAction.Del``, the key is removed from the table.
  ## If the action is ``CopmuteAction.Keep``, the key is added or updated.
  ## The value returned by ``compute`` is always the value returned by
  ## the ``mapper``.
  ##
  ## The operation is performed atomically and other operations on the table
  ## will be blocked while the ``mapper`` is invoked, so it should be short and
  ## simple.
  withLock t:
    var hc: Hash
    var index = rawGet(t, key, hc)
    # mapper must be invoked before enlarging, because it may
    # return none() or raise
    let curVal = if index >= 0: some(t.data[index].val)
                 else: none(type(t.data[0].val))
    # if the key exists, call mapper with the actual key, because identity
    # can be important.
    let mapperRet = if index >= 0: mapper(t.data[index].key, curVal)
                    else: mapper(key, curVal)
    result = mapperRet[0]
    case mapperRet[1]:
    of ComputeAction.Del:
      if index >= 0:
        delImplIdx(t, index)
    of ComputeAction.Keep:
      if result.isSome():
        let val = result.unsafeGet()
        if index >= 0:
          t.data[index].val = val
        else:
          maybeRehashPutImpl(enlarge)

proc `[]=`*[A, B](t: var SharedTable[A, B], key: A, val: B) =
  ## puts a (key, value)-pair into `t`.
  withLock t:
    putImpl(enlarge)

proc add*[A, B](t: var SharedTable[A, B], key: A, val: B) =
  ## puts a new (key, value)-pair into `t` even if ``t[key]`` already exists.
  withLock t:
    addImpl(enlarge)

proc del*[A, B](t: var SharedTable[A, B], key: A) =
  ## deletes `key` from hash table `t`.
  withLock t:
    delImpl()

proc initSharedTable*[A, B](initialSize=64): SharedTable[A, B] =
  ## creates a new hash table that is empty.
  ##
  ## `initialSize` needs to be a power of two. If you need to accept runtime
  ## values for this you could use the ``nextPowerOfTwo`` proc from the
  ## `math <math.html>`_ module or the ``rightSize`` proc from this module.
  assert isPowerOfTwo(initialSize)
  result.counter = 0
  result.dataLen = initialSize
  result.data = cast[KeyValuePairSeq[A, B]](allocShared0(
                                      sizeof(KeyValuePair[A, B]) * initialSize))
  initLock result.lock

proc deinitSharedTable*[A, B](t: var SharedTable[A, B]) =
  deallocShared(t.data)
  deinitLock t.lock
