"""Synthetic fixture only. Owner-approved real file access regression."""
import json, urllib.request
import approved_live_regression as a

def run():
 f=json.loads(a.MANIFEST.read_text()); tokens=[]
 for u in f['users']:
  code,v=a.request('/auth/v1/token?grant_type=password',{'email':u['login']+'@student.local','password':f['password']}); assert code==200
  tokens.append(v['access_token'])
 body=b'E2E private attachment fixture'
 code,v=a.request('/functions/v1/generate-upload-url',{'chatId':f['chats'][0],'fileName':'private-fixture.txt','contentType':'text/plain','fileSize':len(body)},tokens[0]); assert code==200,(code,v)
 item={'key':v['fileKey'],'url':v['fileUrl'],'chat':f['chats'][0],'object_deleted':False}; f.setdefault('files',[]).append(item); a.save(f)
 req=urllib.request.Request(v['uploadUrl'],data=body,method='PUT',headers=v['headers'])
 with a.opener.open(req,timeout=30) as r: assert r.status==200
 print('PASS upload')
 code,r=a.request('/functions/v1/chat-file-access',{'action':'confirm','key':item['key']},tokens[0]); assert code==200,(code,r)
 print('PASS HEAD confirmation')
 params={'p_chat_id':item['chat'],'p_file_name':'forged-name','p_file_key':item['key'],'p_file_url':'https://invalid.example','p_file_type':'fake/type','p_file_size':999}
 code,fid=a.rpc('save_chat_file',tokens[0],**params); assert code==200,(code,fid); item['id']=fid; a.save(f)
 code,same=a.rpc('save_chat_file',tokens[0],**params,p_uploaded_by=f['users'][0]['id'],p_message_id=None); assert same==fid
 print('PASS six/eight argument REST registration and idempotency')
 code,mid=a.rpc('send_message_in_chat_with_files',tokens[0],p_chat_id=item['chat'],p_text='E2E private attachment',p_file_ids=[fid]); assert code==200,(code,mid)
 print('PASS attachment send')
 for label,token in zip(['owner','peer','outsider'],tokens):
  code,r=a.request('/functions/v1/chat-file-access',{'action':'resolve','key':item['key']},token)
  if label!='outsider':
   assert code==200,(code,r)
   with a.opener.open(r['url'],timeout=30) as response: assert response.read()==body
  else: assert code==403
  print('PASS '+label+' access')
 defines=json.loads((a.WORK/'approved-live-defines.json').read_text());defines['E2E_FILE_URL']=item['url'];defines['E2E_FILE_ID']=fid
 (a.WORK/'approved-live-defines.json').write_text(json.dumps(defines),'utf-8')
if __name__=='__main__': run()
