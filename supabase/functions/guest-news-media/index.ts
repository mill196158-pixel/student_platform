const cors = {'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'apikey, content-type, authorization, x-client-info','Access-Control-Allow-Methods':'POST, OPTIONS'};
const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,'Content-Type':'application/json','Cache-Control':'no-store'}});
Deno.serve(async(req:Request)=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:cors});
 if(req.method!=='POST')return reply({error:'method'},405);
 try {
  const {id}=await req.json();
  if(typeof id!=='string'||!/^[0-9a-f-]{36}$/i.test(id))return reply({error:'id'},400);
  const base=Deno.env.get('SUPABASE_URL')!;
  const key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const headers={'apikey':key,'Authorization':`Bearer ${key}`,'Content-Type':'application/json'};
  const rows=await fetch(`${base}/rest/v1/rpc/get_guest_news`,{method:'POST',headers,body:'{}',signal:AbortSignal.timeout(8000)});
  if(!rows.ok)return reply({error:'unavailable'},503);
  const data=await rows.json();
  const row=Array.isArray(data)?data.find((r)=>r.id===id):null;
  const path=row?.image_path;
  if(typeof path!=='string'||!/^news\/[0-9a-f-]{36}\/[0-9a-f-]{36}\.(jpg|png|webp)$/i.test(path))return reply({error:'not_found'},404);
  const signed=await fetch(`${base}/storage/v1/object/sign/news-media/${path}`,{method:'POST',headers,body:JSON.stringify({expiresIn:300}),signal:AbortSignal.timeout(8000)});
  if(!signed.ok)return reply({error:'unavailable'},503);
  const result=await signed.json();
  if(typeof result.signedURL!=='string')return reply({error:'unavailable'},503);
  return reply({signedUrl:`${base}/storage/v1${result.signedURL}`,expiresIn:300});
 }catch{return reply({error:'unavailable'},503);}
});
