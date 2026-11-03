import QRCode from 'qrcode';
import type { App } from '../app.ts';

/** URL the app's scanner reads: lotti://pair?url=<server>&code=<code> */
export function pairingLink(app: App, code: string): string {
  return `lotti://pair?url=${encodeURIComponent(app.config.publicUrl)}&code=${encodeURIComponent(code)}`;
}

export async function printPairingBanner(
  app: App,
  code: string,
): Promise<void> {
  const link = pairingLink(app, code);
  const qr = await QRCode.toString(link, { type: 'terminal', small: true });
  app.log.info(
    [
      '',
      '==================== Lotti Brain: pair your phone ====================',
      `  Server URL   : ${app.config.publicUrl}`,
      `  Pairing code : ${code}`,
      `  Link         : ${link}`,
      '',
      qr,
      '  Enter the URL and code in the Lotti app (Settings > Backend), or scan the QR code.',
      '======================================================================',
      '',
    ].join('\n'),
  );
}
