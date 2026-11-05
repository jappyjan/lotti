// Official G2 stock bundles, pinned by SHA-256. Facts (not files) taken from
// the webflasher firmware catalog (AM-Guru/evenRealities-webflasher, MIT,
// `public/firmware-updates/index.json`, generated 2026-10-09). The download
// URL scheme `https://cdn.evenreal.co/firmware/<md5>.bin` is Even's own CDN;
// it is also the source g2flash's README names (2.3.0.24 there = the same
// URL as below). `mainAppEnd` is webflasher's independently computed install
// end of the main app, cross-checked by `wisp-ota fetch`.
//
// We never commit or redistribute these bundles (safety.md rule 9).

export interface StockRelease {
  version: string;
  /** MD5 of the bundle; also its file name on the CDN. */
  md5: string;
  size: number;
  sha256: string;
  /** Exclusive end address of the installed main app. */
  mainAppEnd: number;
}

export const STOCK_CDN_BASE = 'https://cdn.evenreal.co/firmware';

export const STOCK_RELEASES: readonly StockRelease[] = [
  {
    version: '2.3.2.14',
    md5: '7892790e40cffbae6db8a635b335e17f',
    size: 4701884,
    sha256: '26b6067665a441b779c47f6b95427b8b4bb5f502aaf527466dadce628aeb00b2',
    mainAppEnd: 0x7f5aac,
  },
  {
    version: '2.3.0.24',
    md5: '1dbdf37b03a1169c384945e94d671371',
    size: 4537963,
    sha256: '187ccf2bcc5c17a212106e8a376745511e8289c4232b634a7ea94b9bf25a0979',
    mainAppEnd: 0x7cda60,
  },
  {
    version: '2.2.10.10',
    md5: '5d2abaf086ad7cc4709cad679b7b24d1',
    size: 4493065,
    sha256: '927879057685a4147c6ba1fe33e5f3740d3cc48f87141a9039204d94516e65b8',
    mainAppEnd: 0x7c2b3c,
  },
  {
    version: '2.2.9.22',
    md5: 'fc250b05e98a9ff998b4b68f5f99f994',
    size: 4476518,
    sha256: 'a03fbea9f68a9de6bc271daabb9f3a41c59053d1086622c76a4e990f829cc561',
    mainAppEnd: 0x7bea64,
  },
  {
    version: '2.2.8.4',
    md5: 'd495a1dffb919795e95135e144345f04',
    size: 4342507,
    sha256: 'df7b8bd18727765eba73be5ab836e0ee4cfd17b5e680046003b8d608d2fbfda7',
    mainAppEnd: 0x79e498,
  },
  {
    version: '2.2.7.14',
    md5: 'ededa3729ef16cb2948fa54c44e1dd09',
    size: 4335715,
    sha256: '0fced0aebcc6c88db6f76dba34f91b805d842a5fc297bfd7fa6d6a34ec83cecb',
    mainAppEnd: 0x79c9dc,
  },
  {
    version: '2.2.6.10',
    md5: 'e28738432d7b612d625331b00383149b',
    size: 4301227,
    sha256: 'f4dfb0b49ad3de3c2daf17f8a27a157c3dc98411d6a0d3ab2cfd0918f41b9afa',
    mainAppEnd: 0x794324,
  },
  {
    version: '2.2.4.34',
    md5: 'a6966d807634cc97aec641a0dcca358b',
    size: 4131592,
    sha256: 'f9a93621a7141e0ae54ca6371cd2f1b4afbffa61f302ace096e0656ba25b1754',
    mainAppEnd: 0x78f188,
  },
  {
    version: '2.2.0.24',
    md5: 'a0a293189243b71ca581bda1493da1da',
    size: 3997044,
    sha256: 'b3b0e213f7eb9568c97603a011b4a0261f9a4dbf9f7c933ff16b25aeb7efe0a6',
    mainAppEnd: 0x76e3f4,
  },
  {
    version: '2.1.1.12',
    md5: '55c8b82d3d12a82f22453c7e9c8d8e05',
    size: 4082768,
    sha256: '75ca2a401f813cf23f864106f4dedbc7e00c4c4b37cd50dcf17f7e9fe503c63e',
    mainAppEnd: 0x75f32c,
  },
  {
    version: '2.1.1.8',
    md5: '51f4af4b287af7b4572b4b3e59cecb89',
    size: 4076732,
    sha256: '1aa72ae9bd4e291866193e80f3f950eb35450d87bd3eab1ed017cb5c3875b3fa',
    mainAppEnd: 0x75dcb0,
  },
  {
    version: '2.0.9.20',
    md5: '77de41924c3a7e0402921017140c7456',
    size: 4068333,
    sha256: '4b0055531530b3206f7e3acf103e30edeba6c35ed746aba09e52083efb6a2592',
    mainAppEnd: 0x75bc24,
  },
  {
    version: '2.0.8.20',
    md5: 'd2d778f1b3fd8dad8e12dfc000109657',
    size: 4051861,
    sha256: 'a5e74e6830f4d9f4b8d06e18f11fb7e8f57383e3204504c299c413ce44940c23',
    mainAppEnd: 0x757f24,
  },
  {
    version: '2.0.7.16',
    md5: '650176717d1f30ef684e5f812500903c',
    size: 3958551,
    sha256: '47bdd17b9227d56566280fad42248dbecfe4fc70017ad9c74c3d949e27116b5e',
    mainAppEnd: 0x7429a0,
  },
  {
    version: '2.0.6.14',
    md5: '0c9f9ca58785547278a5103bc6ae7a09',
    size: 3954281,
    sha256: 'f3c4c40aa122f61e859b82ee5eaa296ac8fa3a96e7b9905fd8d112ded732c5da',
    mainAppEnd: 0x741938,
  },
  {
    version: '2.0.5.12',
    md5: '53486f03b825cb22d13e769187b46656',
    size: 3921853,
    sha256: '83e3cc196df2d7bd74f735f2ffbfd9f01c204da2cb73a1fb6fee5119f1125e21',
    mainAppEnd: 0x73b1bc,
  },
  {
    version: '2.0.3.20',
    md5: '57201a6e7cd6dadeee1bdb8f6ed98606',
    size: 3832044,
    sha256: '84866f11895c34d15838736a373a50f06765232e2561fedd8ba1b62ba509c09c',
    mainAppEnd: 0x725494,
  },
  {
    version: '2.0.1.14',
    md5: '09fe9c0df7b14385c023bc35a364b3a9',
    size: 3232068,
    sha256: 'd45005d5f75985339b234550b384899bb89fb37cfe4de4928abc9e882f0709e2',
    mainAppEnd: 0x693588,
  },
];

export function stockRelease(version: string): StockRelease | undefined {
  return STOCK_RELEASES.find((r) => r.version === version);
}

export function stockReleaseUrl(release: StockRelease): string {
  return `${STOCK_CDN_BASE}/${release.md5}.bin`;
}

export function stockReleaseBySha256(sha256: string): StockRelease | undefined {
  const digest = sha256.toLowerCase();
  return STOCK_RELEASES.find((r) => r.sha256 === digest);
}
