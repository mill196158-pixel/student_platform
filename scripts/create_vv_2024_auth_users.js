#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

function loadDotEnvLocal() {
  const envPath = path.resolve(process.cwd(), '.env.local');
  if (!fs.existsSync(envPath)) {
    return;
  }

  const content = fs.readFileSync(envPath, 'utf8');
  for (const line of content.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#') || !trimmed.includes('=')) {
      continue;
    }

    const separatorIndex = trimmed.indexOf('=');
    const key = trimmed.slice(0, separatorIndex).trim();
    let value = trimmed.slice(separatorIndex + 1).trim();

    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }

    if (!process.env[key]) {
      process.env[key] = value;
    }
  }
}

async function requestJson(url, options) {
  const response = await fetch(url, options);
  const text = await response.text();
  let body = null;

  if (text) {
    try {
      body = JSON.parse(text);
    } catch {
      body = { message: text };
    }
  }

  if (!response.ok) {
    const message =
      body?.msg ||
      body?.message ||
      body?.error_description ||
      body?.error ||
      `HTTP ${response.status}`;
    const error = new Error(message);
    error.status = response.status;
    error.body = body;
    throw error;
  }

  return body;
}

function trimTrailingSlash(value) {
  return value.replace(/\/+$/, '');
}

function getAuthUserId(responseBody) {
  return responseBody?.user?.id || responseBody?.id || responseBody?.data?.user?.id;
}

function safeErrorMessage(error) {
  const raw = error?.message || String(error);
  return raw.slice(0, 1000);
}

async function updateCredential({ supabaseUrl, serviceRoleKey, id, patch }) {
  const url = `${supabaseUrl}/rest/v1/stage_student_auth_credentials_vv_2024?id=eq.${encodeURIComponent(id)}`;
  await requestJson(url, {
    method: 'PATCH',
    headers: {
      apikey: serviceRoleKey,
      authorization: `Bearer ${serviceRoleKey}`,
      'content-type': 'application/json',
      prefer: 'return=minimal',
    },
    body: JSON.stringify(patch),
  });
}

async function main() {
  loadDotEnvLocal();

  const supabaseUrl = trimTrailingSlash(process.env.SUPABASE_URL || '');
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY || '';

  if (!supabaseUrl || !serviceRoleKey) {
    throw new Error(
      'Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY. Put them in .env.local or the process environment.',
    );
  }

  const headers = {
    apikey: serviceRoleKey,
    authorization: `Bearer ${serviceRoleKey}`,
    'content-type': 'application/json',
  };

  const credentialsUrl =
    `${supabaseUrl}/rest/v1/stage_student_auth_credentials_vv_2024` +
    '?select=id,import_batch,record_book,login,full_name,group_name,auth_email,auth_password,need_password_change' +
    '&created_in_auth=eq.false' +
    '&order=id.asc';

  const rows = await requestJson(credentialsUrl, { method: 'GET', headers });

  let created = 0;
  let errors = 0;
  const errorRows = [];

  for (const row of rows) {
    try {
      if (!row.auth_email || !row.auth_password || !row.login) {
        throw new Error('Missing auth_email, auth_password, or login');
      }

      const createdUser = await requestJson(`${supabaseUrl}/auth/v1/admin/users`, {
        method: 'POST',
        headers,
        body: JSON.stringify({
          email: row.auth_email,
          password: row.auth_password,
          email_confirm: true,
          user_metadata: {
            login: row.login,
            record_book: row.record_book,
            full_name: row.full_name,
            group_name: row.group_name,
            need_password_change: true,
            import_batch: row.import_batch,
          },
        }),
      });

      const authUserId = getAuthUserId(createdUser);
      if (!authUserId) {
        throw new Error('Admin API response did not include user id');
      }

      await updateCredential({
        supabaseUrl,
        serviceRoleKey,
        id: row.id,
        patch: {
          auth_user_id: authUserId,
          created_in_auth: true,
          error_message: null,
        },
      });

      created += 1;
      console.log(`created login=${row.login} email=${row.auth_email} auth_user_id=${authUserId}`);
    } catch (error) {
      const message = safeErrorMessage(error);
      errors += 1;
      errorRows.push({ id: row.id, login: row.login, auth_email: row.auth_email, error: message });

      await updateCredential({
        supabaseUrl,
        serviceRoleKey,
        id: row.id,
        patch: {
          error_message: message,
        },
      });

      console.error(`error login=${row.login} email=${row.auth_email}: ${message}`);
    }
  }

  console.log(
    JSON.stringify(
      {
        attempted: rows.length,
        created,
        errors,
        errorRows,
      },
      null,
      2,
    ),
  );
}

main().catch((error) => {
  console.error(error?.stack || error?.message || String(error));
  process.exitCode = 1;
});
