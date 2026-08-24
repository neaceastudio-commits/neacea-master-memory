import { createClient } from '@supabase/supabase-js';
import { createInterface } from 'node:readline/promises';
import { stdin as input, stdout as output } from 'node:process';

const RPC_NAME = 'export_master_memory_json';
const SCHEMA_NAME = 'master_memory';

export function validateCliArgs(args) {
  if (args.length > 0) {
    throw new Error('This command accepts no command-line arguments. Enter the email and OTP interactively.');
  }
}

export function readConfig(env) {
  const url = env.SUPABASE_URL?.trim();
  const publishableKey = env.SUPABASE_PUBLISHABLE_KEY?.trim();

  if (!url || !publishableKey) {
    throw new Error('Set SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY in the local environment.');
  }

  if (env.SUPABASE_SERVICE_ROLE_KEY || isServiceRoleKey(publishableKey)) {
    throw new Error('A service-role or secret key is not accepted by this client.');
  }

  let parsedUrl;
  try {
    parsedUrl = new URL(url);
  } catch {
    throw new Error('SUPABASE_URL is not a valid URL.');
  }

  if (parsedUrl.protocol !== 'https:' && parsedUrl.hostname !== 'localhost' && parsedUrl.hostname !== '127.0.0.1') {
    throw new Error('SUPABASE_URL must use HTTPS (except for local development).');
  }

  return { url, publishableKey };
}

function isServiceRoleKey(key) {
  if (/service_role|sb_secret_/i.test(key)) return true;

  // Legacy anon/service-role keys are JWTs. Inspect only the local payload
  // claim; the key is never printed, persisted, or sent to Supabase here.
  const parts = key.split('.');
  if (parts.length !== 3) return false;
  try {
    const payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
    return payload?.role === 'service_role';
  } catch {
    return false;
  }
}

export function summarizeExport(exportData) {
  if (!exportData || typeof exportData !== 'object' || Array.isArray(exportData)) {
    throw new Error('The export RPC returned an unexpected response.');
  }

  const memoryItems = exportData.memory_items;
  if (!Array.isArray(memoryItems)) {
    throw new Error('The export RPC response does not contain memory_items.');
  }

  return { memoryItems: memoryItems.length };
}

function safeError(context, error) {
  const code = error?.code ? ` (${error.code})` : '';
  return new Error(`${context} failed${code}.`);
}

async function run() {
  validateCliArgs(process.argv.slice(2));
  const { url, publishableKey } = readConfig(process.env);

  const supabase = createClient(url, publishableKey, {
    db: { schema: SCHEMA_NAME },
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
  });

  const readline = createInterface({ input, output });
  try {
    const email = (await readline.question('Owner email (input locally): ')).trim();
    if (!email) throw new Error('An owner email is required.');

    const { error: otpRequestError } = await supabase.auth.signInWithOtp({
      email,
      options: { shouldCreateUser: false },
    });
    if (otpRequestError) throw safeError('OTP request', otpRequestError);

    const otp = (await readline.question('OTP (input locally, never passed as an argument): ')).trim();
    if (!/^\d{6}$/.test(otp)) throw new Error('The OTP must be a six-digit code.');

    const { data: verifyData, error: verifyError } = await supabase.auth.verifyOtp({
      email,
      token: otp,
      type: 'email',
    });
    if (verifyError || !verifyData?.session) throw safeError('OTP verification', verifyError);

    const { data: userData, error: userError } = await supabase.auth.getUser();
    if (userError || !userData?.user?.id) throw safeError('Authenticated user check', userError);

    const { data: exportData, error: exportError } = await supabase.rpc(RPC_NAME, {
      p_include_highly_sensitive: false,
    });
    if (exportError) {
      if (exportError.code === 'PGRST106' || exportError.code === 'PGRST202' || exportError.code === '42P01') {
        throw new Error('The master_memory schema/RPC is not exposed to the Data API. Add master_memory to Supabase API Exposed schemas.');
      }
      throw safeError('Master Memory export RPC', exportError);
    }

    const { memoryItems } = summarizeExport(exportData);
    console.log(JSON.stringify({
      authenticated: true,
      user_id_present: true,
      export_success: true,
      memory_items: memoryItems,
      session_persisted: false,
    }, null, 2));
  } finally {
    readline.close();
    // The client is configured not to persist or refresh sessions. Sign out also
    // prevents this one-shot process from retaining a live session server-side.
    await supabase.auth.signOut().catch(() => {});
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  run().catch((error) => {
    console.error(`[memory-client] ${error.message}`);
    process.exitCode = 1;
  });
}
