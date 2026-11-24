'use strict';

// The pools own their entries and close operations; slots share the cap,
// eviction queue and idle timers. Claude supplies its background-work policy.
function createSessionSlots({
  live,
  maxLive,
  idleMs,
  closeEntry,
  isBusy = (entry) => entry.turn,
  keepAlive = () => false,
  isAlwaysOn = () => false,
  evictsBefore = (a, b) => a.lastActivity < b.lastActivity,
}) {
  const slotWaiters = [];

  function releaseSlot() {
    const waiter = slotWaiters.shift();
    if (waiter) waiter();
  }

  function ordinaryLiveCount() {
    let count = 0;
    for (const key of live.keys()) {
      if (!isAlwaysOn(key)) count += 1;
    }
    return count;
  }

  function lruIdleEntry() {
    let victim = null;
    for (const entry of live.values()) {
      if (isBusy(entry) || entry.closed || isAlwaysOn(entry.key)) continue;
      if (!victim || evictsBefore(entry, victim)) victim = entry;
    }
    return victim;
  }

  // A finished turn frees the session for eviction but not the slot: the
  // session stays live. Group chats summon several members at once, so without
  // this a caller waiting on the cap would never be woken by a turn ending —
  // only by an unrelated eviction.
  function pumpWaiters() {
    if (!slotWaiters.length) return;
    if (ordinaryLiveCount() < maxLive) {
      releaseSlot();
      return;
    }
    const victim = lruIdleEntry();
    if (victim) closeEntry(victim).catch(() => {});
  }

  async function acquireSlot(key) {
    if (key != null && isAlwaysOn(key)) return;
    // The cap covers every non-always-on live session the pool owns. When they
    // are all mid-turn there is nothing safe to evict, so the caller waits for
    // a slot rather than the pool quietly exceeding its own memory budget.
    while (ordinaryLiveCount() >= maxLive) {
      const victim = lruIdleEntry();
      if (victim) {
        await closeEntry(victim);
        continue;
      }
      await new Promise((resolve) => slotWaiters.push(resolve));
    }
  }

  function clearIdleTimer(entry) {
    if (entry.idleTimer) clearTimeout(entry.idleTimer);
    entry.idleTimer = null;
  }

  function scheduleIdleClose(entry) {
    clearIdleTimer(entry);
    if (entry.closed) return;
    entry.idleTimer = setTimeout(() => {
      if (isBusy(entry)) return;
      // Background work or an always-on pin keeps the session alive; check again later.
      if (keepAlive(entry) || isAlwaysOn(entry.key)) return scheduleIdleClose(entry);
      closeEntry(entry).catch(() => {});
    }, idleMs);
    if (typeof entry.idleTimer.unref === 'function') entry.idleTimer.unref();
  }

  return {
    acquireSlot,
    releaseSlot,
    pumpWaiters,
    clearIdleTimer,
    scheduleIdleClose,
    get waiting() { return slotWaiters.length; },
  };
}

module.exports = { createSessionSlots };
