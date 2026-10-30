"""Owner-approved synthetic action audit. Secrets/manifest stay outside Git."""
import argparse, json, uuid
import approved_live_regression as a

def checked(path, data=None, method=None):
    code, result=a.request(path,data,method=method,admin=True)
    if code>=300: raise RuntimeError((path,code,result))
    return result

def prepare():
    f=json.loads(a.MANIFEST.read_text()); assert not f.get('cleaned')
    x=f.setdefault('academic',{k:str(uuid.uuid4()) for k in ['group','team','chat','subject','offering','subject_team','subject_chat','teacher']})
    a.save(f)
    marker='E2E-'+f['run']; term='0b7e5ce5-826c-48bf-bc2b-6907073889f5'; year='b3d28bc9-6c27-4758-ab7b-35d292131d8f'
    def insert(table,row):
        existing=checked('/rest/v1/'+table+'?id=eq.'+row['id']+'&select=id')
        if not existing:checked('/rest/v1/'+table,row)
    insert('groups',{'id':x['group'],'name':marker})
    insert('subject_catalog',{'id':x['subject'],'canonical_name':marker,'normalized_name':marker.lower()})
    insert('teachers',{'id':x['teacher'],'full_name':marker,'normalized_name':marker.lower()})
    checked('/rest/v1/subject_catalog?id=eq.'+x['subject'],{'status':'published'},'PATCH')
    checked('/rest/v1/teachers?id=eq.'+x['teacher'],{'status':'published'},'PATCH')
    insert('subject_offerings',{'id':x['offering'],'subject_id':x['subject'],'group_id':x['group'],'academic_year_id':year,'academic_term_id':term,'semester_number':1,'display_name':marker})
    for user in f['users'][:2]:
        checked('/rest/v1/users?id=eq.'+user['id'],{'group_name':marker,'primary_group_id':x['group']},'PATCH')
        if not checked('/rest/v1/student_enrollments?user_id=eq.'+user['id']+'&select=id'):
            checked('/rest/v1/student_enrollments',{'user_id':user['id'],'group_id':x['group']})
    for key,kind in [('team','group_space'),('subject_team','subject')]:
        row={'id':x[key],'name':marker+' '+kind,'kind':kind,'group_id':x['group'],'group_name':marker,'owner_id':f['users'][0]['id']}
        if kind=='subject':row.update(subject_id=x['subject'],subject_offering_id=x['offering'],academic_term_id=term,academic_year_id=year,semester_number=1)
        insert('teams',row)
        for i,user in enumerate(f['users'][:2]):
            found=checked('/rest/v1/team_members?team_id=eq.'+row['id']+'&user_id=eq.'+user['id']+'&select=user_id')
            if not found:checked('/rest/v1/team_members',{'team_id':row['id'],'user_id':user['id'],'role':'owner' if i==0 else 'member'})
        chats=checked('/rest/v1/chats?team_id=eq.'+row['id']+'&type=eq.team_main&select=id')
        chat_key='chat' if key=='team' else 'subject_chat'
        if chats:x[chat_key]=chats[0]['id'];a.save(f)
        else:insert('chats',{'id':x[chat_key],'team_id':row['id'],'type':'team_main'})
    if len(f['users'])<4:
        login='e2e_'+f['run'][:12]+'_moderator'
        user=checked('/auth/v1/admin/users',{'email':login+'@student.local','password':f['password'],'email_confirm':True,'user_metadata':{'test_run':f['run']}})
        f['users'].append({'id':user['id'],'login':login});a.save(f)
        checked('/rest/v1/users?id=eq.'+user['id'],{'login':login,'name':'E2E','surname':'Moderator','role':'student','must_change_password':False},'PATCH')
    moderator=f['users'][3]['id']
    for role in ['moderator','content_editor']:
        if not checked('/rest/v1/admin_role_assignments?user_id=eq.'+moderator+'&role_code=eq.'+role+'&select=id'):
            checked('/rest/v1/admin_role_assignments',{'user_id':moderator,'role_code':role,'scope_type':'global'})
    defines=json.loads((a.WORK/'approved-live-defines.json').read_text())
    defines.update(E2E_OTHER_LOGIN=f['users'][2]['login'],E2E_MODERATOR_LOGIN=f['users'][3]['login'],E2E_MAIN_APPROVED='true',E2E_RUN=f['run'])
    defines.update({'E2E_'+k.upper():v for k,v in x.items()})
    (a.WORK/'approved-live-defines.json').write_text(json.dumps(defines),'utf-8')
    print('Prepared isolated action fixture and temporary moderator')


def cleanup():
    f=json.loads(a.MANIFEST.read_text());x=f['academic'];users={u['id'] for u in f['users']}
    if f.get('cleaned'): print('Already cleaned');return
    for u in f['users']:
        if u.get('cleaned'):continue
        auth=checked('/auth/v1/admin/users/'+u['id'])
        if auth.get('user_metadata',{}).get('test_run')!=f['run']:raise RuntimeError('Identity mismatch')
    if any(not item.get('object_deleted') for item in f.get('files',[])):raise RuntimeError('Storage cleanup required first')
    group=checked('/rest/v1/groups?id=eq.'+x['group']+'&select=name')
    if group and group[0]['name']!='E2E-'+f['run']:raise RuntimeError('Group mismatch')
    for key in ['team','subject_team']:
        team=checked('/rest/v1/teams?id=eq.'+x[key]+'&select=group_id,subject_id,subject_offering_id')
        if team and (team[0]['group_id']!=x['group'] or (key=='subject_team' and (team[0]['subject_id']!=x['subject'] or team[0]['subject_offering_id']!=x['offering']))):raise RuntimeError('Team mismatch')
        members=checked('/rest/v1/team_members?team_id=eq.'+x[key]+'&select=user_id')
        if not {m['user_id'] for m in members}.issubset(users):raise RuntimeError('Unexpected team member')
    offerings=checked('/rest/v1/subject_offerings?subject_id=eq.'+x['subject']+'&select=id,group_id')
    if any(o['id']!=x['offering'] or o['group_id']!=x['group'] for o in offerings):raise RuntimeError('Unexpected offering')
    # Discover only fixture-owned rows, then persist the exact list before writes.
    reviews=checked('/rest/v1/entity_reviews?entity_id=eq.'+x['subject']+'&select=id,author_user_id')
    if any(r['author_user_id'] not in users for r in reviews):raise RuntimeError('Unexpected review author')
    vacancies=checked('/rest/v1/vacancies?created_by=eq.'+f['users'][0]['id']+'&select=id,title')
    if any(not r['title'].startswith('E2E vacancy '+f['run']) for r in vacancies):raise RuntimeError('Unexpected vacancy')
    assignments=checked('/rest/v1/assignments?team_id=eq.'+x['subject_team']+'&select=id,author_id,title')
    if any(r['author_id'] not in users or not r['title'].startswith('E2E assignment') for r in assignments):raise RuntimeError('Unexpected assignment')
    for u in f['users']:
        for row in checked('/rest/v1/chat_members?user_id=eq.'+u['id']+'&select=chat_id'):
            chat=checked('/rest/v1/chats?id=eq.'+row['chat_id']+'&select=id,type')
            if chat and chat[0]['type']=='dm' and row['chat_id'] not in f['chats']:
                members=checked('/rest/v1/chat_members?chat_id=eq.'+row['chat_id']+'&select=user_id')
                if not {m['user_id'] for m in members}.issubset(users):raise RuntimeError('Unexpected DM member')
                f['chats'].append(row['chat_id'])
    for row in vacancies:
        if checked('/rest/v1/vacancy_assets?vacancy_id=eq.'+row['id']+'&select=id'):raise RuntimeError('Remove storage before vacancy cleanup')
    teacher=checked('/rest/v1/teachers?id=eq.'+x['teacher']+'&select=full_name')
    if teacher and teacher[0]['full_name']!='E2E-'+f['run']:raise RuntimeError('Teacher mismatch')
    if checked('/rest/v1/lessons?teacher_id=eq.'+x['teacher']+'&select=id'):raise RuntimeError('Teacher has lessons')
    if checked('/rest/v1/offering_teachers?teacher_id=eq.'+x['teacher']+'&select=teacher_id'):raise RuntimeError('Teacher has offerings')
    ledger=[]
    for review in reviews:
        rows=checked('/rest/v1/student_points_ledger?review_id=eq.'+review['id']+'&select=id,user_id,created_by')
        if any(r['user_id'] not in users or (r['created_by'] is not None and r['created_by'] not in users) for r in rows):raise RuntimeError('Unexpected review points owner')
        ledger.extend(rows)
    f['review_points_cleanup']=[r['id'] for r in ledger];a.save(f)
    f['action_cleanup']={'reviews':[r['id'] for r in reviews],'vacancies':[r['id'] for r in vacancies],'assignments':[r['id'] for r in assignments]};a.save(f)
    for row in ledger:checked('/rest/v1/student_points_ledger?id=eq.'+row['id'],method='DELETE')
    for table,rows in [('entity_reviews',reviews),('vacancies',vacancies),('assignments',assignments)]:
        for row in rows:
            if table=='vacancies' and checked('/rest/v1/vacancy_assets?vacancy_id=eq.'+row['id']+'&select=id'):raise RuntimeError('Remove storage before vacancy cleanup')
            checked('/rest/v1/'+table+'?id=eq.'+row['id'],method='DELETE')
            if checked('/rest/v1/'+table+'?id=eq.'+row['id']+'&select=id'):raise RuntimeError('Row survived cleanup')
    teacher=checked('/rest/v1/teachers?id=eq.'+x['teacher']+'&select=full_name')
    if teacher and teacher[0]['full_name']!='E2E-'+f['run']:raise RuntimeError('Teacher mismatch')
    if checked('/rest/v1/lessons?teacher_id=eq.'+x['teacher']+'&select=id'):raise RuntimeError('Teacher has lessons')
    if checked('/rest/v1/offering_teachers?teacher_id=eq.'+x['teacher']+'&select=teacher_id'):raise RuntimeError('Teacher has offerings')
    checked('/rest/v1/teacher_versions?teacher_id=eq.'+x['teacher'],method='DELETE')
    checked('/rest/v1/teachers?id=eq.'+x['teacher'],method='DELETE')
    for uid in users:checked('/rest/v1/admin_role_assignments?user_id=eq.'+uid,method='DELETE')
    checked('/rest/v1/group_space_organizer_grants?group_id=eq.'+x['group'],method='DELETE')
    a.cleanup(f)
    for u in f['users']:
        code,_=a.request('/auth/v1/admin/users/'+u['id'],admin=True)
        if code!=404:raise RuntimeError('Synthetic auth user still exists')
    print('Action fixtures and temporary roles removed and verified')

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['prepare','cleanup']);parser.add_argument('--approved',action='store_true');args=parser.parse_args()
    if not args.approved:raise SystemExit('Owner-approved fixture only')
    (prepare if args.action=='prepare' else cleanup)()

