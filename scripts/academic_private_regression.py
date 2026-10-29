"""Live synthetic group: collections/proof/topic ACL and conflict regression."""
import concurrent.futures, json, urllib.request, uuid
import approved_live_regression as a
f=json.loads(a.MANIFEST.read_text());tokens=[];results=[]
def check(name,ok):
 results.append({'scenario':name,'passed':bool(ok)});print(('PASS ' if ok else 'FAIL ')+name,flush=True)
 (a.WORK/'academic-private-results.json').write_text(json.dumps(results,indent=2),'utf-8')
 if not ok: raise RuntimeError(name)
for u in f['users']:
 code,v=a.request('/auth/v1/token?grant_type=password',{'email':u['login']+'@student.local','password':f['password']});assert code==200;tokens.append(v['access_token'])
ta,tb,tc=tokens;chat=f['academic']['chat'];team=f['academic']['team']
def upload(token,proof=False):
 body=b'E2E academic file';code,v=a.request('/functions/v1/generate-upload-url',{'chatId':chat,'fileName':'academic-fixture.txt','contentType':'text/plain','fileSize':len(body)},token);assert code==200,(code,v)
 item={'key':v['fileKey'],'url':v['fileUrl'],'chat':chat,'object_deleted':False};f.setdefault('files',[]).append(item);a.save(f)
 with a.opener.open(urllib.request.Request(v['uploadUrl'],data=body,method='PUT',headers=v['headers']),timeout=30) as r:assert r.status==200
 code,v=a.request('/functions/v1/chat-file-access',{'action':'confirm','key':item['key']},token);assert code==200,(code,v)
 if proof:code,fid=a.rpc('save_collection_proof_upload',token,p_key=item['key'])
 else:code,fid=a.rpc('save_chat_file',token,p_chat_id=chat,p_file_name='x',p_file_key=item['key'],p_file_url=item['url'],p_file_type='text/plain',p_file_size=len(body))
 assert code==200,(code,fid);item['id']=fid;a.save(f);return item
file=upload(ta)
params={'p_client_key':str(uuid.uuid4()),'p_title':'E2E concurrent collection','p_file_ids':[file['id']]}
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool: replies=list(pool.map(lambda _:a.rpc('create_group_collection_with_files',ta,**params),range(2)))
check('concurrent publication returns same collection',all(c==200 for c,_ in replies) and replies[0][1]==replies[1][1]);coll=replies[0][1]
check('referenced collection file survives discard',a.rpc('discard_unattached_chat_upload',ta,p_key=file['key'])==(200,False))
check('changed retry payload rejected',a.rpc('create_group_collection_with_files',ta,**dict(params,p_title='changed'))[0]>=400)
proof=upload(tb,True)
check('orphan sensitive proof unreadable',a.request('/functions/v1/chat-file-access',{'action':'resolve','key':proof['key']},tb)[0]==403)
code,v=a.rpc('upsert_my_collection_contribution',tb,p_collection_id=coll,p_participation_status='joining',p_payment_status='reported',p_amount=10,p_proof_file_id=proof['id']);check('participant reports payment with proof',code<300)
for name,token,allowed in [('proof owner',tb,True),('organizer',ta,True),('outsider',tc,False)]:
 code,v=a.request('/functions/v1/chat-file-access',{'action':'resolve','key':proof['key']},token)
 check(name+' proof rights',code==200 if allowed else code==403)
 if allowed:check(name+' proof not cached offline',v.get('cacheable') is False)
check('proof cannot be public chat attachment',a.rpc('send_message_in_chat_with_files',tb,p_chat_id=chat,p_text='forbidden',p_file_ids=[proof['id']])[0]>=400)
check('member cannot confirm own payment',a.rpc('confirm_collection_contribution',tb,p_collection_id=coll,p_user_id=f['users'][1]['id'],p_payment_status='confirmed')[0]>=400)
check('organizer confirms payment',a.rpc('confirm_collection_contribution',ta,p_collection_id=coll,p_user_id=f['users'][1]['id'],p_payment_status='confirmed')[0]<300)
chat=f['academic']['subject_chat']
source=upload(ta)
code,v=a.rpc('publish_topic_selection_for_chat',ta,p_chat_id=chat,p_title='E2E topic contest',p_source_file_id=source['id'],p_options=[{'title':'One place','capacity':1,'sort_order':0}]);check('publish topic with source attachment',code==200)
selection=v.get('selection_id') or v.get('id');assert selection,v
code,options=a.rpc('list_topic_options_for_selection',tb,p_selection_id=selection);check('member reads topic options',code==200 and len(options)==1);option=options[0]['id']
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool: picks=list(pool.map(lambda token:a.rpc('pick_topic',token,p_selection_id=selection,p_option_id=option),[ta,tb]))
check('one-place topic has one winner under concurrency',sum(code<300 for code,_ in picks)==1)
check('topic source survives discard',a.rpc('discard_unattached_chat_upload',ta,p_key=source['key'])==(200,False))
check('outsider topic read denied',a.rpc('list_topic_options_for_selection',tc,p_selection_id=selection)==(200,[]))
winner=ta if picks[0][0]<300 else tb
check('winner cancels topic pick',a.rpc('cancel_topic_pick',winner,p_selection_id=selection)[0]<300)
check('organizer closes topic selection',a.rpc('close_topic_selection',ta,p_selection_id=selection)[0]<300)
check('closed topic rejects new pick',a.rpc('pick_topic',tb,p_selection_id=selection,p_option_id=option)[0]>=400)
print('All academic checks passed',len(results))
