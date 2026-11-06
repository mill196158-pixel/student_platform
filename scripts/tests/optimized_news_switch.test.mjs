import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { switchNewsImage } from '../optimized_news_switch.mjs';
const sha=b=>createHash('sha256').update(b).digest('hex');
const POST='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', RUN='cccccccc-cccc-cccc-cccc-cccccccccccc';
const USER='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const OLD=`news/${USER}/11111111-1111-1111-1111-111111111111.jpg`;
const BACKUP=`news/${USER}/22222222-2222-2222-2222-222222222222.jpg`;
const NEW=`news/${USER}/33333333-3333-3333-3333-333333333333.jpg`;
const RES1='44444444-4444-4444-4444-444444444444', RES2='55555555-5555-5555-5555-555555555555';
const original=Uint8Array.from([255,216,255,...Array(997).fill(4)]);
const optimized=Uint8Array.from([255,216,255,...Array(97).fill(7)]);
function fixture(){
 const state={post:{id:POST,status:'published',version_number:4,image_path:OLD,title:'Original'},
  files:new Map([[OLD,original]]),calls:[],journal:[],run:null,applyCount:0,rollbackCount:0};
 const api={
  getNews:async()=>structuredClone(state.post),
  downloadNews:async path=>state.files.get(path),
  uploadNews:async(purpose,bytes,_mime,onReserved)=>{
   const data=purpose==='backup'?{path:BACKUP,reservationId:RES1}:{path:NEW,reservationId:RES2};
   state.calls.push(`reserve_${purpose}`);await onReserved(data);
   state.calls.push(`put_${purpose}`);state.files.set(data.path,bytes);return data;
  },
  applyNews:async params=>{state.calls.push('apply');state.applyCount++;
   if(params.p_expected_version!==state.post.version_number||params.p_expected_old_path!==state.post.image_path)throw Error('conflict');
   state.run={old:OLD,new:params.p_new_path,backup:params.p_backup_path};
   state.post.image_path=params.p_new_path;state.post.version_number++;return {run_id:RUN,version_number:state.post.version_number};},
  rollbackNews:async(run,version)=>{state.calls.push('rollback');state.rollbackCount++;
   if(run!==RUN||version!==state.post.version_number)throw Error('conflict');
   state.post.image_path=state.run.old;state.post.version_number++;return {run_id:RUN,version_number:state.post.version_number};},
 };
 const plan={newsId:POST,version:4,currentPath:OLD,currentSha256:sha(original),originalFile:'original.bin',
  optimizedFile:'small.jpg',optimizedSha256:sha(optimized)};
 return {api,state,plan,journal:async e=>{state.journal.push(structuredClone(e));}};
}

test('preflight makes no mutation and verifies both files',async()=>{
 const f=fixture();const r=await switchNewsImage({...f,originalBytes:original,optimizedBytes:optimized});
 assert.equal(r.status,'preflight_only');assert.deepEqual(f.state.calls,[]);
});
test('apply saves and verifies original backup before switching a new path',async()=>{
 const f=fixture();const r=await switchNewsImage({...f,originalBytes:original,optimizedBytes:optimized,apply:true});
 assert.equal(r.runId,RUN);assert.equal(f.state.post.image_path,NEW);assert.equal(f.state.post.version_number,5);
 assert.deepEqual(f.state.files.get(OLD),original);assert.deepEqual(f.state.files.get(BACKUP),original);
 assert.deepEqual(f.state.journal.map(x=>x.step),['prepare','backup_reserved','optimized_reserved','apply_start','apply_response','apply_verified']);
 assert.deepEqual(f.state.calls,['reserve_backup','put_backup','reserve_optimized','put_optimized','apply']);
});
test('changed post stops before CAS; uploaded copies are retained for inspection',async()=>{
 const f=fixture();let n=0;const real=f.api.getNews;
 f.api.getNews=async()=>{n++;if(n===2)f.state.post.version_number++;return real();};
 await assert.rejects(switchNewsImage({...f,originalBytes:original,optimizedBytes:optimized,apply:true}));
 assert.equal(f.state.applyCount,0);assert.ok(f.state.files.has(BACKUP));assert.ok(f.state.files.has(NEW));
});
test('invalid stored backup stops before derivative or switch',async()=>{
 const f=fixture();const upload=f.api.uploadNews;
 f.api.uploadNews=async(...args)=>{const r=await upload(...args);if(args[0]==='backup')f.state.files.set(BACKUP,new Uint8Array([1]));return r;};
 await assert.rejects(switchNewsImage({...f,originalBytes:original,optimizedBytes:optimized,apply:true}));
 assert.equal(f.state.applyCount,0);assert.ok(!f.state.files.has(NEW));
});
test('lost apply response does not retry or remove reservations',async()=>{
 const f=fixture();const apply=f.api.applyNews;
 f.api.applyNews=async params=>{await apply(params);throw Error('network lost');};
 await assert.rejects(switchNewsImage({...f,originalBytes:original,optimizedBytes:optimized,apply:true}));
 assert.equal(f.state.applyCount,1);assert.equal(f.state.post.image_path,NEW);
 assert.equal(f.state.journal.at(-1).step,'apply_start');assert.ok(f.state.files.has(BACKUP));
});
test('rollback checks backup and leaves both versions intact',async()=>{
 const f=fixture();await switchNewsImage({...f,originalBytes:original,optimizedBytes:optimized,apply:true});
 const rollback={newsId:POST,version:5,currentPath:NEW,currentSha256:sha(optimized),runId:RUN,
  originalPath:OLD,backupPath:BACKUP,originalSha256:sha(original)};
 const r=await switchNewsImage({api:f.api,plan:rollback,apply:true,journal:f.journal});
 assert.equal(r.status,'rolled_back');assert.equal(f.state.post.image_path,OLD);assert.ok(f.state.files.has(NEW));
});
