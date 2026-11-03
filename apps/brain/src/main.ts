import { createApp } from './app.ts';
import { loadConfig } from './config.ts';
import { registerIntegrations } from './integrations/register.ts';
import { listen } from './server/http.ts';
import { printPairingBanner } from './server/pairing-banner.ts';

async function main(): Promise<void> {
  const config = loadConfig();
  const app = createApp({ config });
  registerIntegrations(app);
  const srv = await listen(app);
  app.scheduler.start();
  app.log.info(
    `Lotti Brain ${config.version} listening on :${srv.port} (data: ${config.dataDir})`,
  );
  const code = app.auth.ensureStartupCode();
  if (code) await printPairingBanner(app, code);
  else
    app.log.info(
      'A device is already paired. Create more codes in the app (pairing.new_code).',
    );
  const stop = async () => {
    app.scheduler.stop();
    await srv.close();
    app.db.close();
    process.exit(0);
  };
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
}

main().catch((e) => {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
});
