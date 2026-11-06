#!/usr/bin/env node
import { parseArgs } from 'node:util';
import { startSim } from './server.ts';

const { values } = parseArgs({
  options: {
    port: { type: 'string', short: 'p', default: '8360' },
    host: { type: 'string', default: '127.0.0.1' },
    data: { type: 'string', short: 'd' },
    help: { type: 'boolean', short: 'h' },
  },
});

if (values.help) {
  console.log(`wisp-sim [--port 8360] [--host 127.0.0.1] [--data <dir>]

  --data   keep persisted resources in this directory across restarts`);
  process.exit(0);
}

const sim = await startSim({
  port: Number(values.port),
  host: values.host,
  dataDir: values.data,
  log: (l) => console.log(`[sim] ${l}`),
});
console.log(`wisp-sim: viewer ${sim.url}`);
console.log(
  `wisp-sim: link   ${sim.linkUrl}  (?lens=left|right, ?mirror=0 for one lens only)`,
);
const stop = () => void sim.close().then(() => process.exit(0));
process.on('SIGINT', stop);
process.on('SIGTERM', stop);
