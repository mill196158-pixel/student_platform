import {signChatObject} from '../_shared/chat_object_signing.ts';
const cors={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info','Access-Control-Allow-Methods':'POST,OPTIONS','Cache-Control':'no-store'};
const reply=(data:unknown,status=200)=>Response.json(data,{status,headers:cors});
class AccessDenied extends Error {}
class AuthenticationDenied extends Error {}
class UnclassifiedClientFailure extends Error {}
class ConfirmedOutage extends Error {}
async function networkFetch(input: string | URL, init?: RequestInit): Promise<Response> {
  try { return await fetch(input, init); } catch (_) { throw new ConfirmedOutage(); }
}
async function signedObject(method: 'GET' | 'HEAD', key: string): Promise<string> {
  try { return await signChatObject(method,key); } catch (_) { throw new ConfirmedOutage(); }
}
Deno.serve(async req=>{
  if(req.method==='OPTIONS') return new Response('ok',{headers:cors});
  if(req.method!=='POST') return reply({error:'method_not_allowed'},405);
  const base=Deno.env.get('SUPABASE_URL')!;
  const anon=Deno.env.get('SUPABASE_ANON_KEY')!;
  const authorization=req.headers.get('Authorization')??'';
  try {
    const auth=await networkFetch(`${base}/auth/v1/user`,{headers:{apikey:anon,Authorization:authorization}});
    if(auth.status===401||auth.status===403) return reply({error:'unauthorized'},401);
    if(auth.status>=400 && auth.status<500) return reply({error:'service_unavailable'},503);
    if(!auth.ok) return reply(auth.status>=500 ? {error:'service_unavailable',accessPolicyVersion:1} : {error:'service_unavailable'},503);
    const user=await auth.json();
    if(typeof user.id!=='string') return reply({error:'unauthorized'},401);
    const body=await req.json();
    const key=body.key;
    if(typeof key!=='string'||key.length>2048||!/^(chats|diaries)\/[a-f0-9-]{36}\/.+/.test(key)) return reply({error:'invalid_key'},400);
    async function rpc(name:string,params:unknown,admin=false){
      const token=admin?`Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')}`:authorization;
      const response=await networkFetch(`${base}/rest/v1/rpc/${name}`,{method:'POST',headers:{apikey:admin?Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!:anon,Authorization:token,'Content-Type':'application/json'},body:JSON.stringify(params)});
      if(!response.ok) {
        const error=await response.json().catch(()=>null);
        if(response.status===401 || (response.status===403 && name==='resolve_chat_file_access' && error?.code==='42501' && error?.message==='not_authenticated')) {
          throw new AuthenticationDenied();
        }
        if(response.status===403 && name==='resolve_chat_file_access' && error?.code==='42501' && error?.message==='file_unavailable') {
          throw new AccessDenied();
        }
        if(response.status>=500) throw new ConfirmedOutage();
        throw new UnclassifiedClientFailure();
      }
      const raw=await response.text();return raw?JSON.parse(raw):null;
    }
    if(body.action==='confirm'){
      const intent=await rpc('inspect_chat_file_upload',{p_key:key,p_actor:user.id},true);
      const head=await networkFetch(await signedObject('HEAD',intent.key),{method:'HEAD'});
      if(!head.ok||Number(head.headers.get('content-length'))!==intent.size||
          head.headers.get('content-type')?.split(';')[0]!==intent.type.split(';')[0]) return reply({error:'upload_mismatch'},409);
      await rpc('confirm_chat_file_upload',{p_key:key,p_actor:user.id},true);
      return reply({confirmed:true});
    }
    if(body.action!=='resolve') return reply({error:'invalid_action'},400);
    const file=await rpc('resolve_chat_file_access',{p_key:key});
    return reply({url:await signedObject('GET',file.key),expiresIn:60,accessPolicyVersion:1,fileId:file.id,cacheable:file.cacheable===true});
  }catch(error){
    if(error instanceof AccessDenied) return reply({error:'file_unavailable',reason:'access_denied_v1'},403);
    if(error instanceof AuthenticationDenied) return reply({error:'unauthorized'},401);
    if(error instanceof UnclassifiedClientFailure) return reply({error:'service_unavailable'},503);
    if(error instanceof ConfirmedOutage) return reply({error:'service_unavailable',accessPolicyVersion:1},503);
    return reply({error:'service_unavailable'},503);
  }
});
