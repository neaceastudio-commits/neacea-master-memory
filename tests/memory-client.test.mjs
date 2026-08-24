import test from 'node:test';
import assert from 'node:assert/strict';
import { readConfig, summarizeExport, validateCliArgs } from '../scripts/memory-client.mjs';

test('rejects command-line arguments so OTP cannot be supplied through shell history', () => {
  assert.throws(() => validateCliArgs(['123456']), /no command-line arguments/);
});

test('accepts only URL and publishable key configuration', () => {
  assert.deepEqual(
    readConfig({ SUPABASE_URL: 'https://example.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_test' }),
    { url: 'https://example.supabase.co', publishableKey: 'sb_publishable_test' },
  );
  assert.throws(
    () => readConfig({ SUPABASE_URL: 'https://example.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'service_role_test' }),
    /service-role or secret key/,
  );
  const header = Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })).toString('base64url');
  const payload = Buffer.from(JSON.stringify({ role: 'service_role' })).toString('base64url');
  assert.throws(
    () => readConfig({ SUPABASE_URL: 'https://example.supabase.co', SUPABASE_PUBLISHABLE_KEY: `${header}.${payload}.signature` }),
    /service-role or secret key/,
  );
});

test('summarizes an empty export without exposing record contents', () => {
  assert.deepEqual(summarizeExport({ memory_items: [] }), { memoryItems: 0 });
  assert.throws(() => summarizeExport({ memory_items: 'not-an-array' }), /memory_items/);
});
