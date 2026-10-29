"""Owner-approved live regression, isolated synthetic records only.

Explicit --approved required. No schema changes, no real account passwords.
Manifest outside repo records created IDs before subsequent steps for cleanup.
"""
import argparse
import concurrent.futures
import json
from pathlib import Path
import secrets
import sys
import urllib.error
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]
WORK = Path('C:/student_platform_e2e')
MANIFEST = WORK/'approved-live-fixture.json'
BASE = 'https://gwdanmwluhrcfxbnplwd.supabase.co'
env = {}
for line in (ROOT/'.env.local').read_text('utf-8-sig').splitlines():
    name, sep, value = line.partition('=')
    if sep and not name.startswith('#'):
        env[name.strip()] = value.strip().strip('\"\'')
assert env.get('SUPABASE_URL',BASE).rstrip('/') == BASE

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise RuntimeError('Redirect refused')
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect())

def request(path, data=None, token=None, method=None, admin=False):
    assert path.startswith('/') and not path.startswith('//')
    key = env['SUPABASE_SERVICE_ROLE_KEY'] if admin else env['SUPABASE_ANON_KEY']
    req=urllib.request.Request(BASE+path,
        data=None if data is None else json.dumps(data).encode(), method=method,
        headers={'apikey':key,'Authorization':'Bearer '+(token or key),
                 'Content-Type':'application/json','Prefer':'return=representation'})
    try:
        with opener.open(req,timeout=30) as response:
            raw=response.read()
            return response.status,json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        return error.code,json.loads(error.read())

def save(f):
    MANIFEST.write_text(json.dumps(f),'utf-8')

def rpc(name,token,**kwargs):
    return request('/rest/v1/rpc/'+name,kwargs,token)

def prepare():
    if MANIFEST.exists():
        f=json.loads(MANIFEST.read_text('utf-8'))
        if f.get('cleaned'): raise SystemExit('Fixture already cleaned')
    else:
        f={'run':uuid.uuid4().hex,'password':secrets.token_urlsafe(22),'users':[],'chats':[]}
    save(f)
    for i in range(3):
        login=f'e2e_{f["run"][:12]}_{i}'
        if i < len(f['users']):
            user=f['users'][i]
            code,auth=request('/auth/v1/admin/users/'+user['id'],admin=True)
            if code!=200 or auth.get('user_metadata',{}).get('test_run')!=f['run']:
                raise RuntimeError('Resume identity mismatch')
        else:
            code, user=request('/auth/v1/admin/users',{'email':login+'@student.local',
                'password':f['password'],'email_confirm':True,
                'user_metadata':{'test_run':f['run']}},admin=True)
            if code not in (200,201): raise RuntimeError(f'Create test Auth user failed HTTP {code}')
            f['users'].append({'id':user['id'],'login':login});save(f)
        payload={'login':login,'name':'E2E','surname':f'Synthetic {i}','role':'student','status':'','must_change_password':False}
        code,existing=request('/rest/v1/users?id=eq.'+user['id']+'&select=id',admin=True)
        if code!=200: raise RuntimeError('Cannot inspect synthetic profile')
        if existing:
            code,_=request('/rest/v1/users?id=eq.'+user['id'],payload,method='PATCH',admin=True)
        else:
            code,_=request('/rest/v1/users',dict(payload,id=user['id']),admin=True)
        if code not in (200,201): raise RuntimeError(f'Create test profile failed HTTP {code}')
    write_defines(f)
    print('Prepared three isolated live test accounts; manifest saved privately')

def write_defines(f):
    (WORK/'approved-live-defines.json').write_text(json.dumps({
        'SUPABASE_URL':BASE,'SUPABASE_ANON_KEY':env['SUPABASE_ANON_KEY'],
        'E2E_LOGIN':f['users'][0]['login'],'E2E_PEER_LOGIN':f['users'][1]['login'],
        'E2E_PASSWORD':f['password'],'E2E_LIVE_APPROVED':'true'}),'utf-8')

def run(f):
    results=[]
    def check(name,ok):
        results.append({'scenario':name,'passed':bool(ok)})
        print(('PASS ' if ok else 'FAIL ')+name)
        (WORK/'approved-live-results.json').write_text(json.dumps(results,indent=2),'utf-8')
    tokens=[]
    for user in f['users']:
        code,auth=request('/auth/v1/token?grant_type=password',{'email':user['login']+'@student.local','password':f['password']})
        if code!=200: raise RuntimeError(f'Test login failed HTTP {code}')
        tokens.append(auth['access_token'])
    a,b,c=[u['id'] for u in f['users']];ta,tb,tc=tokens
    check('three real Auth sessions',len(set(tokens))==3)
    for name in ['get_my_profile','get_my_teams','get_my_lessons','get_my_friends_bulk','get_my_classmates','unread_total']:
        code,_=rpc(name,ta);check('read '+name,code<300)
    rpc('remove_friend',ta,p_user_id=b)
    rpc('cancel_friend_request',ta,p_user_id=b)
    rpc('cancel_friend_request',tb,p_user_id=a)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        sent=list(pool.map(lambda _:rpc('send_friend_request',ta,p_user_id=b),range(2)))
    check('concurrent repeated friend request',all(code<300 for code,_ in sent))
    code,incoming=rpc('get_my_incoming_friend_requests',tb)
    check('single incoming request',code==200 and len(incoming)==1)
    code,body=rpc('accept_friend_request',tc,p_user_id=a)
    check('outsider cannot accept request',code==400 and body.get('message')=='friend_request_not_found')
    check('recipient accepts',rpc('accept_friend_request',tb,p_user_id=a)[0]<300)
    for token in [ta,tb]:
        code,rows=rpc('get_my_friends_bulk',token)
        check('friend visible to participant',code==200 and len(rows)==1)
    code,chat=rpc('ensure_dm_chat',ta,p_partner=b)
    if code!=200 or not isinstance(chat,str): raise RuntimeError(f'DM creation failed HTTP {code}')
    uuid.UUID(chat)
    if chat not in f['chats']: f['chats'].append(chat);save(f)
    code,same=rpc('ensure_dm_chat',ta,p_partner=b)
    check('DM creation idempotent',code==200 and same==chat)
    message_text='E2E '+f['run']
    code,mid=rpc('send_message_in_chat_with_files',ta,p_chat_id=chat,p_text=message_text,p_file_ids=[])
    check('send message through real RPC',code==200 and isinstance(mid,str))
    if code!=200:raise SystemExit(1)
    code,rows=rpc('get_chat_messages_page',tb,p_chat_id=chat)
    check('peer receives message exactly once',code==200 and sum(r['id']==mid for r in rows)==1)
    code,body=rpc('get_chat_messages_page',tc,p_chat_id=chat)
    check('outsider cannot read chat',code==400 and body.get('message')=='forbidden')
    code,body=rpc('send_message_in_chat_with_files',tc,p_chat_id=chat,p_text='forbidden',p_file_ids=[])
    check('outsider cannot send to chat',code==400 and body.get('message')=='forbidden')
    check('author edits message',rpc('edit_own_message',ta,p_message_id=mid,p_text=message_text+' edited')[0]<300)
    code,body=rpc('edit_own_message',tb,p_message_id=mid,p_text='forbidden')
    check('peer cannot edit author message',code==400 and body.get('message')=='not_author')
    code,_=rpc('toggle_message_reaction',tb,p_message_id=mid,p_emoji='👍')
    check('peer adds reaction',code<300)
    code,body=rpc('toggle_message_reaction',tc,p_message_id=mid,p_emoji='👍')
    check('outsider cannot react to hidden message',code==400 and body.get('code')=='P0001' and body.get('message')=='forbidden')
    check('mark chat read',rpc('mark_chat_read',tb,p_chat_id=chat)[0]<300)
    code,before=request('/rest/v1/users?id=eq.'+a+'&select=status',token=ta)
    if code!=200:raise RuntimeError('Cannot snapshot own test profile')
    original=before[0]['status']
    try:
        code,_=request('/rest/v1/users?id=eq.'+a,{'status':'E2E test'},ta,'PATCH')
        check('own profile status update',code<300)
        code,rows=rpc('get_user_profile',tb,p_id=a)
        check('status visible to another session',code==200 and rows[0]['status']=='E2E test')
        code,_=request('/rest/v1/users?id=eq.'+a,{'status':'forbidden'},tc,'PATCH')
        _,rows=rpc('get_user_profile',ta,p_id=a)
        check('outsider cannot change profile',rows[0]['status']=='E2E test')
    finally:
        request('/rest/v1/users?id=eq.'+a,{'status':original},ta,'PATCH')
    check('block peer',rpc('block_user',ta,p_user_id=b)[0]<300)
    code,body=rpc('send_message_in_chat_with_files',tb,p_chat_id=chat,p_text='blocked',p_file_ids=[])
    check('blocked DM denied',code==400 and body.get('message')=='dm_blocked')
    check('unblock peer',rpc('unblock_user',ta,p_user_id=b)[0]<300)
    check('remove friend',rpc('remove_friend',ta,p_user_id=b)[0]<300)
    print('Live checks:',sum(x['passed'] for x in results),'/',len(results))
    sys.exit(0 if all(x['passed'] for x in results) else 1)

def cleanup(f):
    # Only manifest IDs are touched; verify ownership marker before delete.
    for user in f['users']:
        if user.get('cleaned'): continue
        code,auth=request('/auth/v1/admin/users/'+user['id'],admin=True)
        if code!=200 or auth.get('user_metadata',{}).get('test_run')!=f['run']:
            raise RuntimeError('Cleanup identity check failed')
    for chat in f['chats']:
        if chat in f.get('cleaned_chats',[]): continue
        uuid.UUID(chat)
        code,members=request('/rest/v1/chat_members?chat_id=eq.'+chat+'&select=user_id',admin=True)
        if code!=200 or len(members)<2 or not set(m['user_id'] for m in members).issubset({u['id'] for u in f['users']}):
            raise RuntimeError('Unexpected chat participant; cleanup stopped')
        code,_=request('/rest/v1/chats?id=eq.'+chat,method='DELETE',admin=True)
        if code>=300:raise RuntimeError(f'Chat cleanup failed HTTP {code}')
        f.setdefault('cleaned_chats',[]).append(chat);save(f)
    for user in f['users']:
        if user.get('cleaned'): continue
        code,_=request('/auth/v1/admin/users/'+user['id'],method='DELETE',admin=True)
        if code>=300:raise RuntimeError(f'Auth cleanup failed HTTP {code}')
        user['cleaned']=True;save(f)
    f['cleaned']=True;save(f)
    print('Synthetic live fixture removed')

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['prepare','run','cleanup']);parser.add_argument('--approved',action='store_true');args=parser.parse_args()
    if not args.approved:raise SystemExit('Explicit owner-approved invocation required')
    if args.action=='prepare':prepare()
    else:
        f=json.loads(MANIFEST.read_text('utf-8'))
        if f.get('cleaned'):raise SystemExit('Fixture already cleaned')
        (run if args.action=='run' else cleanup)(f)
