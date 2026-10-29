const enc = (s: string) => encodeURIComponent(s).replace(/[!'()*]/g,
  c => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
const hex = (b: ArrayBuffer) => [...new Uint8Array(b)].map(x=>x.toString(16).padStart(2,'0')).join('');
async function hmac(key: Uint8Array, value: string) {
  const k=await crypto.subtle.importKey('raw',Uint8Array.from(key),{name:'HMAC',hash:'SHA-256'},false,['sign']);
  return new Uint8Array(await crypto.subtle.sign('HMAC',k,new TextEncoder().encode(value)));
}
export async function signChatObject(method: 'GET'|'HEAD', key: string, expires=60) {
  const bucket=Deno.env.get('YANDEX_BUCKET');
  const access=Deno.env.get('YANDEX_ACCESS_KEY_ID');
  const secret=Deno.env.get('YANDEX_SECRET_ACCESS_KEY');
  const endpoint=(Deno.env.get('YANDEX_ENDPOINT')??'storage.yandexcloud.net').replace(/^https?:\/\//,'').replace(/\/+$/,'');
  const region=Deno.env.get('YANDEX_REGION')??'ru-central1';
  if (!bucket||!access||!secret) throw new Error('storage_configuration');
  const host=`${bucket}.${endpoint}`;
  const time=new Date().toISOString().replace(/[:-]|\.\d{3}/g,'');
  const date=time.slice(0,8), scope=`${date}/${region}/s3/aws4_request`;
  const uri='/'+key.split('/').map(enc).join('/');
  const pairs=Object.entries({'X-Amz-Algorithm':'AWS4-HMAC-SHA256',
    'X-Amz-Credential':`${access}/${scope}`,'X-Amz-Date':time,
    'X-Amz-Expires':String(expires),'X-Amz-SignedHeaders':'host'});
  const query=pairs.sort(([a],[b])=>a<b?-1:a>b?1:0).map(([k,v])=>`${enc(k)}=${enc(v)}`).join('&');
  const canonical=[method,uri,query,`host:${host}\n`,'host','UNSIGNED-PAYLOAD'].join('\n');
  const hash=hex(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(canonical)));
  let signing=await hmac(new TextEncoder().encode('AWS4'+secret),date);
  for(const part of [region,'s3','aws4_request']) signing=await hmac(signing,part);
  const signature=hex((await hmac(signing,['AWS4-HMAC-SHA256',time,scope,hash].join('\n'))).buffer);
  return `https://${host}${uri}?${query}&X-Amz-Signature=${signature}`;
}
