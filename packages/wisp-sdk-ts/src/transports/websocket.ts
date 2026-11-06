import type { Transport, TransportReceiver } from '../link/transport.ts';

/** The parts of the WHATWG `WebSocket` we use (browsers, Node ≥ 22, React Native). */
export interface WebSocketLike {
  binaryType: string;
  readonly readyState: number;
  send(data: Uint8Array | ArrayBuffer): void;
  close(code?: number, reason?: string): void;
  onopen: ((ev: unknown) => void) | null;
  onmessage: ((ev: { data: unknown }) => void) | null;
  onclose: ((ev: unknown) => void) | null;
  onerror: ((ev: unknown) => void) | null;
}

export type WebSocketConstructor = new (url: string) => WebSocketLike;

export interface WebSocketTransportOptions {
  /** Defaults to the global `WebSocket`. */
  WebSocket?: WebSocketConstructor;
  /** Largest message we send. Default 65536. */
  mtu?: number;
}

const OPEN = 1;

/** Each binary WebSocket message carries a piece of the Wisp byte stream (simulator link). */
export class WebSocketTransport implements Transport {
  private receiver: TransportReceiver | undefined;
  readonly mtu: number;

  constructor(
    private readonly socket: WebSocketLike,
    opts: { mtu?: number } = {},
  ) {
    this.mtu = opts.mtu ?? 65536;
    socket.binaryType = 'arraybuffer';
    socket.onmessage = (ev) => {
      const d = ev.data;
      if (d instanceof ArrayBuffer) this.receiver?.onData(new Uint8Array(d));
      else if (ArrayBuffer.isView(d))
        this.receiver?.onData(
          new Uint8Array(d.buffer, d.byteOffset, d.byteLength),
        );
    };
    socket.onclose = () => this.receiver?.onClose();
    socket.onerror = () => this.receiver?.onClose(new Error('WebSocket error'));
  }

  static connect(
    url: string,
    opts: WebSocketTransportOptions = {},
  ): Promise<WebSocketTransport> {
    const Ctor =
      opts.WebSocket ??
      (globalThis as { WebSocket?: WebSocketConstructor }).WebSocket;
    if (!Ctor)
      return Promise.reject(
        new Error('no WebSocket here: pass opts.WebSocket'),
      );
    const socket = new Ctor(url);
    return new Promise((resolve, reject) => {
      socket.onopen = () => resolve(new WebSocketTransport(socket, opts));
      socket.onerror = () => reject(new Error(`could not connect to ${url}`));
    });
  }

  attach(receiver: TransportReceiver) {
    this.receiver = receiver;
  }

  async write(chunk: Uint8Array) {
    if (this.socket.readyState !== OPEN) throw new Error('WebSocket not open');
    this.socket.send(chunk);
  }

  async close() {
    this.socket.close();
  }
}
