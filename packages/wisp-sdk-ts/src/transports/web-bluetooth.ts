import type { Transport, TransportReceiver } from '../link/transport.ts';

/** GATT layout of the Wisp service. */
export const WISP_GATT = {
  service: 'cf099bf1-f34e-49e2-b353-7f20e02243bc',
  /** Phone → glasses, write without response. */
  rx: 'cf099bf2-f34e-49e2-b353-7f20e02243bc',
  /** Glasses → phone, notify. */
  tx: 'cf099bf3-f34e-49e2-b353-7f20e02243bc',
} as const;

// Minimal structural types, so the core needs no DOM typings.
interface Characteristic {
  value?: DataView | null;
  writeValueWithoutResponse(data: Uint8Array): Promise<void>;
  startNotifications(): Promise<Characteristic>;
  addEventListener(
    type: 'characteristicvaluechanged',
    fn: (ev: { target: unknown }) => void,
  ): void;
}
interface GattServer {
  connected: boolean;
  connect(): Promise<GattServer>;
  disconnect(): void;
  getPrimaryService(uuid: string): Promise<{
    getCharacteristic(uuid: string): Promise<Characteristic>;
  }>;
}
export interface BluetoothDeviceLike {
  name?: string;
  gatt?: GattServer;
  addEventListener(type: 'gattserverdisconnected', fn: () => void): void;
}
export interface BluetoothLike {
  requestDevice(options: {
    filters: { services?: string[]; namePrefix?: string }[];
    optionalServices?: string[];
  }): Promise<BluetoothDeviceLike>;
}

export interface WebBluetoothOptions {
  /** ATT MTU. Web Bluetooth doesn't expose the negotiated one; Wisp asks for 247. */
  mtu?: number;
  /** Narrow the chooser to names with this prefix. */
  namePrefix?: string;
  /** Defaults to `navigator.bluetooth`. */
  bluetooth?: BluetoothLike;
}

/** Wisp over GATT with Web Bluetooth. One instance per temple. */
export class WebBluetoothTransport implements Transport {
  private receiver: TransportReceiver | undefined;
  readonly mtu: number;

  private constructor(
    readonly device: BluetoothDeviceLike,
    private readonly server: GattServer,
    private readonly rx: Characteristic,
    mtu: number,
  ) {
    this.mtu = mtu - 3;
  }

  /** Shows the browser's device chooser (needs a user gesture) and connects. */
  static async request(
    opts: WebBluetoothOptions = {},
  ): Promise<WebBluetoothTransport> {
    const bluetooth =
      opts.bluetooth ??
      (globalThis as { navigator?: { bluetooth?: BluetoothLike } }).navigator
        ?.bluetooth;
    if (!bluetooth) throw new Error('Web Bluetooth is not available here');
    const filter = opts.namePrefix
      ? { namePrefix: opts.namePrefix }
      : { services: [WISP_GATT.service] };
    const device = await bluetooth.requestDevice({
      filters: [filter],
      optionalServices: [WISP_GATT.service],
    });
    return WebBluetoothTransport.connect(device, opts);
  }

  static async connect(
    device: BluetoothDeviceLike,
    opts: Pick<WebBluetoothOptions, 'mtu'> = {},
  ): Promise<WebBluetoothTransport> {
    if (!device.gatt) throw new Error('device has no GATT server');
    const server = await device.gatt.connect();
    const service = await server.getPrimaryService(WISP_GATT.service);
    const rx = await service.getCharacteristic(WISP_GATT.rx);
    const tx = await service.getCharacteristic(WISP_GATT.tx);
    const t = new WebBluetoothTransport(device, server, rx, opts.mtu ?? 247);
    tx.addEventListener('characteristicvaluechanged', (ev) => {
      const v = (ev.target as Characteristic).value;
      if (v)
        t.receiver?.onData(
          new Uint8Array(v.buffer, v.byteOffset, v.byteLength).slice(),
        );
    });
    device.addEventListener('gattserverdisconnected', () =>
      t.receiver?.onClose(),
    );
    await tx.startNotifications();
    return t;
  }

  attach(receiver: TransportReceiver) {
    this.receiver = receiver;
  }

  async write(chunk: Uint8Array) {
    await this.rx.writeValueWithoutResponse(chunk);
  }

  async close() {
    if (this.server.connected) this.server.disconnect();
  }
}
