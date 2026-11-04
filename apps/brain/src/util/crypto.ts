import {
  createCipheriv,
  createDecipheriv,
  createHash,
  hkdfSync,
  randomBytes,
  timingSafeEqual,
} from 'node:crypto';

export function deriveKey(masterKey: string): Buffer {
  return Buffer.from(
    hkdfSync(
      'sha256',
      Buffer.from(masterKey, 'utf8'),
      Buffer.from('lotti-brain-v1'),
      Buffer.from('secrets'),
      32,
    ),
  );
}

/** AES-256-GCM. Output: base64(iv | tag | ciphertext). */
export function encrypt(key: Buffer, plain: string): string {
  const iv = randomBytes(12);
  const c = createCipheriv('aes-256-gcm', key, iv);
  const ct = Buffer.concat([c.update(plain, 'utf8'), c.final()]);
  return Buffer.concat([iv, c.getAuthTag(), ct]).toString('base64');
}

export function decrypt(key: Buffer, blob: string): string {
  const b = Buffer.from(blob, 'base64');
  const d = createDecipheriv('aes-256-gcm', key, b.subarray(0, 12));
  d.setAuthTag(b.subarray(12, 28));
  return Buffer.concat([d.update(b.subarray(28)), d.final()]).toString('utf8');
}

export function sha256(s: string): string {
  return createHash('sha256').update(s).digest('hex');
}

export function randomToken(prefix = ''): string {
  return prefix + randomBytes(32).toString('base64url');
}

export function safeEqual(a: string, b: string): boolean {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

const ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
/** Pairing code like K7QM-4XD2 (no ambiguous characters). */
export function pairingCode(): string {
  const b = randomBytes(8);
  let s = '';
  for (let i = 0; i < 8; i++) s += ALPHABET[b[i]! % ALPHABET.length];
  return `${s.slice(0, 4)}-${s.slice(4)}`;
}

export function newId(prefix = ''): string {
  return prefix + randomBytes(8).toString('hex');
}
