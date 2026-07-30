export default {
  mounted() {
    this.cacheDir = null;
    this.initPromise = this._init();
  },

  async _init() {
    try {
      const root = await navigator.storage.getDirectory();
      this.cacheDir = root;
    } catch (err) {
      console.warn("OPFS not available:", err.message);
      this.cacheDir = null;
    }
  },

  // Store a blob by key
  async put(key, blob) {
    if (!this.cacheDir) return;
    try {
      const handle = await this.cacheDir.getFileHandle(key, { create: true });
      const writable = await handle.createWritable();
      await writable.write(blob);
      await writable.close();
    } catch (err) {
      // Quota exceeded — degrade gracefully, not throw
      console.warn("OPFS put failed (likely quota):", err.message);
    }
  },

  // Retrieve a blob by key
  async get(key) {
    if (!this.cacheDir) return null;
    try {
      const handle = await this.cacheDir.getFileHandle(key);
      const file = await handle.getFile();
      return file;
    } catch {
      return null;  // Not found or error — cache miss
    }
  },

  // Evict a single key
  async evict(key) {
    if (!this.cacheDir) return;
    try {
      await this.cacheDir.removeEntry(key);
    } catch {
      // Ignore — not found is fine
    }
  },

  // List all cache entries
  async keys() {
    if (!this.cacheDir) return [];
    const entries = [];
    for await (const [name] of this.cacheDir.entries()) {
      entries.push(name);
    }
    return entries;
  },

  // Clear entire cache
  async clear() {
    if (!this.cacheDir) return;
    for await (const [name] of this.cacheDir.entries()) {
      await this.cacheDir.removeEntry(name).catch(() => {});
    }
  },

  // Check approximate usage vs quota
  async storageInfo() {
    if (!navigator.storage.estimate) return null;
    try {
      const estimate = await navigator.storage.estimate();
      return {
        usage: estimate.usage,
        quota: estimate.quota,
        percent: estimate.quota > 0 ? (estimate.usage / estimate.quota) * 100 : 0
      };
    } catch {
      return null;
    }
  },

  // Put with LRU tracking: store a metadata file listing access order
  async putLRU(key, blob, maxEntries = 100) {
    await this.put(key, blob);

    // Update LRU list
    const lruKey = '__opfs_lru__';
    let lru = await this.get(lruKey);
    let entries = [];
    if (lru) {
      try {
        const text = await lru.text();
        entries = JSON.parse(text);
      } catch { entries = []; }
    }

    // Remove existing entry for this key
    entries = entries.filter(e => e !== key);
    // Add to front (most recent)
    entries.unshift(key);

    // Evict least-recently-used if over limit
    while (entries.length > maxEntries) {
      const oldKey = entries.pop();
      await this.evict(oldKey);
    }

    // Persist LRU list
    const lruBlob = new Blob([JSON.stringify(entries)], { type: 'application/json' });
    await this.put(lruKey, lruBlob);
  },

  // Get with LRU promotion
  async getLRU(key) {
    const blob = await this.get(key);
    if (blob) {
      // Promote in LRU on access (fire-and-forget)
      this._promoteLRU(key).catch(() => {});
    }
    return blob;
  },

  async _promoteLRU(key) {
    const lruKey = '__opfs_lru__';
    const lru = await this.get(lruKey);
    if (!lru) return;
    try {
      const text = await lru.text();
      let entries = JSON.parse(text);
      entries = entries.filter(e => e !== key);
      entries.unshift(key);
      const lruBlob = new Blob([JSON.stringify(entries)], { type: 'application/json' });
      await this.put(lruKey, lruBlob);
    } catch {}
  },

  // Quota guard: check before putting
  async hasQuota(requiredBytes = 1024 * 1024) {
    const info = await this.storageInfo();
    if (!info) return true;  // Can't check — allow
    const remaining = info.quota - info.usage;
    return remaining >= requiredBytes;
  }
};
