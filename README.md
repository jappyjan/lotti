# Lotti

A curious raccoon living in your Even G2 glasses: an AI-first assistant you control with the R1 ring, the touchpads, voice, or the chat in the phone app.

Status: working end to end in code; the iOS app and the glasses pieces (wear event, image containers) still need real-device checks.

- [Vision & goals](docs/vision.md)
- [Design language](docs/design.md)
- [Architecture](docs/architecture.md)
- [Lotti Brain protocol](docs/protocol.md) and [backend README](apps/brain/README.md)
- [Roadmap](docs/roadmap.md)

## Workspace

Nx + pnpm: `apps/brain` (backend), `apps/ios` (iPhone app), `packages/lotti-kit` (Swift package).

```sh
pnpm install
pnpm nx run-many -t build test
```

## Deploy Lotti Brain

```sh
cd apps/brain
MASTER_KEY=$(openssl rand -hex 32) docker compose up -d   # build context is the repo root
docker compose logs brain                                  # prints a pairing code, URL and QR
```

Only `MASTER_KEY` is needed (it encrypts secrets in `/data`); `PUBLIC_URL` and the APNs key are optional. Reach it over Tailscale/HTTPS (e.g. Coolify). `GET /health` returns OK.

## Pair and set up (all in the app)

1. Open the Lotti app, Settings → Lotti Brain, enter the URL and the pairing code (or open the `lotti://pair…` link). The device token goes to the Keychain.
2. Settings → AI providers: enter a DeepSeek key (default), or sign in with ChatGPT or Claude. Pick the active and fallback provider.
3. Settings → Accounts: Google, iCloud, IMAP/CalDAV, Bring!. Jobs, memory, skills, MCP servers and catch-up rules live in Settings too. Credentials are write-only.

There is no admin CLI: manage Lotti by talking to her, or in the app.

APNs is built but off until configured; the default iOS build signs with the free Personal Team (see `apps/ios/README.md` for the opt-in).
