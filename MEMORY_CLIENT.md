# MemoryClient locale

Il repository contiene un CLI Node.js minimale per verificare l’accesso autenticato alla Master Memory. Questo componente non importa dati.

## Prerequisiti una tantum

1. Nel Dashboard Supabase, aggiungere `master_memory` a **Project Settings → API → Exposed schemas**. Lo schema resta protetto: le tabelle non concedono privilegi diretti; sono esposte solo le RPC con `EXECUTE` per `authenticated`.
2. In **Authentication → Email Templates → Magic Link**, includere `{{ .Token }}` nel template per ricevere il codice OTP.

## Configurazione locale

Richiede Node.js 22 o superiore.

Impostare localmente, senza inserirle nel repository:

```bash
export SUPABASE_URL="https://<project-ref>.supabase.co"
export SUPABASE_PUBLISHABLE_KEY="<publishable-key>"
```

La publishable key non è una service-role key. Non impostare né usare `SUPABASE_SERVICE_ROLE_KEY`.

## Esecuzione

```bash
pnpm install
pnpm run memory:auth
```

Il CLI chiede email e OTP interattivamente. Non accetta OTP o token come argomenti, non stampa credenziali e configura `persistSession: false`, quindi access token e refresh token restano solo nella memoria del processo.

Il test autenticato chiama `export_master_memory_json(false)` tramite il client con schema `master_memory`. La RPC controlla `auth.uid()`; una sessione mancante produce errore. Con database vuoto l’output atteso è:

```json
{
  "authenticated": true,
  "user_id_present": true,
  "export_success": true,
  "memory_items": 0,
  "session_persisted": false
}
```

Il CLI non usa SQL amministrativo, non passa `owner_id`, non scrive tabelle e non avvia l’import staging.
