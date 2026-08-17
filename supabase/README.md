# Momentus Supabase backend

The iOS and watchOS apps authenticate with Supabase and call the `ai-gateway` Edge Function. The
client-side anon key is safe to include in the app. AssemblyAI and Anthropic secret keys must only
exist as Edge Function secrets.

Required hosted configuration:

1. Enable **Authentication → Sign In / Providers → Anonymous Sign-Ins**.
2. Set `ASSEMBLYAI_API_KEY` and `ANTHROPIC_API_KEY` in **Edge Functions → Secrets**.
3. Apply the database migrations, which add the initial per-user daily usage ceiling.
4. Deploy `supabase/functions/ai-gateway` with JWT verification enabled.

CLI equivalent after signing into the Supabase organization that owns the project:

```sh
npx supabase@latest link --project-ref hbljfwhhyxppcughhulp
npx supabase@latest secrets set ASSEMBLYAI_API_KEY=... ANTHROPIC_API_KEY=...
npx supabase@latest db push
npx supabase@latest functions deploy ai-gateway
```

Never commit either provider secret or a Supabase secret/service-role key.

The 25-unit daily ceiling is a beta safety limit, not a subscription entitlement system. Before a
public paid launch, replace it with verified StoreKit entitlements and plan-specific quotas.
