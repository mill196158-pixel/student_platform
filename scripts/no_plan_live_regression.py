"""Explicitly approved live no-plan regression. Isolated fixture, no real users."""
import json, secrets, uuid, concurrent.futures, sys
from pathlib import Path
from approved_live_regression import request, rpc, WORK
MANIFEST=WORK/'no-plan-fixture.json'
def save(f): MANIFEST.write_text(json.dumps(f),'utf-8')
def ok(response):
    code,body=response
    if code>=300: raise RuntimeError(f'HTTP {code}: {body}')
    return body

def prepare():
    assert not MANIFEST.exists(), 'Existing fixture must be inspected first'
    f={'run':uuid.uuid4().hex,'password':secrets.token_urlsafe(24),'users':[], 'group_id':str(uuid.uuid4())}
    save(f)
    for i in range(3):
        login=f'np_{f["run"][:12]}_{i}'
        user=ok(request('/auth/v1/admin/users',{'email':login+'@student.local','password':f['password'],'email_confirm':True,'user_metadata':{'test_run':f['run']}},admin=True))
        f['users'].append({'id':user['id'],'login':login});save(f)
        payload={'login':login,'name':'Synthetic','surname':'NoPlan','role':'student','status':'','must_change_password':False}
        existing=ok(request('/rest/v1/users?id=eq.'+user['id']+'&select=id',admin=True))
        ok(request('/rest/v1/users'+('?id=eq.'+user['id'] if existing else ''),payload if existing else dict(payload,id=user['id']),method='PATCH' if existing else 'POST',admin=True))
    for n in range(77,100):
        name=f'{n}-СДПГС-25'
        from urllib.parse import quote
        if not ok(request('/rest/v1/groups?name=eq.'+quote(name)+'&select=id',admin=True)): break
    f['group_name']=name;save(f)
    ok(request('/rest/v1/groups',{'id':f['group_id'],'name':name},admin=True))
    ok(request('/rest/v1/group_academic_profiles',{'group_id':f['group_id'],'admission_year':2025,'nominal_semesters':8},admin=True))
    ok(request('/rest/v1/student_enrollments',{'group_id':f['group_id'],'user_id':f['users'][0]['id'],'started_at':'2025-09-01'},admin=True))
    ok(request('/rest/v1/users?id=eq.'+f['users'][0]['id'],{'primary_group_id':f['group_id'],'group_name':name},method='PATCH',admin=True))
    ok(request('/rest/v1/admin_role_assignments',{'user_id':f['users'][2]['id'],'role_code':'academic_editor','scope_type':'global'},admin=True))
    print('Prepared isolated group and three synthetic Auth accounts')

def run(f):
    tokens=[ok(request('/auth/v1/token?grant_type=password',{'email':u['login']+'@student.local','password':f['password']}))['access_token'] for u in f['users']]
    student, outsider, admin=tokens; results=[]
    def check(name, condition):
        results.append({'scenario':name,'passed':bool(condition)})
        (WORK/'no-plan-results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2),'utf-8')
        print(('PASS ' if condition else 'FAIL ')+name,flush=True)
        assert condition,name
    def payload(names, date='2026-03-02'):
        return {'groups':[{'group_id':f['group_id'],'group_name':f['group_name'],'status':'applied','lessons':[{'date':date,'week':1,'day':'Понедельник','pair_num':i+1,'time_start':'10:00','time_end':'11:30','subject':s,'group_name':f['group_name']} for i,s in enumerate(names)]}]}
    raw='Квантовая гидромеханика '+f['run'][:8]
    p=payload([raw+' (л.)',raw+' (пр.)'])
    check('student cannot import',rpc('admin_save_rasp_schedule_run',student,p_payload=p)[0]>=400)
    check('anon cannot import',request('/rest/v1/rpc/admin_save_rasp_schedule_run',{'p_payload':p})[0]>=400)
    def imp(data):
        body=ok(rpc('admin_save_rasp_schedule_run',admin,p_payload=data))
        (WORK/'no-plan-last-import.json').write_text(json.dumps(body,ensure_ascii=False,indent=2),'utf-8')
        return body
    imp(p)
    def offerings():return ok(request('/rest/v1/subject_offerings?group_id=eq.'+f['group_id']+'&select=id,subject_id,semester_number',admin=True))
    rows=offerings();check('full importer creates one offering for lecture and practice',len(rows)==1)
    f['subject_id']=rows[0]['subject_id'];f['offering_id']=rows[0]['id'];save(f)
    def mine():return ok(rpc('rpc_get_my_subjects_v2',student))
    sub=mine();check('student sees one subject and available chat without curriculum',len(sub)==1 and sub[0]['can_open_chat'] and sub[0]['semester_number']==2)
    f['team_id']=sub[0]['team_id'];f['chat_id']=sub[0]['chat_id'];save(f)
    check('student team list includes created team',any(x['id']==f['team_id'] for x in ok(rpc('get_my_teams',student))))
    check('outsider sees no group subjects',len(ok(rpc('rpc_get_my_subjects_v2',outsider)))==0)
    check('outsider cannot read chat',rpc('get_chat_messages_page',outsider,p_chat_id=f['chat_id'])[0]>=400)
    check('member can open chat',rpc('get_chat_messages_page',student,p_chat_id=f['chat_id'])[0]==200)
    imp(p)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:list(pool.map(lambda _:imp(p),range(2)))
    check('repeat and concurrent full imports retain offering and team IDs',offerings()==rows and mine()[0]['team_id']==f['team_id'])
    check('two lessons remain after concurrent imports',len(ok(request('/rest/v1/lessons?group_id=eq.'+f['group_id']+'&date=eq.2026-03-02&select=id',admin=True)))==2)
    typo=raw.replace('гидромеханика','гидромеханка')
    imp(payload([typo], '2026-03-03'))
    check('near typo held for review without duplicate offering',len(offerings())==1 and len(ok(rpc('admin_list_unlinked_schedule_subjects',admin)))>0)
    # An unrelated valid name in the same interval must not be provisioned by binding this typo.
    other='История керамики '+f['run'][:8]
    ok(request('/rest/v1/lessons',{'group_id':f['group_id'],'date':'2026-03-03','week':1,'day':'Вторник','pair_num':9,'time_start':'20:00','time_end':'21:00','subject':other,'raw_subject_name':other},admin=True))
    check('student cannot bind',rpc('admin_bind_schedule_subject',student,p_group_id=f['group_id'],p_raw_subject=typo,p_subject_id=f['subject_id'])[0]>=400)
    ok(rpc('admin_bind_schedule_subject',admin,p_group_id=f['group_id'],p_raw_subject=typo,p_subject_id=f['subject_id']))
    check('manual bind resolves typo and does not touch unrelated subject',len(offerings())==1 and len(ok(request('/rest/v1/lessons?group_id=eq.'+f['group_id']+'&subject_offering_id=is.null&select=id',admin=True)))==1)
    imp(payload([typo], '2026-03-04'))
    check('saved alias works on later import',len(offerings())==1 and len(mine())==1)
    check('NULL dry-run rejected',rpc('admin_sync_schedule_subjects',admin,p_group_id=f['group_id'],p_from='2026-03-02',p_to='2026-03-04',p_dry_run=None)[0]>=400)
    print('Live checks finished; fixture awaits cleanup',flush=True)

def boundaries(f):
    u=f['users'][2]
    token=ok(request('/auth/v1/token?grant_type=password',{'email':u['login']+'@student.local','password':f['password']}))['access_token']
    results=json.loads((WORK/'no-plan-results.json').read_text('utf-8'))
    for day,semester in [('2026-08-31',None),('2026-09-01',3),('2027-01-31',3),('2027-02-01',4)]:
        p={'groups':[{'group_id':f['group_id'],'group_name':f['group_name'],'status':'applied','lessons':[{'date':day,'week':1,'day':'Тест','pair_num':1,'time_start':'10:00','time_end':'11:30','subject':'Квантовая гидромеханика '+f['run'][:8],'group_name':f['group_name']}]}]}
        body=ok(rpc('admin_save_rasp_schedule_run',token,p_payload=p))
        rows=ok(request('/rest/v1/lessons?group_id=eq.'+f['group_id']+'&date=eq.'+day+'&select=semester_number,subject_offering_id',admin=True))
        assert len(rows)==1 and rows[0]['semester_number']==semester, (day,rows,body)
        passed={'scenario':'calendar boundary '+day+' semester '+str(semester),'passed':True};results.append(passed);print('PASS '+passed['scenario'])
    (WORK/'no-plan-results.json').write_text(json.dumps(results,ensure_ascii=False,indent=2),'utf-8')

def cleanup(f):
    if f.get('cleaned'):return
    allowed={u['id'] for u in f['users']}
    for u in f['users']:
        if u.get('cleaned'):continue
        auth=ok(request('/auth/v1/admin/users/'+u['id'],admin=True))
        assert auth.get('user_metadata',{}).get('test_run')==f['run'],'Auth fixture marker mismatch'
    groups=ok(request('/rest/v1/groups?id=eq.'+f['group_id']+'&select=name',admin=True))
    assert not groups or groups[0]['name']==f['group_name']
    teams=ok(request('/rest/v1/teams?group_id=eq.'+f['group_id']+'&select=id',admin=True))
    for team in teams:
        members=ok(request('/rest/v1/team_members?team_id=eq.'+team['id']+'&select=user_id',admin=True))
        assert {m['user_id'] for m in members}.issubset(allowed),'Unexpected member'
    offerings=ok(request('/rest/v1/subject_offerings?group_id=eq.'+f['group_id']+'&select=id,subject_id',admin=True))
    subjects=set(o['subject_id'] for o in offerings)|set(f.get('cleanup_subjects',[]))
    for sid in subjects:
        rows=ok(request('/rest/v1/subject_catalog?id=eq.'+sid+'&select=canonical_name',admin=True))
        assert not rows or f['run'][:8] in rows[0]['canonical_name'],'Nonfixture subject'
        uses=ok(request('/rest/v1/subject_offerings?subject_id=eq.'+sid+'&select=group_id',admin=True))
        assert all(o['group_id']==f['group_id'] for o in uses),'Shared subject'
    f['cleanup_subjects']=list(subjects);save(f)
    runs=ok(request('/rest/v1/rasp_schedule_runs?created_by=eq.'+f['users'][2]['id']+'&select=id',admin=True))
    for r in runs:ok(request('/rest/v1/rasp_schedule_runs?id=eq.'+r['id'],method='DELETE',admin=True))
    for table in ['lessons','teams','subject_offerings','student_enrollments','group_term_semesters','group_academic_profiles']:
        ok(request('/rest/v1/'+table+'?group_id=eq.'+f['group_id'],method='DELETE',admin=True))
    for sid in subjects:ok(request('/rest/v1/subject_catalog?id=eq.'+sid,method='DELETE',admin=True))
    for u in f['users']:
        if u.get('cleaned'):continue
        ok(request('/rest/v1/users?id=eq.'+u['id'],{'primary_group_id':None,'group_name':None},method='PATCH',admin=True))
    ok(request('/rest/v1/groups?id=eq.'+f['group_id'],method='DELETE',admin=True))
    for u in f['users']:
        if u.get('cleaned'):continue
        ok(request('/auth/v1/admin/users/'+u['id'],method='DELETE',admin=True));u['cleaned']=True;save(f)
    assert not ok(request('/rest/v1/lessons?group_id=eq.'+f['group_id']+'&select=id',admin=True))
    assert not ok(request('/rest/v1/teams?group_id=eq.'+f['group_id']+'&select=id',admin=True))
    f['cleaned']=True;f.pop('password',None);save(f)
    print('Synthetic group, subjects, offerings, teams, runs and Auth users removed')

if __name__=='__main__':
    assert '--approved' in sys.argv
    if sys.argv[1]=='prepare':prepare()
    elif sys.argv[1]=='run':run(json.loads(MANIFEST.read_text('utf-8')))

    elif sys.argv[1]=='boundaries':boundaries(json.loads(MANIFEST.read_text('utf-8')))

    elif sys.argv[1]=='cleanup':cleanup(json.loads(MANIFEST.read_text('utf-8')))
