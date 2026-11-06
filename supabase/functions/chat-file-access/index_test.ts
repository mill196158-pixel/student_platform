// Local contract test: network and credentials are replaced with synthetic data.
let handler: (request: Request) => Promise<Response>;
// The function registers one handler at module import. Do not open a socket.
// @ts-ignore: test-only replacement of Deno.serve.
Deno.serve = (h: typeof handler) => { handler = h; return {}; };
Deno.env.set('SUPABASE_URL', 'https://supabase.invalid');
Deno.env.set('SUPABASE_ANON_KEY', 'synthetic');
Deno.env.set('YANDEX_BUCKET', 'example');
Deno.env.set('YANDEX_ACCESS_KEY_ID', 'synthetic');
Deno.env.set('YANDEX_SECRET_ACCESS_KEY', 'synthetic');
await import('./index.ts');
const key = 'chats/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/a.png';
let mode = 'ok';
globalThis.fetch = async (input: string | URL | Request) => {
  const url = String(input);
  if (url.endsWith('/auth/v1/user')) {
    if (mode === 'malformedAuth') return new Response('{', {status:200});
    if (mode === 'auth') return Response.json({}, {status:401});
    if (mode === 'auth400') return Response.json({}, {status:400});
    if (mode === 'auth429') return Response.json({}, {status:429});
    if (mode === 'authOutage') return Response.json({}, {status:503});
    return Response.json({id:'synthetic-user'});
  }
  if (url.includes('/rest/v1/rpc/resolve_chat_file_access')) {
    if (mode === 'malformedRpc') return new Response('{', {status:200});
    if (mode === 'deny') return Response.json({code:'42501', message:'file_unavailable'}, {status:403});
    if (mode === 'rpcAuth') return Response.json({}, {status:401});
    if (mode === 'rpcNotAuthenticated') return Response.json({code:'42501', message:'not_authenticated'}, {status:403});
    if (mode === 'unexpected403') return Response.json({code:'XX000', message:'outage'}, {status:403});
    if (mode === 'rpcOutage') return Response.json({}, {status:503});
    return Response.json({key,id:'synthetic-id',cacheable:false});
  }
  throw new Error('unexpected mock request');
};
async function call(): Promise<[number, Record<string, unknown>]> {
  const response = await handler(new Request('http://test/', {method:'POST',headers:{'Content-Type':'application/json','Authorization':'Bearer synthetic'},body:JSON.stringify({action:'resolve',key})}));
  return [response.status, await response.json()];
}
function check(value: boolean, message: string) { if (!value) throw new Error(message); }
Deno.test('typed access contract distinguishes denial from outages and keeps cacheability', async () => {
  mode = 'ok'; let [status, body] = await call();
  check(status===200 && body.accessPolicyVersion===1 && body.cacheable===false && typeof body.url==='string', 'typed success');
  mode = 'deny'; [status, body] = await call();
  check(status===403 && body.error==='file_unavailable' && body.reason==='access_denied_v1', 'typed ACL denial');
  for (mode of ['rpcOutage','authOutage']) {
    [status,body] = await call();
    check(status===503 && body.error==='service_unavailable' && body.accessPolicyVersion===1, `outage ${mode}`);
  }
  mode = 'unexpected403'; [status,body] = await call();
  check(status===503 && body.error==='service_unavailable' && body.accessPolicyVersion===undefined, 'unclassified 403');
  for (mode of ['auth400','auth429','malformedAuth','malformedRpc']) {
    [status,body] = await call();
    check(status===503 && body.error==='service_unavailable' && body.accessPolicyVersion===undefined, `unclassified auth ${mode}`);
  }
  for (mode of ['rpcAuth','rpcNotAuthenticated']) {
    [status,body] = await call();
    check(status===401 && body.error==='unauthorized', `rpc auth ${mode}`);
  }
  mode = 'auth'; [status,body] = await call();
  check(status===401 && body.error==='unauthorized', 'auth error');
  mode = 'ok'; Deno.env.delete('YANDEX_SECRET_ACCESS_KEY');
  [status,body] = await call();
  check(status===503 && body.error==='service_unavailable' && body.accessPolicyVersion===1, 'signing outage');
});
