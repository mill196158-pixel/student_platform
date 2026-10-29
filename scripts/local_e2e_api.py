"""Local-only real HTTP/API regression. Synthetic accounts; never production.

Missing historical RPCs are reported, never replaced by success stubs.
Local approximate baseline does not establish production RLS parity.
"""
import concurrent.futures
import json
from pathlib import Path
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request
from local_e2e_schema import sql

WORK = Path('C:/student_platform_e2e')
status = json.loads((WORK / 'status.json').read_text('utf-8-sig'))
BASE = status['API_URL']
if BASE != 'http://127.0.0.1:55321':
    raise SystemExit('Refusing non-isolated API URL')

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise RuntimeError('Redirect prohibited for isolated tests')

opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

def request(path, data=None, token=None, method=None, admin=False):
    url = BASE + path
    if urllib.parse.urlsplit(url).netloc != '127.0.0.1:55321':
        raise RuntimeError('Nonlocal URL')
    key = status['SERVICE_ROLE_KEY'] if admin else status['ANON_KEY']
    headers = {'apikey': key, 'Authorization': 'Bearer ' + (token or key),
               'Content-Type': 'application/json', 'Prefer': 'return=representation'}
    req = urllib.request.Request(url, headers=headers, method=method,
        data=None if data is None else json.dumps(data).encode())
    try:
        with opener.open(req, timeout=20) as response:
            body = response.read()
            return response.status, json.loads(body) if body else None
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read())

def rpc(name, token, **args):
    return request('/rest/v1/rpc/' + name, args, token)

def denied(response, message):
    code, body = response
    return code == 400 and isinstance(body, dict) and body.get('code') == 'P0001' and body.get('message') == message

def main():
    # Refuse reruns against populated fixture users rather than duplicate accounts.
    marker = WORK / 'fixture.json'
    if marker.exists():
        fixture = json.loads(marker.read_text('utf-8'))
    else:
        fixture = {'password': secrets.token_urlsafe(18), 'users': []}
        for login in ['99000001', '99000002', '99000003']:
            code, user = request('/auth/v1/admin/users', {
                'email': login + '@student.local', 'password': fixture['password'],
                'email_confirm': True}, admin=True)
            assert code in (200, 201), (code, user.get('msg'))
            uid = user['id']
            fixture['users'].append({'id': uid, 'login': login})
            sql(f"insert into public.users(id,login,name,surname) values ('{uid}','{login}','E2E','Synthetic');")
        marker.write_text(json.dumps(fixture), 'utf-8')
    users = fixture['users']
    tokens = []
    results = []
    def check(name, condition, detail=''):
        results.append({'scenario': name, 'passed': bool(condition), 'detail': detail})
        print(('PASS ' if condition else 'FAIL ') + name)
    for user in users:
        code, body = request('/auth/v1/token?grant_type=password', {
            'email': user['login']+'@student.local', 'password': fixture['password']})
        assert code == 200, 'Local login failed'
        tokens.append(body['access_token'])
    a, b, c = [u['id'] for u in users]
    ta, tb, tc = tokens
    check('three independent password logins', len(set(tokens)) == 3)
    bad, _ = request('/auth/v1/token?grant_type=password', {
        'email': users[0]['login']+'@student.local', 'password': 'incorrect-test-password'})
    check('incorrect password rejected', bad == 400)

    # Only this isolated fixture's friend records are reset.
    sql(f"delete from public.friend_requests where from_id in ('{a}','{b}','{c}');"
        f"delete from public.friends where user_id in ('{a}','{b}','{c}') or friend_id in ('{a}','{b}','{c}');")
    check('self friend request rejected', denied(rpc('send_friend_request',ta,p_user_id=a), 'friendship_self_not_allowed'))
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(pool.map(lambda _: rpc('send_friend_request',ta,p_user_id=b), range(2)))
    check('duplicate concurrent request accepted safely', all(r[0] < 300 for r in responses))
    code, incoming = rpc('get_my_incoming_friend_requests',tb)
    check('incoming request exactly once', code == 200 and isinstance(incoming,list) and len(incoming)==1,
          'RPC name/signature must match checked-in client')
    check('outsider cannot accept another users request', denied(rpc('accept_friend_request',tc,p_user_id=a), 'friend_request_not_found'))
    check('recipient accepts request', rpc('accept_friend_request',tb,p_user_id=a)[0] < 300)
    for token in [ta,tb]:
        code, friends = rpc('get_my_friends_bulk',token)
        check('friend visible from both sessions', code == 200 and len(friends)==1)
    check('remove friendship', rpc('remove_friend',ta,p_user_id=b)[0] < 300)
    code, friends = rpc('get_my_friends_bulk',tb)
    check('friend removed for peer', code == 200 and len(friends)==0)
    rpc('send_friend_request',ta,p_user_id=b)
    check('cancel outgoing request', rpc('cancel_friend_request',ta,p_user_id=b)[0] < 300)
    rpc('send_friend_request',ta,p_user_id=b)
    check('decline incoming request', rpc('decline_friend_request',tb,p_user_id=a)[0] < 300)
    check('block user', rpc('block_user',ta,p_user_id=b)[0] < 300)
    check('unblock user', rpc('unblock_user',ta,p_user_id=b)[0] < 300)
    code, profile = rpc('get_user_profile',ta,p_id=a)
    check('profile RPC returns own synthetic profile', code == 200 and len(profile)==1 and profile[0]['id']==a)
    check('presence heartbeat', rpc('touch_my_presence',ta)[0] < 300)
    chat='e2e00000-0000-4000-8000-000000000001'
    message='e2e00000-0000-4000-8000-000000000002'
    sql(f"insert into public.chats(id,type) values ('{chat}','dm') on conflict do nothing;"
        f"insert into public.chat_members(chat_id,user_id) values ('{chat}','{a}'),('{chat}','{b}') on conflict do nothing;"
        f"insert into public.messages(id,chat_id,author_id,body,content) values ('{message}','{chat}','{a}','fixture','fixture') on conflict do nothing;")
    code, page = rpc('get_chat_messages_page',tb,p_chat_id=chat)
    check('peer reads seeded chat message', code == 200 and any(row['id']==message for row in page))
    check('outsider denied chat history', denied(rpc('get_chat_messages_page',tc,p_chat_id=chat), 'forbidden'))
    # Signature is verified against checked-in SQL; no substitute send implementation.
    code, body = rpc('edit_own_message',ta,p_message_id=message,p_text='E2E edited')
    check('author edits message', code < 300, str(body)[:150] if code>=400 else '')
    check('peer cannot edit authors message', denied(rpc('edit_own_message',tb,p_message_id=message,p_text='forbidden'), 'not_author'))
    code, page = rpc('get_chat_messages_page',tb,p_chat_id=chat)
    check('edited message persists for peer', code == 200 and any(row['id']==message and row['text']=='E2E edited' for row in page))
    schema_code, schema = request('/rest/v1/')
    paths = schema.get('paths',{}) if isinstance(schema,dict) else {}
    for name in ['send_chat_message','get_my_profile','get_my_teams']:
        check('required contract exists: '+name, '/rpc/'+name in paths,
              'Missing original definition cannot be replaced with a passing test stub')
    (WORK / 'api-results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2),'utf-8')
    # Local fixture secret is never stored in the repository or printed.
    (WORK / 'flutter-defines.json').write_text(json.dumps({
        'SUPABASE_URL':'http://10.0.2.2:55321', 'SUPABASE_ANON_KEY':status['ANON_KEY'],
        'E2E_LOGIN':users[0]['login'], 'E2E_PASSWORD':fixture['password']}),'utf-8')
    print('Result:',sum(r['passed'] for r in results),'/',len(results))
    sys.exit(0 if all(r['passed'] for r in results) else 1)

if __name__=='__main__':
    main()
