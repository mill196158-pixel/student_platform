"""Explicitly approved synthetic REST regression after RPC-only write grants."""
import argparse, json, time, uuid
import approved_live_regression as a
parser=argparse.ArgumentParser();parser.add_argument('--approved',action='store_true');args=parser.parse_args()
if not args.approved:raise SystemExit('Owner approval required')
f=json.loads(a.MANIFEST.read_text());assert not f.get('cleaned')
tokens=[]
for user in f['users'][:3]:
    code,row=a.request('/auth/v1/token?grant_type=password',{'email':user['login']+'@student.local','password':f['password']})
    assert code==200 and row['user']['user_metadata']['test_run']==f['run']
    tokens.append(row['access_token'])
owner,author,outsider=tokens;team=f['academic']['subject_team']
def rpc(name,token,**params):
    code,row=a.rpc(name,token,**params)
    if code>=300:raise RuntimeError((name,code,row.get('code')))
    return row
marker='E2E assignment grants '+f['run'];f.setdefault('planned_actions',[]).append(marker);a.save(f)
created=rpc('propose_assignment',author,p_team_id=team,p_title=marker,p_description='Synthetic',p_link='',p_due='',p_attachments=[])
id=created['assignment_id'];f.setdefault('guard_assignments',[]).append(id);a.save(f)
for method,path,body,token in [
 ('POST','/rest/v1/assignments',{'id':str(uuid.uuid4()),'team_id':team,'title':marker},owner),
 ('PATCH','/rest/v1/assignments?id=eq.'+id,{'title':'forbidden'},author),
 ('DELETE','/rest/v1/assignments?id=eq.'+id,None,outsider),
 ('POST','/rest/v1/assignment_done',{'assignment_id':id,'user_id':f['users'][2]['id']},outsider)]:
    code,_=a.request(path,body,token=token,method=method);assert code in (401,403),(method,code)
print('PASS direct REST writes blocked')
for name,params in [('remove_assignment',{'p_assignment_id':id}),('update_assignment',{'p_assignment_id':id,'p_title':'bad','p_description':'','p_link':'','p_due':'','p_attachments':[]}),('set_assignment_done',{'p_assignment_id':id,'p_done':True})]:
    for token in [outsider,None]:
        code,_=a.request('/rest/v1/rpc/'+name,params,token=token);assert code in (401,403),(name,code)
print('PASS outsider and anonymous RPC mutations blocked')
rpc('vote_assignment',author,p_assignment_id=id);votes=rpc('vote_assignment',author,p_assignment_id=id);assert votes['votes']==1
rpc('publish_assignment',owner,p_assignment_id=id)
assert rpc('set_assignment_done',author,p_assignment_id=id,p_done=True) is True
assert rpc('set_assignment_done',author,p_assignment_id=id,p_done=False) is False
rpc('update_assignment',author,p_assignment_id=id,p_title=marker+' edited',p_description='changed',p_link='',p_due='',p_attachments=[])
code,rows=a.request('/rest/v1/assignments?id=eq.'+id+'&select=id,title',token=owner);assert code==200 and rows[0]['title']==marker+' edited'
rpc('remove_assignment',author,p_assignment_id=id)
code,rows=a.request('/rest/v1/assignments?id=eq.'+id+'&select=id',token=owner);assert code==200 and rows==[]
print('PASS RPC create/vote idempotency/publish/done/undo/author edit/delete and member SELECT preserved')
