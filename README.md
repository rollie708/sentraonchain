# SENTRA — The Intelligence Layer for Crypto

Live, production-style on-chain search. Facts come from real providers; nothing is simulated.

## Run locally

```powershell
cd sentra
powershell -ExecutionPolicy Bypass -File server.ps1   # http://localhost:8080/
```

No build step. Frontend is static (`index.html` + `css/` + `js/`); `server.ps1` adds the
secure API layer (config, keyed-provider proxy, admin persistence, analytics).

## Deploy on Vercel (production)

The `sentra/` folder is the deploy root. Static files deploy as-is; `api/*.js` become
serverless functions replacing `server.ps1` (same routes, same response shapes).

1. Push the `sentra/` folder to a Git repo (GitHub/GitLab/Bitbucket).
2. Go to **vercel.com → Add New → Project → Import** the repo.
3. If the repo root contains `sentra/` as a subfolder, set **Root Directory = `sentra`**.
   If the repo IS the sentra content, leave root as `/`.
4. Framework Preset: **Other**. Build Command: *(empty)*. Output Directory: *(empty / `./`)*.
5. **Environment Variables** (Settings → Environment Variables) — add what you use:
   `SENTRA_TOKEN_ADDRESS`, `SENTRA_X_URL`, `SENTRA_LAUNCH_AT=2026-09-25T13:00:00Z`,
   `ALCHEMY_API_KEY`, `MORALIS_API_KEY`, `OPENAI_API_KEY`, `SENTRA_ADMIN_TOKEN`.
6. **Deploy.** Every `git push` redeploys automatically. Add a custom domain under
   Settings → Domains if you want one.

Vercel notes (by design, not bugs):

* `/api/admin/config` returns 501 — the serverless filesystem is ephemeral, so
  token/X/launch settings come from **env vars**, not the Admin UI. The Admin UI
  still works per-browser (localStorage) and tells you this.
* `/api/analytics` accepts events and returns ok (wire Upstash/KV/PostHog in
  `api/analytics.js` if you want persistence).
* Rate limiting in `api/_lib.js` is best-effort per instance; add Vercel KV/Upstash
  for strict global limits.
* No `vercel.json` rewrites needed: all app routes are hash routes (`#/...`), so
  only `/` + `/api/*` must resolve — both work out of the box.

## API keys (all server-side, never in frontend code)

| Variable | Use | Required for |
|---|---|---|
| `ALCHEMY_API_KEY` | EVM RPC/indexing via `/api/keyed/alchemy` | deep history, keyed chains |
| `MORALIS_API_KEY` | wallet/token entity data via `/api/keyed/moralis` | rich wallet analytics |
| `COINGECKO_API_KEY` | higher market-data limits (optional header later) | scale |
| `OPENAI_API_KEY` | optional NL→query assist (facts still from providers) | scale |
| `SUPABASE_URL` / `SUPABASE_ANON_KEY` | saved searches, alerts schema (`sql/schema.sql`) | accounts |
| `SENTRA_TOKEN_ADDRESS` | token contract (empty = COMING AT LAUNCH) | launch |
| `SENTRA_X_URL` | official X link (placeholder until provided) | links |
| `SENTRA_ADMIN_TOKEN` | protects `POST /api/admin/config` | admin |

Free, keyless providers used out of the box: **Blockscout v2** (Ethereum/Base/Arbitrum/
Optimism/Polygon), **CoinGecko**, **DeFiLlama**, **Blockstream** (Bitcoin), **Solana public RPC**.

## Architecture

```
js/config.js            chain registry (status honest per chain) + launch config
js/services/errors.js   cache + dedupe + throttle + retry (cost control)
js/services/market.js   CoinGecko
js/services/protocol.js DeFiLlama
js/services/blockchain.js Blockscout / Blockstream / Solana RPC / keyed proxy
js/services/wallet.js   wallet normalization
js/services/tokens.js   token normalization (+ unverified warning)
js/services/query.js    NL → {intent, chain, entity, timeframe, sort, limit…}
js/services/search.js   orchestration → {answer, sections, provenance, confidence}
js/services/analytics.js anonymous usage events
js/ui.js                router + views + countdown + autocomplete + admin
server.ps1              static + /api/* (config, keyed proxy, admin, analytics)
```

## Acceptance flows

1. `#/search?q=What's happening on Base right now?` → live Base stats + txns
2. Wallet: `#/wallet/ethereum/0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045`
3. Tx: paste any `0x…` 64-hex hash into search
4. `Compare Base and Arbitrum` → side-by-side table
5. Invalid address → clean error state, no crash
6. Disabled chain (e.g. Sui) → honest "unsupported" message
7. Countdown flips to SENTRA IS LIVE after 2026-09-25T13:00:00Z
8. `grep -ri "api[_-]\?key" js/` → no secrets in frontend
