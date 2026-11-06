/** What a transport delivers to the link. */
export interface TransportReceiver {
  onData(chunk: Uint8Array): void;
  onClose(error?: Error): void;
}

/**
 * A byte stream to one temple. Writes may split or join frames freely: the
 * link reassembles. Implementations: Web Bluetooth (GATT), WebSocket
 * (simulator), loopback (tests). A Node BLE transport (e.g. on top of
 * `@abandonware/noble`) only needs to implement this interface: write chunks
 * of at most `mtu` bytes to the RX characteristic without response and pass
 * TX notifications to `onData`.
 */
export interface Transport {
  /** Largest chunk one `write` may carry (ATT MTU − 3 for GATT). */
  readonly mtu: number;
  /** Registers the receiver; called once, before the first write. */
  attach(receiver: TransportReceiver): void;
  write(chunk: Uint8Array): Promise<void>;
  close(): Promise<void>;
}
