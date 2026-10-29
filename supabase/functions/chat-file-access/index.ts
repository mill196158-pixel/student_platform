import {signChatObject} from '../_shared/chat_object_signing.ts';
const cors={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info','Access-Control-Allow-Methods':'POST,OPTIONS','Cache-Control':'no-store'};
const reply=(data:unknown,status=200)=>Response.json(data,{status,headers:cors});
Deno.serve(async req=>{
  if(req.method==='OPTIONS') return new Response('ok',{headers:cors});
  if(req.method!=='POST') return reply({error:'method_not_allowed'},405);
  const base=Deno.env.get('SUPABASE_URL')!;
  const anon=Deno.env.get('SUPABASE_ANON_KEY')!;
  const authorization=req.headers.get('Authorization')??'';
  try {
    const auth=await fetch(`${base}/auth/v1/user`,{headers:{apikey:anon,Authorization:authorization}});
    if(!auth.ok) return reply({error:'unauthorized'},401);
    const user=await auth.json();
    if(typeof user.id!=='string') return reply({error:'unauthorized'},401);
    const body=await req.json();
    const key=body.key;
    if(typeof key!=='string'||key.length>2048||!/^(chats|diaries)\/[a-f0-9-]{36}\/.+/.test(key)) return reply({error:'invalid_key'},400);
    async function rpc(name:string,params:unknown,admin=false){
      const token=admin?`Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')}`:authorization;
      const response=await fetch(`${base}/rest/v1/rpc/${name}`,{method:'POST',headers:{apikey:admin?Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!:anon,Authorization:token,'Content-Type':'application/json'},body:JSON.stringify(params)});
      if(!response.ok) throw new Error('access_denied');
      const raw=await response.text();return raw?JSON.parse(raw):null;
    }
    if(body.action==='confirm'){
      const intent=await rpc('inspect_chat_file_upload',{p_key:key,p_actor:user.id},true);
      const head=await fetch(await signChatObject('HEAD',intent.key),{method:'HEAD'});
      if(!head.ok||Number(head.headers.get('content-length'))!==intent.size||
          head.headers.get('content-type')?.split(';')[0]!==intent.type.split(';')[0]) return reply({error:'upload_mismatch'},409);
      await rpc('confirm_chat_file_upload',{p_key:key,p_actor:user.id},true);
      return reply({confirmed:true});
    }
    if(body.action!=='resolve') return reply({error:'invalid_action'},400);
    const file=await rpc('resolve_chat_file_access',{p_key:key});
    return reply({url:await signChatObject('GET',file.key),expiresIn:60,fileId:file.id,cacheable:file.cacheable===true});
  }catch{
    return reply({error:'file_unavailable'},403);
  }
});
