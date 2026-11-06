/** Guarded, journalled news-image replacement; no automatic deletion or retry.
 * Requires the reviewed news guard migration and matching Edge function.
 * --apply requires an exclusive new local JSONL journal path.
 */
import { createHash } from 'node:crypto';
import { readFile, stat, open } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { createAuthenticatedOperatorApi } from './optimized_promo_switch.mjs';
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PATH=/^news\/[0-9a-f-]{36}\/[0-9a-f-]{36}\.(jpg|png|webp)$/i;
const SHA=/^[0-9a-f]{64}$/;
const LIMIT=5*1024*1024;
const hash=(name, bytes)=>createHash(name).update(bytes).digest('hex');
function insist(ok,message){if(!ok)throw new Error(message);}
function detectMime(bytes) {
 if(bytes.length>=3&&bytes[0]===0xff&&bytes[1]===0xd8&&bytes[2]===0xff)return 'image/jpeg';
 if(bytes.length>=8&&Buffer.from(bytes.subarray(0,8)).equals(Buffer.from([137,80,78,71,13,10,26,10])))return 'image/png';
 if(bytes.length>=12&&Buffer.from(bytes.subarray(0,4)).toString()==='RIFF'&&Buffer.from(bytes.subarray(8,12)).toString()==='WEBP')return 'image/webp';
 return '';
}
function expectBytes(bytes, sha, label){
 insist(bytes instanceof Uint8Array&&bytes.length>0&&bytes.length<=LIMIT&&hash('sha256',bytes)===sha,`${label} checksum or size mismatch`);
}
function validPlan(plan){
 insist(plan&&UUID.test(plan.newsId||'')&&Number.isSafeInteger(plan.version)&&plan.version>0&&PATH.test(plan.currentPath||'')&&SHA.test(plan.currentSha256||''),'invalid news plan');
 const rollback=plan.runId!=null;
 if(rollback){
  insist(UUID.test(plan.runId)&&PATH.test(plan.originalPath||'')&&PATH.test(plan.backupPath||'')&&
   plan.originalPath!==plan.backupPath&&SHA.test(plan.originalSha256||''),'invalid rollback plan');
 }else{
  insist(typeof plan.originalFile==='string'&&plan.originalFile&&typeof plan.optimizedFile==='string'&&plan.optimizedFile&&
   SHA.test(plan.optimizedSha256||''),'invalid image files');
 }
 return rollback;
}
async function writeJournal(journal,event){
 insist(typeof journal==='function','apply requires an exclusive local journal');
 await journal(event);
}
function checkPost(post,plan){
 insist(post?.id===plan.newsId&&post.status==='published'&&post.version_number===plan.version&&
  post.image_path===plan.currentPath,'news changed; stop and inspect');
}

export async function switchNewsImage({api,plan,originalBytes,optimizedBytes,apply=false,journal}){
 const rollback=validPlan(plan);
 checkPost(await api.getNews(plan.newsId),plan);
 const current=await api.downloadNews(plan.currentPath);
 expectBytes(current,plan.currentSha256,'current news image');
 if(rollback){
  const backup=await api.downloadNews(plan.backupPath);
  expectBytes(backup,plan.originalSha256,'rollback backup');
  if(!apply)return {status:'preflight_only',action:'rollback'};
  await writeJournal(journal,{step:'rollback_start',newsId:plan.newsId,runId:plan.runId,
    version:plan.version,currentPath:plan.currentPath,backupPath:plan.backupPath});
  const result=await api.rollbackNews(plan.runId,plan.version);
  insist(result?.run_id===plan.runId&&result.version_number===plan.version+1,'rollback result uncertain');
  await writeJournal(journal,{step:'rollback_response',runId:plan.runId,version:result.version_number});
  const after=await api.getNews(plan.newsId);
  insist(after?.id===plan.newsId&&after.status==='published'&&after.version_number===plan.version+1&&
    (after.image_path===plan.originalPath||after.image_path===plan.backupPath),'rollback result uncertain; inspect manually');
  expectBytes(await api.downloadNews(after.image_path),plan.originalSha256,'restored news image');
  expectBytes(await api.downloadNews(plan.currentPath),plan.currentSha256,'retained optimized image');
  await writeJournal(journal,{step:'rollback_verified',runId:plan.runId,version:after.version_number});
  return {status:'rolled_back',runId:plan.runId,version:after.version_number};
 }
 expectBytes(originalBytes,plan.currentSha256,'local original');
 expectBytes(optimizedBytes,plan.optimizedSha256,'optimized image');
 const oldMime=detectMime(originalBytes);
 insist(oldMime&&detectMime(optimizedBytes)==='image/jpeg'&&optimizedBytes.length<originalBytes.length,'images cannot be safely switched');
 if(!apply)return {status:'preflight_only',action:'optimize'};
 await writeJournal(journal,{step:'prepare',newsId:plan.newsId,version:plan.version,currentPath:plan.currentPath,
  currentSha256:plan.currentSha256,optimizedSha256:plan.optimizedSha256});
 const backup=await api.uploadNews('backup',originalBytes,oldMime,
  value=>writeJournal(journal,{step:'backup_reserved',...value}));
 insist(PATH.test(backup?.path||'')&&UUID.test(backup?.reservationId||'')&&backup.path!==plan.currentPath,'invalid backup reservation');
 expectBytes(await api.downloadNews(backup.path),plan.currentSha256,'stored backup');
 const optimized=await api.uploadNews('optimized',optimizedBytes,'image/jpeg',
  value=>writeJournal(journal,{step:'optimized_reserved',...value}));
 insist(PATH.test(optimized?.path||'')&&UUID.test(optimized?.reservationId||'')&&
  optimized.path!==plan.currentPath&&optimized.path!==backup.path,'invalid optimized reservation');
 expectBytes(await api.downloadNews(optimized.path),plan.optimizedSha256,'stored optimized image');
 // A changed post causes a stop even before the authoritative server CAS.
 checkPost(await api.getNews(plan.newsId),plan);
 const params={p_news_id:plan.newsId,p_expected_version:plan.version,p_expected_old_path:plan.currentPath,
  p_backup_path:backup.path,p_new_path:optimized.path,p_old_etag:hash('md5',originalBytes),
  p_old_size:originalBytes.length,p_old_mime:oldMime,p_new_etag:hash('md5',optimizedBytes),p_new_size:optimizedBytes.length};
 await writeJournal(journal,{step:'apply_start',newsId:plan.newsId,version:plan.version,
  originalPath:plan.currentPath,backupPath:backup.path,optimizedPath:optimized.path,
  originalSha256:plan.currentSha256,optimizedSha256:plan.optimizedSha256});
 const result=await api.applyNews(params);
 insist(UUID.test(result?.run_id||'')&&result.version_number===plan.version+1,'apply result uncertain');
 await writeJournal(journal,{step:'apply_response',runId:result.run_id,version:result.version_number});
 const after=await api.getNews(plan.newsId);
 insist(after?.id===plan.newsId&&after.status==='published'&&after.version_number===plan.version+1&&after.image_path===optimized.path,
  'publication result uncertain; inspect manually');
 expectBytes(await api.downloadNews(after.image_path),plan.optimizedSha256,'published news image');
 expectBytes(await api.downloadNews(plan.currentPath),plan.currentSha256,'original news image');
 expectBytes(await api.downloadNews(backup.path),plan.currentSha256,'retained backup');
 await writeJournal(journal,{step:'apply_verified',runId:result.run_id,version:after.version_number});
 return {status:'published',runId:result.run_id,version:after.version_number};
}

async function main(){
 const args=process.argv.slice(2),apply=args.includes('--apply');
 const pi=args.indexOf('--plan'),ji=args.indexOf('--journal');
 insist(pi>=0&&args[pi+1]&&(!apply||(ji>=0&&args[ji+1]))&&
  args.every((x,i)=>x==='--apply'||x==='--plan'||x==='--journal'||i===pi+1||i===ji+1),
  'usage: node optimized_news_switch.mjs --plan local-plan.json [--apply --journal new-local-file.jsonl]');
 const api=await createAuthenticatedOperatorApi();
 const plan=JSON.parse(await readFile(args[pi+1],'utf8'));
 const rollback=validPlan(plan);
 let originalBytes,optimizedBytes;
 if(!rollback){
  insist((await stat(plan.originalFile)).size<=LIMIT&&(await stat(plan.optimizedFile)).size<=LIMIT,'image too large');
  originalBytes=new Uint8Array(await readFile(plan.originalFile));
  optimizedBytes=new Uint8Array(await readFile(plan.optimizedFile));
 }
 let file;
 try{
  if(apply)file=await open(args[ji+1],'wx',0o600);
  const journal=file?async event=>{await file.write(`${JSON.stringify(event)}\n`);await file.sync();}:undefined;
  const result=await switchNewsImage({api,plan,originalBytes,optimizedBytes,apply,journal});
  console.log(JSON.stringify(result));
 }finally{if(file)await file.close();}
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
 main().catch(error=>{console.error(`Operation stopped: ${error.message}`);process.exitCode=1;});
}
