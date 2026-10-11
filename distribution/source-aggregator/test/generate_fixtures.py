import base64,io,json,plistlib,struct,zipfile,zlib
from pathlib import Path
root=Path(__file__).parent
info={'CFBundleDisplayName':'验证 & Range','CFBundleName':'RangeFixture','CFBundleIdentifier':'com.example.range','CFBundleShortVersionString':'1.2.3','CFBundleVersion':'42','MinimumOSVersion':'15.0','Extras':{'flag':True,'empty':'','negative':-1,'array':['值',3,False],'data':b'abc'}}
expected={'name':info['CFBundleDisplayName'],'bundleIdentifier':info['CFBundleIdentifier'],'version':'1.2.3','buildVersion':'42','minOSVersion':'15.0'}
class Streaming(io.BytesIO):
 def seekable(self):return False
 def seek(self,*args):raise io.UnsupportedOperation('not seekable')
def png(cgbi=False):
 def chunk(tag,data):return struct.pack('>I',len(data))+tag+data+struct.pack('>I',zlib.crc32(tag+data))
 pixels=(b'\0'+(b'\x00\x00\xff\xff' if cgbi else b'\xff\x00\x00\xff')*4)*4
 compressed=zlib.compress(pixels)
 if cgbi:compressed=compressed[2:-4]
 return b'\x89PNG\r\n\x1a\n'+(chunk(b'CgBI',b'\x40\xa0\x60\x82') if cgbi else b'')+chunk(b'IHDR',struct.pack('>IIBBBBB',4,4,8,6,0,0,0))+chunk(b'IDAT',compressed)+chunk(b'IEND',b'')
def car(chunked=True,cycle=False):
 blocks=[b''];variables={}
 def addblock(data):blocks.append(data);return len(blocks)-1
 def tree(name,entries):
  pairs=[(addblock(value),addblock(key)) for key,value in entries]
  leaf=addblock(struct.pack('>HHII',1,len(pairs),0,0)+b''.join(struct.pack('>II',v,k) for v,k in pairs))
  if cycle:blocks[leaf]=struct.pack('>HHII',1,len(pairs),leaf,0)+blocks[leaf][12:]
  variables[name]=addblock(b'tree'+struct.pack('>IIIIB',1,leaf,4096,len(pairs),0))
 variables['CARHEADER']=addblock(b'RATC'+b'\0'*432)
 variables['KEYFORMAT']=addblock(b'tmfk'+struct.pack('<IIII',1,2,17,15))
 tree('FACETKEYS',[(b'AppIcon\0',struct.pack('<HHHHH',0,0,1,17,600)),(b'Other\0',struct.pack('<HHHHH',0,0,1,17,800))])
 def rendition(size,color):
  csi=bytearray(180);csi[:4]=b'ISTC';struct.pack_into('<IIII',csi,4,1,8,size,size);csi[24:28]=b'BGRA';csi[40:53]=b'arbitrary.png'
  pixels=bytes(color)*size*size
  if chunked:
   payload=b''
   for start in range(0,size,2):
    raw=pixels[start*size*4:(start+2)*size*4];encoded=b'bvx-'+struct.pack('<I',len(raw))+raw+b'bvx$'
    payload+=b'KCBC'+struct.pack('<IIII',0,0,2,len(encoded))+encoded
  else:payload=pixels
  return bytes(csi)+b'MLEC'+struct.pack('<III',3,4 if chunked else 0,len(payload))+payload
 tree('RENDITIONS',[(struct.pack('<HH',600,1),rendition(4,[0,0,255,255])),(struct.pack('<HH',800,1),rendition(8,[255,0,0,255]))])
 body=b'';offsets=[]
 for block in blocks:offsets.append((32+len(body),len(block)));body+=block
 index=struct.pack('>I',len(blocks))+b''.join(struct.pack('>II',*pair) for pair in offsets)
 var=struct.pack('>I',len(variables))+b''.join(struct.pack('>IB',bid,len(name))+name.encode() for name,bid in variables.items())
 return b'BOMStore'+struct.pack('>IIIIII',1,len(blocks),32+len(body),len(index),32+len(body)+len(index),len(var))+body+index+var
def make(fmt=plistlib.FMT_BINARY,compress=zipfile.ZIP_DEFLATED,comment=b'',large=False,descriptor=False,multiple=False,missing=False,icon=None):
 b=Streaming() if descriptor else io.BytesIO()
 plist=dict(info)
 if icon:
  primary={'CFBundleIconName':'AppIcon'} if icon.startswith('car') else {'CFBundleIconFiles':['PrimaryIcon']}
  plist['CFBundleIcons']={'CFBundlePrimaryIcon':primary,'CFBundleAlternateIcons':{'Other':{'CFBundleIconFiles':['WrongIcon']}}}
 with zipfile.ZipFile(b,'w',compression=compress) as z:
  if not missing:z.writestr('Payload/Fixture.app/Info.plist',plistlib.dumps(plist,fmt=fmt))
  if icon:
   z.writestr('Payload/Fixture.app/WrongIcon.png',png())
   if icon.startswith('car'):z.writestr('Payload/Fixture.app/Assets.car',car(chunked=icon!='car-stored',cycle=icon=='car-cycle'))
   elif icon!='missing':z.writestr('Payload/Fixture.app/PrimaryIcon@3x.png',b'broken' if icon=='broken' else png(cgbi=icon=='cgbi'))
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
add('icon-png',make(icon='png'))
add('icon-png-xml',make(fmt=plistlib.FMT_XML,icon='png'))
add('icon-cgbi',make(icon='cgbi'))
add('icon-car-stored',make(icon='car-stored'))
add('icon-car-lzfse',make(icon='car-lzfse'))
add('icon-car-cycle',make(icon='car-cycle'),'ICON_EXTRACTION_FAILED')
add('icon-broken',make(icon='broken'),'ICON_EXTRACTION_FAILED')
add('icon-missing',make(icon='missing'),'ICON_EXTRACTION_FAILED')
(root/'fixtures.mjs').write_text('export default '+json.dumps(fixtures,ensure_ascii=False)+';\n')
print('Generated',len(fixtures),'ZIP/plist/protocol fixtures.')
