import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { switchHomePromo, inspectHomePromoRecovery } from '../optimized_promo_switch.mjs';
const journal = async () => {};
const sha = b => createHash('sha256').update(b).digest('hex');
const ID='eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
const OLD='ffffffff-ffff-ffff-ffff-ffffffffffff';
const NEW='dddddddd-dddd-dddd-dddd-dddddddddddd';
const DRAFT='cccccccc-cccc-cccc-cccc-cccccccccccc';
const oldBytes = Uint8Array.from({length: 1000}, (_, i) => i % 256);
const newBytes = Uint8Array.from([0xff,0xd8,0xff,1,2,3,4,5]);
const clone = x => structuredClone(x);
function fixture() {
  const state = { item: { id:ID, template_key:'home_promo_v1',status:'published',row_version:4,
    payload:{ image_asset_id:OLD,title:'Card',action:{kind:'app_screen',screen_key:'info'} },
    has_working_draft:false,asset_ids:[OLD]}, draft:null, files:new Map([[OLD,oldBytes]]), writes:[], publishCalls:0 };
  const view = () => ({ ...clone(state.item), ...(state.draft ? {working_draft:clone(state.draft)} : {}) });
  const api = {
    getItem: async () => view(),
    download: async id => state.files.get(id),
    begin: async (_id, version, asset) => {
      state.writes.push('begin');
      if (state.item.has_working_draft || version!==state.item.row_version || asset!==state.item.payload.image_asset_id) throw Error('conflict');
      state.item.has_working_draft=true;
      state.draft={id:DRAFT,base_canonical_row_version:version,row_version:1,payload:clone(state.item.payload),draft_asset_ids:[]};
      return view();
    },
    upload: async (_id,bytes) => {
      state.writes.push('upload'); state.files.set(NEW,bytes); state.item.asset_ids.push(NEW);
      state.draft.draft_asset_ids.push(NEW); state.draft.row_version++;
      return {id:NEW,mime_type:'image/jpeg',byte_size:bytes.length,working_draft_id:DRAFT,
        working_draft_row_version:state.draft.row_version,bound_to_working_draft:true};
    },
    save: async (_id,version,payload) => {
      state.writes.push('save'); if(state.draft.row_version!==version) throw Error('conflict');
      state.draft.payload=clone(payload); state.draft.row_version++; return view();
    },
    publish: async (_id,version) => {
      state.writes.push('publish'); state.publishCalls++;
      if(state.draft.row_version!==version||state.draft.base_canonical_row_version!==state.item.row_version) throw Error('conflict');
      state.item.payload=clone(state.draft.payload); state.item.row_version++;
      state.item.has_working_draft=false; state.draft=null;
    },
  };
  return {api,state,plan:{itemId:ID,rowVersion:4,currentAssetId:OLD,currentSha256:sha(oldBytes),
    optimizedFile:'local.jpg',optimizedSha256:sha(newBytes)}};
}

test('preflight verifies source and does not create a draft',async()=>{
 const {api,state,plan}=fixture();
 assert.equal((await switchHomePromo({api,plan,optimizedBytes:newBytes})).status,'preflight_only');
 assert.deepEqual(state.writes,[]); assert.equal(state.item.row_version,4);
});
test('publishes only new asset id, preserving source and other fields',async()=>{
 const {api,state,plan}=fixture(); const before=clone(state.item.payload);
 const result=await switchHomePromo({api,plan,optimizedBytes:newBytes,apply:true,journal});
 assert.equal(result.newAssetId,NEW); assert.equal(result.rowVersion,5);
 assert.deepEqual(state.item.payload,{...before,image_asset_id:NEW});
 assert.deepEqual(state.item.asset_ids,[OLD,NEW]); assert.deepEqual(state.files.get(OLD),oldBytes);
 assert.deepEqual(state.writes,['begin','upload','save','publish']);
});
test('existing draft or changed source fails before mutation',async()=>{
 const {api,state,plan}=fixture(); state.item.has_working_draft=true;
 await assert.rejects(switchHomePromo({api,plan,optimizedBytes:newBytes,apply:true,journal}));
 assert.deepEqual(state.writes,[]);
 state.item.has_working_draft=false; state.files.set(OLD,new Uint8Array([3]));
 await assert.rejects(switchHomePromo({api,plan,optimizedBytes:newBytes,apply:true,journal}));
 assert.deepEqual(state.writes,[]);
});
test('concurrent draft edit during upload aborts without publish or discard',async()=>{
 const {api,state,plan}=fixture(); const realUpload=api.upload;
 api.upload=async (...args)=>{ state.draft.payload.title='Other editor'; state.draft.row_version++; return realUpload(...args); };
 await assert.rejects(switchHomePromo({api,plan,optimizedBytes:newBytes,apply:true,journal}));
 assert.equal(state.publishCalls,0); assert.equal(state.draft.payload.title,'Other editor');
 assert.deepEqual(state.writes,['begin','upload']);
});
test('rollback reuses saved original and retains optimized asset',async()=>{
 const {api,state,plan}=fixture();
 await switchHomePromo({api,plan,optimizedBytes:newBytes,apply:true,journal});
 const rollback={itemId:ID,rowVersion:5,currentAssetId:NEW,currentSha256:sha(newBytes),targetAssetId:OLD,targetSha256:sha(oldBytes)};
 const result=await switchHomePromo({api,plan:rollback,apply:true,journal});
 assert.equal(result.action,'rollback'); assert.equal(state.item.payload.image_asset_id,OLD);
 assert.deepEqual(state.item.asset_ids,[OLD,NEW]); assert.deepEqual(state.files.get(NEW),newBytes);
});
test('lost publish response is never retried or discarded',async()=>{
 const {api,state,plan}=fixture(); const realPublish=api.publish;
 api.publish=async (...args)=>{await realPublish(...args); throw Error('connection lost');};
 const events=[];
 await assert.rejects(switchHomePromo({api,plan,optimizedBytes:newBytes,apply:true,journal:async event=>events.push(event)}));
 assert.equal(state.publishCalls,1); assert.equal(state.item.payload.image_asset_id,NEW);
 assert.equal(events.at(-1).step,'publish_start');
 const recovery=await inspectHomePromoRecovery({api,plan});
 assert.equal(recovery.item.payload.image_asset_id,NEW);
 assert.equal(recovery.item.has_working_draft,false);
 assert.equal(recovery.item.payload.title,undefined);
 assert.equal(recovery.item.payload.action,undefined);
 assert.equal(recovery.assets.find(x=>x.id===NEW).sha256,sha(newBytes));
 assert.equal(state.publishCalls,1);
});
