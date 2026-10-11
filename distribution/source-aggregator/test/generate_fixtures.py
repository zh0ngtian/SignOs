import base64,io,json,plistlib,struct,zipfile
from pathlib import Path
root=Path(__file__).parent
info={'CFBundleDisplayName':'验证 & Range','CFBundleName':'RangeFixture','CFBundleIdentifier':'com.example.range','CFBundleShortVersionString':'1.2.3','CFBundleVersion':'42','MinimumOSVersion':'15.0','Extras':{'flag':True,'empty':'','negative':-1,'array':['值',3,False],'data':b'abc'}}
expected={'name':info['CFBundleDisplayName'],'bundleIdentifier':info['CFBundleIdentifier'],'version':'1.2.3','buildVersion':'42','minOSVersion':'15.0'}
class Streaming(io.BytesIO):
 def seekable(self):return False
 def seek(self,*args):raise io.UnsupportedOperation('not seekable')
def make(fmt=plistlib.FMT_BINARY,compress=zipfile.ZIP_DEFLATED,comment=b'',large=False,descriptor=False,multiple=False,missing=False):
 b=Streaming() if descriptor else io.BytesIO()
 with zipfile.ZipFile(b,'w',compression=compress) as z:
  if not missing:z.writestr('Payload/Fixture.app/Info.plist',plistlib.dumps(info,fmt=fmt))
  z.writestr('Payload/Fixture.app/PlugIns/Extension.appex/Info.plist',plistlib.dumps({'CFBundleIdentifier':'com.example.extension'}))
  if multiple:z.writestr('Payload/Other.app/Info.plist',plistlib.dumps(info,fmt=fmt))
  if large:
   for i in range(1600):z.writestr(f'Payload/Fixture.app/Resources/empty-{i:05d}.txt',b'')
  z.comment=comment
 return b.getvalue()
def aszip64(blob):
 e=blob.rfind(b'PK\x05\x06');count,cdsize,cdoff=struct.unpack_from('<HII',blob,e+10)
 cd=bytearray(blob[cdoff:e]);nameLen,extraLen=struct.unpack_from('<HH',cd,28)
 uncomp,comp,off=struct.unpack_from('<I',cd,24)[0],struct.unpack_from('<I',cd,20)[0],struct.unpack_from('<I',cd,42)[0]
 extra=struct.pack('<HHQQQ',1,24,uncomp,comp,off)
 struct.pack_into('<I',cd,20,0xffffffff);struct.pack_into('<I',cd,24,0xffffffff);struct.pack_into('<I',cd,42,0xffffffff);struct.pack_into('<H',cd,30,extraLen+len(extra))
 at=46+nameLen+extraLen;cd[at:at]=extra
 zoff=cdoff+len(cd)
 record=struct.pack('<IQHHIIQQQQ',0x06064b50,44,45,45,0,0,count,count,len(cd),cdoff)
 loc=struct.pack('<IIQI',0x07064b50,0,zoff,1)
 tail=bytearray(blob[e:]);struct.pack_into('<HHII',tail,8,65535,65535,0xffffffff,0xffffffff)
 return blob[:cdoff]+cd+record+loc+tail
fixtures=[]
def add(name,blob,error=None,behavior=None):fixtures.append({'id':name,'base64':base64.b64encode(blob).decode(),'expected':expected if error is None else None,'error':error,'behavior':behavior})
add('binary-deflate',make())
add('xml-deflate',make(fmt=plistlib.FMT_XML))
add('binary-stored',make(compress=zipfile.ZIP_STORED))
add('max-zip-comment',make(comment=b'x'*65535))
add('central-directory-outside-tail',make(large=True))
add('zip64',aszip64(make()))
add('data-descriptor',make(descriptor=True))
add('multiple-main-apps',make(multiple=True),'MULTIPLE_MAIN_APPS')
add('missing-main-app',make(missing=True),'MAIN_PLIST_NOT_FOUND')
bad=bytearray(make());central=bad.find(b'PK\x01\x02');struct.pack_into('<I',bad,central+16,0);add('bad-crc',bytes(bad),'CRC_MISMATCH')
add('range-ignored',make(),'RANGE_UNSUPPORTED','ignore')
add('file-changed',make(),'OBJECT_CHANGED','changed')
add('truncated-range',make(),'TRUNCATED_RANGE','truncated')
add('wrong-range',make(),'BAD_CONTENT_RANGE','wrong')
add('unsupported-compression',make(compress=zipfile.ZIP_BZIP2),'COMPRESSION_UNSUPPORTED')
(root/'fixtures.mjs').write_text('export default '+json.dumps(fixtures,ensure_ascii=False)+';\n')
print('Generated',len(fixtures),'ZIP/plist/protocol fixtures.')
