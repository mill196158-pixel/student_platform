/**
 * Audited, user-session-only home-promo image switch.
 * Default mode is preflight (admin_get_content_item writes an audit event).
 * --apply mutates the specific item and must only be used after review.
 * Never use service_role. Conflicts/uncertainty never auto-discard drafts.
 */
import { createHash } from 'node:crypto';
import { readFile, stat, open } from 'node:fs/promises';
import { isDeepStrictEqual } from 'node:util';
import { pathToFileURL } from 'node:url';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SHA = /^[0-9a-f]{64}$/;
const LIMIT = 20 * 1024 * 1024;
const PROJECT_ORIGIN = 'https://gwdanmwluhrcfxbnplwd.supabase.co';
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
function insist(condition, message) { if (!condition) throw new Error(message); }
function validatePlan(plan) {
  insist(plan && UUID.test(plan.itemId) && UUID.test(plan.currentAssetId), 'invalid plan identities');
  insist(Number.isSafeInteger(plan.rowVersion) && plan.rowVersion > 0, 'invalid canonical version');
  insist(SHA.test(plan.currentSha256 || ''), 'invalid current checksum');
  const rollback = plan.targetAssetId != null;
  if (rollback) {
    insist(UUID.test(plan.targetAssetId) && plan.targetAssetId !== plan.currentAssetId && SHA.test(plan.targetSha256 || ''), 'invalid rollback target');
    insist(!plan.optimizedFile && !plan.optimizedSha256, 'ambiguous plan');
  } else {
    insist(typeof plan.optimizedFile === 'string' && plan.optimizedFile.length > 0 && SHA.test(plan.optimizedSha256 || ''), 'invalid optimized image');
  }
  return rollback;
}
function isExpected(item, plan) {
  return item?.id === plan.itemId && item.status === 'published' && item.template_key === 'home_promo_v1' &&
    item.row_version === plan.rowVersion && item.payload?.image_asset_id === plan.currentAssetId &&
    item.has_working_draft === false && Array.isArray(item.asset_ids) && item.asset_ids.includes(plan.currentAssetId);
}
function expectBytes(bytes, sha, label) {
  insist(bytes instanceof Uint8Array && bytes.length > 0 && bytes.length <= LIMIT && digest(bytes) === sha,
    `${label} checksum mismatch or invalid size`);
}
function expectDraft(item, plan, draftId, version, payload) {
  const draft = item?.working_draft;
  insist(item?.id === plan.itemId && item.row_version === plan.rowVersion &&
    item.payload?.image_asset_id === plan.currentAssetId && item.has_working_draft === true &&
    draft?.id === draftId && draft.base_canonical_row_version === plan.rowVersion &&
    draft.row_version === version && isDeepStrictEqual(draft.payload, payload), 'draft changed; inspect manually');
}

/** `api` is an authenticated, scoped adapter; no automatic retries or deletion. */
export async function switchHomePromo({ api, plan, optimizedBytes, apply = false, journal }) {
  const rollback = validatePlan(plan);
  const before = await api.getItem(plan.itemId);
  insist(isExpected(before, plan), 'content changed or an existing draft is present');
  const currentBytes = await api.download(plan.currentAssetId);
  expectBytes(currentBytes, plan.currentSha256, 'current asset');
  let targetBytes;
  if (rollback) {
    insist(before.asset_ids.includes(plan.targetAssetId), 'rollback asset missing');
    targetBytes = await api.download(plan.targetAssetId);
    expectBytes(targetBytes, plan.targetSha256, 'rollback asset');
  } else {
    expectBytes(optimizedBytes, plan.optimizedSha256, 'optimized asset');
    insist(optimizedBytes.length < currentBytes.length && optimizedBytes.length <= 5 * 1024 * 1024 &&
      optimizedBytes[0] === 0xff && optimizedBytes[1] === 0xd8 && optimizedBytes[2] === 0xff,
      'optimized image is not a smaller JPEG');
    targetBytes = optimizedBytes;
  }
  if (!apply) return { status: 'preflight_only', action: rollback ? 'rollback' : 'optimize' };
  insist(typeof journal === 'function', 'durable journal required');
  await journal({step:'begin_start',itemId:plan.itemId,rowVersion:plan.rowVersion,currentAssetId:plan.currentAssetId,currentSha256:plan.currentSha256,targetSha256:rollback?plan.targetSha256:plan.optimizedSha256});
  // Atomic server wrapper refuses a canonical mismatch or ANY existing draft.
  const started = await api.begin(plan.itemId, plan.rowVersion, plan.currentAssetId);
  const draft = started?.working_draft;
  insist(UUID.test(draft?.id || '') && draft.row_version === 1 &&
    draft.base_canonical_row_version === plan.rowVersion &&
    isDeepStrictEqual(draft.payload, before.payload) &&
    Array.isArray(draft.draft_asset_ids) && draft.draft_asset_ids.length === 0,
    'unexpected draft; inspect manually');
  await journal({step:'begin_response',draftId:draft.id,version:draft.row_version});
  let version = draft.row_version;
  let newId = plan.targetAssetId;
  if (!rollback) {
    await journal({step:'upload_start',draftId:draft.id});
    const uploaded = await api.upload(plan.itemId, optimizedBytes, event=>journal(event));
    insist(UUID.test(uploaded?.id || '') && uploaded.id !== plan.currentAssetId &&
      uploaded.mime_type === 'image/jpeg' && uploaded.byte_size === optimizedBytes.length &&
      uploaded.working_draft_id === draft.id && uploaded.working_draft_row_version === version + 1 &&
      uploaded.bound_to_working_draft === true, 'upload result changed; inspect draft manually');
    newId = uploaded.id;
    version = uploaded.working_draft_row_version;
    await journal({step:'upload_response',draftId:draft.id,assetId:newId,version});
  }
  expectDraft(await api.getItem(plan.itemId), plan, draft.id, version, before.payload);
  const nextPayload = { ...before.payload, image_asset_id: newId };
  await journal({step:'save_start',draftId:draft.id,assetId:newId,version});
  const saved = await api.save(plan.itemId, version, nextPayload);
  expectDraft(saved, plan, draft.id, version + 1, nextPayload);
  version++;
  await journal({step:'save_response',draftId:draft.id,assetId:newId,version});
  await journal({step:'publish_start',draftId:draft.id,assetId:newId,version});
  await api.publish(plan.itemId, version);
  await journal({step:'publish_response',draftId:draft.id,assetId:newId});
  const after = await api.getItem(plan.itemId);
  insist(after?.id === plan.itemId && after.status === 'published' &&
    after.row_version === plan.rowVersion + 1 && after.has_working_draft === false &&
    isDeepStrictEqual(after.payload, nextPayload) &&
    after.asset_ids?.includes(plan.currentAssetId) && after.asset_ids?.includes(newId),
    'publication result uncertain; inspect manually');
  expectBytes(await api.download(newId), rollback ? plan.targetSha256 : plan.optimizedSha256, 'published asset');
  expectBytes(await api.download(plan.currentAssetId), plan.currentSha256, 'retained asset');
  await journal({step:'published_verified',assetId:newId,rowVersion:after.row_version});
  return { status: 'published', action: rollback ? 'rollback' : 'optimize',
    oldAssetId: plan.currentAssetId, newAssetId: newId, rowVersion: after.row_version };
}

/** Inspect only: admin_get_content_item itself writes a server audit entry. */
export async function inspectHomePromoRecovery({api, plan}) {
  validatePlan(plan);
  const item = await api.getItem(plan.itemId);
  insist(item?.id === plan.itemId && Array.isArray(item.asset_ids), 'invalid item');
  const ids = [...new Set([...item.asset_ids, ...(item.working_draft?.draft_asset_ids || [])])];
  const assets = [];
  for (const id of ids) {
    if (!UUID.test(id)) throw new Error('invalid asset identity');
    try { const bytes = await api.download(id); assets.push({id,sha256:digest(bytes),size:bytes.length}); }
    catch (_) { assets.push({id,unavailable:true}); }
  }
  const draft = item.working_draft;
  const safeItem = {
    id: item.id, row_version: item.row_version, status: item.status,
    asset_ids: item.asset_ids, has_working_draft: item.has_working_draft,
    payload: {image_asset_id: item.payload?.image_asset_id},
    ...(draft ? {working_draft: {
      id: draft.id, row_version: draft.row_version,
      base_canonical_row_version: draft.base_canonical_row_version,
      draft_asset_ids: draft.draft_asset_ids,
      payload: {image_asset_id: draft.payload?.image_asset_id},
    }} : {}),
  };
  return {item:safeItem,assets,notice:'Inspection only. No mutation or automatic retry; compare with durable journal and plan.'};
}

function createApi({ base, apiKey, token }) {
  const origin = new URL(base);
  insist(origin.origin === PROJECT_ORIGIN && origin.pathname === '/' && !origin.username && !origin.password,
    'Supabase base URL must be the specified project origin');
  const authHeaders = { apikey: apiKey, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
  async function requestJson(path, body) {
    const res = await fetch(new URL(path, origin), { method: 'POST', headers: authHeaders,
      body: JSON.stringify(body), redirect: 'error' });
    if (!res.ok) throw new Error(`request failed (${res.status}); inspect state manually`);
    return await res.json();
  }
  function safeSignedUrl(raw) {
    const u = new URL(raw);
    insist(u.protocol === 'https:' && u.origin === origin.origin && !u.username && !u.password &&
      u.pathname.startsWith('/storage/v1/object/'), 'invalid signed storage URL');
    return u;
  }
  async function fetchSignedBytes(rawUrl) {
    const url = safeSignedUrl(rawUrl);
    const res = await fetch(url, { redirect: 'error' });
    if (!res.ok) throw new Error(`asset download failed (${res.status})`);
    const declared = Number(res.headers.get('content-length') || 0);
    insist(!declared || declared <= LIMIT, 'asset too large');
    insist(res.body, 'empty asset stream');
    const chunks = [];
    let total = 0;
    for await (const chunk of res.body) {
      total += chunk.length;
      insist(total <= LIMIT, 'asset too large');
      chunks.push(chunk);
    }
    return new Uint8Array(Buffer.concat(chunks, total));
  }
  async function bytesFor(assetId) {
    const obj = await requestJson('/functions/v1/content-media', { action: 'createDownload', assetId });
    return fetchSignedBytes(obj.signedUrl);
  }
  return {
    getItem: id => requestJson('/rest/v1/rpc/admin_get_content_item', { p_id: id }),
    download: bytesFor,
    getNews: id => requestJson('/rest/v1/rpc/admin_get_news', { p_id: id }),
    async downloadNews(path) {
      const obj = await requestJson('/functions/v1/news-media', { action: 'createDownload', path });
      insist(obj.path === path, 'news media identity mismatch');
      return fetchSignedBytes(obj.signedUrl);
    },
    async uploadNews(purpose, bytes, mime, onReserved) {
      const created = await requestJson('/functions/v1/news-media', {
        action: 'createOptimizationUpload', purpose, fileName: 'optimization',
        contentType: mime, fileSize: bytes.length,
      });
      insist(created.purpose === purpose && UUID.test(created.reservationId || '') &&
        /^news\/[0-9a-f-]{36}\/[0-9a-f-]{36}\.(jpg|png|webp)$/i.test(created.path || ''),
        'invalid news upload reservation');
      // Record the reserved identity before PUT; never record signed URLs.
      if (onReserved) await onReserved({ path: created.path, reservationId: created.reservationId });
      const res = await fetch(safeSignedUrl(created.signedUrl), { method: 'PUT',
        headers: { 'Content-Type': mime }, body: bytes, redirect: 'error' });
      if (!res.ok) throw new Error(`news upload failed (${res.status}); inspect reservation manually`);
      return { path: created.path, reservationId: created.reservationId };
    },
    applyNews: params => requestJson('/rest/v1/rpc/admin_optimize_news_image_guarded', params),
    findNews: (id, path) => requestJson('/rest/v1/rpc/admin_find_news_image_optimization',
      { p_news_id: id, p_optimized_path: path }),
    rollbackNews: (runId, version) => requestJson('/rest/v1/rpc/admin_rollback_news_image_guarded',
      { p_run_id: runId, p_expected_current_version: version }),
    begin: (id, version, asset) => requestJson('/rest/v1/rpc/admin_begin_home_promo_image_optimization',
      { p_id: id, p_expected_row_version: version, p_expected_asset_id: asset }),
    save: (id, version, payload) => requestJson('/rest/v1/rpc/admin_save_content_working_draft',
      { p_id: id, p_expected_draft_row_version: version, p_patch: { payload } }),
    publish: (id, version) => requestJson('/rest/v1/rpc/admin_publish_content_working_draft',
      { p_id: id, p_expected_draft_row_version: version }),
    async upload(id, bytes, journal) {
      const create = await requestJson('/functions/v1/content-media',
        { action: 'createUpload', contentItemId: id, contentType: 'image/jpeg', fileSize: bytes.length });
      insist(UUID.test(create.intentId || '') && !create.path && !create.storagePath && !create.storage_path,
        'invalid upload intent');
      await journal({step:'upload_intent',intentId:create.intentId});
      const res = await fetch(safeSignedUrl(create.signedUrl), { method: 'PUT',
        headers: { 'Content-Type': 'image/jpeg' }, body: bytes, redirect: 'error' });
      if (!res.ok) throw new Error(`upload failed (${res.status}); inspect draft manually`);
      await journal({step:'upload_put_response',intentId:create.intentId});
      await journal({step:'finalize_start',intentId:create.intentId});
      const finalized = await requestJson('/functions/v1/content-media',
        { action: 'finalizeUpload', intentId: create.intentId, title: 'optimized-image' });
      return finalized.asset;
    },
  };
}

export async function createAuthenticatedOperatorApi() {
  const base = process.env.SUPABASE_URL || '';
  const apiKey = process.env.SUPABASE_ANON_KEY || '';
  const token = process.env.SUPABASE_USER_ACCESS_TOKEN || '';
  insist(base && apiKey && token, 'Missing scoped user-session environment');
  if (!apiKey.startsWith('sb_publishable_')) {
    let keyClaims;
    try { keyClaims = JSON.parse(Buffer.from(apiKey.split('.')[1], 'base64url').toString('utf8')); } catch (_) { throw new Error('Only a publishable/anon API key is allowed'); }
    insist(keyClaims?.role === 'anon', 'Only a publishable/anon API key is allowed');
  }
  let claims;
  try { claims = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString('utf8')); } catch (_) { throw new Error('Invalid user token'); }
  insist(claims?.role === 'authenticated' && UUID.test(claims.sub || ''), 'Only an authenticated user JWT is allowed');
  const origin = new URL(base);
  insist(origin.origin === PROJECT_ORIGIN && origin.pathname === '/' && !origin.username && !origin.password, 'Invalid Supabase project URL');
  const userResponse = await fetch(new URL('/auth/v1/user', origin), { headers: { apikey: apiKey, Authorization: `Bearer ${token}` }, redirect: 'error' });
  insist(userResponse.ok && (await userResponse.json()).id === claims.sub, 'Current user session rejected');
  return createApi({ base, apiKey, token });
}

async function main() {
  const args = process.argv.slice(2);
  const apply = args.includes('--apply');
  const recover = args.includes('--recover');
  const planIndex = args.indexOf('--plan');
  const journalIndex = args.indexOf('--journal');
  insist(!(apply && recover) && planIndex >= 0 && args[planIndex + 1] && (!apply || (journalIndex>=0 && args[journalIndex+1])) && args.every((x, i) => x === '--apply' || x === '--recover' || x === '--plan' || x === '--journal' || i === planIndex + 1 || i === journalIndex+1),
    'usage: node optimized_promo_switch.mjs --plan local-plan.json [--recover | --apply --journal new-file.jsonl]');
  const api = await createAuthenticatedOperatorApi();
  const plan = JSON.parse(await readFile(args[planIndex + 1], 'utf8'));
  validatePlan(plan);
  if (recover) { console.log(JSON.stringify(await inspectHomePromoRecovery({api,plan}))); return; }
  if (plan.optimizedFile) insist((await stat(plan.optimizedFile)).size <= LIMIT, 'optimized file too large');
  const optimizedBytes = plan.optimizedFile ? new Uint8Array(await readFile(plan.optimizedFile)) : undefined;
  let file;
  try {
    if (apply) file=await open(args[journalIndex+1],'wx',0o600);
    const journal=file?async event=>{await file.write(`${JSON.stringify(event)}\n`);await file.sync();}:undefined;
    const result = await switchHomePromo({ api, plan, optimizedBytes, apply, journal });
    console.log(JSON.stringify(result));
  } finally { if(file) await file.close(); }
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => { console.error(`Operation stopped: ${error.message}`); process.exitCode = 1; });
}
