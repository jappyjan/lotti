/** A tiny typed event emitter. `on` returns a function that unsubscribes. */
export class Emitter<E extends { [K in keyof E]: unknown }> {
  private readonly listeners = new Map<keyof E, Set<(value: never) => void>>();

  on<K extends keyof E>(type: K, fn: (value: E[K]) => void): () => void {
    let set = this.listeners.get(type);
    if (!set) this.listeners.set(type, (set = new Set()));
    set.add(fn);
    return () => this.off(type, fn);
  }

  once<K extends keyof E>(type: K, fn: (value: E[K]) => void): () => void {
    const off = this.on(type, (v) => {
      off();
      fn(v);
    });
    return off;
  }

  off<K extends keyof E>(type: K, fn: (value: E[K]) => void) {
    this.listeners.get(type)?.delete(fn);
  }

  listenerCount(type: keyof E): number {
    return this.listeners.get(type)?.size ?? 0;
  }

  /** A throwing listener doesn't stop the others; its error is rethrown async. */
  emit<K extends keyof E>(type: K, value: E[K]) {
    for (const fn of [...(this.listeners.get(type) ?? [])]) {
      try {
        (fn as (v: E[K]) => void)(value);
      } catch (err) {
        void Promise.reject(err);
      }
    }
  }
}
