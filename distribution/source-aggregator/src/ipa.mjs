import { inflateRawSync } from 'node:zlib';
import { crc32 } from './crc.mjs';
import { normalizeIconPNG } from './png.mjs';
import { extractCARIcon } from './car.mjs';
export { crc32 } from './crc.mjs';
import { publicURL } from './urls.mjs';
import { SourceError } from './errors.mjs';
export class ParseError extends Error { constructor(code, detail) { super(detail || code); this.code = code; } }
const fail = (code, detail) => { throw new ParseError(code, detail); };
const view = a => new DataView(a.buffer, a.byteOffset, a.byteLength);
const text = a => new TextDecoder('utf-8', {fatal:true}).decode(a);
const safe = n => { if (!Number.isSafeInteger(n) || n < 0) fail('UNSAFE_OFFSET'); return n; };
// Read root keys and only the scalar fields we publish. Unrelated nested values
// must not consume parser CPU or fail metadata extraction.
function binaryPlist(a) {
 const end=a.length-32;
 if(end<8)fail('BAD_BINARY_PLIST');
 const uint=(p,n)=>{if(n<1||n>8||p<0||p+n>a.length)fail('BAD_BINARY_PLIST');let x=0;for(let i=0;i<n;i++)x=x*256+a[p+i];return safe(x);};
 const os=a[end+6],rs=a[end+7],count=uint(end+8,8),top=uint(end+16,8),table=uint(end+24,8);
 if(!count||count>100000||top>=count||![1,2,4,8].includes(os)||![1,2,4,8].includes(rs)||table<8||table+count*os>end)fail('BAD_BINARY_PLIST');
 const offset=id=>{if(id>=count)fail('BAD_BINARY_PLIST');const p=uint(table+id*os,os);if(p<8||p>=table)fail('BAD_BINARY_PLIST');return p;};
 const length=p=>{let n=a[p]&15,data=p+1;if(n===15){if(data>=table||(a[data]>>4)!==1||(a[data]&15)>3)fail('BAD_BINARY_PLIST');const size=2**(a[data]&15);if(data+1+size>table)fail('BAD_BINARY_PLIST');n=uint(data+1,size);data+=1+size;}return {n,data};};
 const scalar=id=>{const p=offset(id),kind=a[p]>>4;
  if(kind===5||kind===6){const {n,data}=length(p),bytes=n*(kind===6?2:1);if(data+bytes>table)fail('BAD_BINARY_PLIST');return new TextDecoder(kind===6?'utf-16be':'utf-8',{fatal:true}).decode(a.subarray(data,data+bytes));}
  if(kind===1){const n=2**(a[p]&15);if(n>8||p+1+n>table)fail('BAD_BINARY_PLIST');return uint(p+1,n);}
  fail('UNSUPPORTED_PLIST_OBJECT');
 };
 const p=offset(top);if(a[p]>>4!==13)fail('BAD_BINARY_PLIST');const {n,data}=length(p);
 if(n>10000||data+2*n*rs>table)fail('BAD_BINARY_PLIST');
 const iconKeys=new Set(['CFBundleIcons','CFBundleIcons~ipad','CFBundleIconFiles','CFBundleIconFile']);
 const nested=(id,ancestors=new Set())=>{
  if(ancestors.size>=8||ancestors.has(id))fail('BAD_BINARY_PLIST');
  const chain=new Set(ancestors);chain.add(id);const p=offset(id),kind=a[p]>>4;
  if(kind===5||kind===6)return scalar(id);
  if(kind!==10&&kind!==13)return null;
  const {n,data}=length(p);if(n>128||data+n*rs*(kind===13?2:1)>table)fail('BAD_BINARY_PLIST');
  if(kind===10)return Array.from({length:n},(_,i)=>nested(uint(data+i*rs,rs),chain));
  const out=Object.create(null);for(let i=0;i<n;i++){const key=scalar(uint(data+i*rs,rs));if(typeof key!=='string'||Object.hasOwn(out,key))fail('BAD_BINARY_PLIST');if(['CFBundlePrimaryIcon','CFBundleIconName','CFBundleIconFiles'].includes(key))out[key]=nested(uint(data+(n+i)*rs,rs),chain);}return out;
 };
 const wanted=new Set(['CFBundleDisplayName','CFBundleName','CFBundleIdentifier','CFBundleShortVersionString','CFBundleVersion','MinimumOSVersion',...iconKeys]),out=Object.create(null);
 for(let i=0;i<n;i++){const key=scalar(uint(data+i*rs,rs));if(typeof key!=='string')fail('BAD_BINARY_PLIST');if(wanted.has(key)){if(Object.hasOwn(out,key))fail('BAD_BINARY_PLIST');const id=uint(data+(n+i)*rs,rs);out[key]=iconKeys.has(key)?nested(id):scalar(id);}}
 return out;
}

function xmlPlist(a) {
 let s=text(a).replace(/^\uFEFF/,'').replace(/<\?xml[\s\S]*?\?>/g,'').replace(/<!--[\s\S]*?-->/g,'');
 if(/<!ENTITY|<!DOCTYPE[^>]*\[/i.test(s))fail('UNSUPPORTED_XML_ENTITY');
 s=s.replace(/<!DOCTYPE[^>]*>/g,'').trim();
 const tokens=s.match(/<[^>]+>|[^<]+/g)||[];let p=0;
 const skip=()=>{while(p<tokens.length&&!tokens[p].startsWith('<')&&!tokens[p].trim())p++;};
 const decode=x=>x.replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos);/gi,(_,e)=>e[0]==='#'?String.fromCodePoint(parseInt(e.slice(e[1].toLowerCase()==='x'?2:1),e[1].toLowerCase()==='x'?16:10)):({amp:'&',lt:'<',gt:'>',quot:'"',apos:"'"}[e]));
 function parse(depth=0) {
  if(depth>64)fail('BAD_XML_PLIST');skip();const open=tokens[p++];const m=/^<([a-z]+)(?:\s[^>]*)?\s*(\/?)>$/.exec(open||'');if(!m)fail('BAD_XML_PLIST');const tag=m[1],self=/\/>$/.test(open);
  if(tag==='true'||tag==='false'){if(!self){skip();if(tokens[p++]!==`</${tag}>`)fail('BAD_XML_PLIST');}return tag==='true';}
  if(tag==='dict'||tag==='array'||tag==='plist'){
   if(self)return tag==='dict'?Object.create(null):[];
   const children=[];for(;;){skip();if(tokens[p]===`</${tag}>`){p++;break;}children.push(parse(depth+1));if(children.length>20000)fail('BAD_XML_PLIST');}
   if(tag==='plist'){if(children.length!==1)fail('BAD_XML_PLIST');return children[0];}
   if(tag==='array')return children;
   if(children.length%2)fail('BAD_XML_PLIST');const out=Object.create(null);for(let i=0;i<children.length;i+=2){if(typeof children[i]!=='string'||Object.hasOwn(out,children[i]))fail('BAD_XML_PLIST');out[children[i]]=children[i+1];}return out;
  }
  if(!['key','string','integer','real','date','data'].includes(tag))fail('BAD_XML_PLIST');
  let raw='';if(!self){while(p<tokens.length&&!tokens[p].startsWith('<'))raw+=tokens[p++];if(tokens[p++]!==`</${tag}>`)fail('BAD_XML_PLIST');}
  raw=decode(raw);if(tag==='integer'||tag==='real'){const n=Number(raw.trim());if(!Number.isFinite(n))fail('BAD_XML_PLIST');return n;}if(tag==='data')return {dataChars:raw.trim().length};return raw;
 }
 const result=parse();skip();if(p!==tokens.length)fail('BAD_XML_PLIST');return result;
}

async function limitedBody(response,max) {
 const reader=response.body.getReader();const parts=[];let size=0;
 try {for(;;){const {value,done}=await reader.read();if(done)break;size+=value.length;if(size>max)fail('BODY_TOO_LARGE');parts.push(value);}}
 catch(e){await reader.cancel().catch(()=>{});throw e;}
 const out=new Uint8Array(size);let at=0;for(const p of parts){out.set(p,at);at+=p.length;}return out;
}

export async function parseIPA(url,transport=fetch,options={}) {
 url=publicURL(url); const started=Date.now();let resolved=url,total=null,etag=null;const requests=[];
 async function range(spec,maximum) {
  let target=resolved,response;const headers={'Range':spec,'Accept-Encoding':'identity'};if(etag)headers['If-Range']=etag;
  for(let hop=0;;hop++) {
   response=await transport(target,{headers,redirect:'manual',signal:AbortSignal.timeout(15000),cf:{cacheTtl:0}});
   if([301,302,303,307,308].includes(response.status)){const location=response.headers.get('location');await response.body?.cancel();if(!location||hop>=5)fail('BAD_REDIRECT');target=publicURL(new URL(location,target).href);continue;}break;
  }
  if(response.status!==206){await response.body?.cancel();if(response.status===429||response.status>=500)throw new SourceError('UPSTREAM_UNAVAILABLE','下载服务器限流或暂时不可用',422,true);if([401,403,404,410].includes(response.status))throw new SourceError('DOWNLOAD_INACCESSIBLE',`下载地址无法访问（HTTP ${response.status}）`);fail('RANGE_UNSUPPORTED',`Expected 206, received ${response.status}`);}
  const m=/^bytes (\d+)-(\d+)\/(\d+)$/.exec(response.headers.get('content-range')||'');
  if(!m){await response.body?.cancel();fail('BAD_CONTENT_RANGE');}
  const lo=safe(Number(m[1])),hi=safe(Number(m[2])),length=safe(Number(m[3]));
  if(hi<lo||hi>=length||hi-lo+1>maximum){await response.body?.cancel();fail('BAD_CONTENT_RANGE');}
  if(total!==null&&length!==total){await response.body?.cancel();fail('OBJECT_CHANGED');}
  const suffix=/^bytes=-(\d+)$/.exec(spec), exact=/^bytes=(\d+)-(\d+)$/.exec(spec);
  if(suffix&&(lo!==Math.max(0,length-Number(suffix[1]))||hi!==length-1)||exact&&(lo!==Number(exact[1])||hi!==Number(exact[2]))){await response.body?.cancel();fail('BAD_CONTENT_RANGE');}
  const current=response.headers.get('etag');if(etag&&current!==etag){await response.body?.cancel();fail('OBJECT_CHANGED');}
  const encoding=response.headers.get('content-encoding');if(encoding&&encoding!=='identity'){await response.body?.cancel();fail('ENCODED_RANGE');}
  total=length;resolved=target;if(!etag&&current&&!current.startsWith('W/'))etag=current;
  const a=await limitedBody(response,maximum);if(a.length!==hi-lo+1)fail('TRUNCATED_RANGE');requests.push({range:spec,bytes:a.length,status:206});return {a,lo};
 }
 const tail=await range('bytes=-65557',65557),t=view(tail.a);let eocd=-1;
 for(let p=tail.a.length-22;p>=0;p--){if(t.getUint32(p,true)===0x06054b50&&p+22+t.getUint16(p+20,true)===tail.a.length){eocd=p;break;}}
 if(eocd<0)fail('EOCD_NOT_FOUND');
 if(t.getUint16(eocd+4,true)!==0||t.getUint16(eocd+6,true)!==0||t.getUint16(eocd+8,true)!==t.getUint16(eocd+10,true))fail('MULTIDISK_UNSUPPORTED');
 let count=t.getUint16(eocd+10,true),cdSize=t.getUint32(eocd+12,true),cdOffset=t.getUint32(eocd+16,true),zip64=false;
 if(count===65535||cdSize===0xffffffff||cdOffset===0xffffffff){
  zip64=true;const position=tail.lo+eocd-20;if(position<0)fail('BAD_ZIP64');
  const loc=position>=tail.lo?tail.a.subarray(position-tail.lo,position-tail.lo+20):(await range(`bytes=${position}-${position+19}`,20)).a;const l=view(loc);
  if(loc.length!==20||l.getUint32(0,true)!==0x07064b50||l.getUint32(4,true)!==0||l.getUint32(16,true)!==1)fail('BAD_ZIP64');
  const zOffset=safe(Number(l.getBigUint64(8,true))),z=(await range(`bytes=${zOffset}-${zOffset+55}`,56)).a,zv=view(z);
  if(zv.getUint32(0,true)!==0x06064b50||zv.getUint32(16,true)||zv.getUint32(20,true)||zv.getBigUint64(24,true)!==zv.getBigUint64(32,true))fail('BAD_ZIP64');
  count=safe(Number(zv.getBigUint64(32,true)));cdSize=safe(Number(zv.getBigUint64(40,true)));cdOffset=safe(Number(zv.getBigUint64(48,true)));
 }
 if(cdSize<1||cdSize>4194304||count>100000||cdOffset+cdSize>tail.lo+eocd)fail('DIRECTORY_LIMIT');
 let cd;
 if(cdOffset>=tail.lo&&cdOffset+cdSize<=total)cd=tail.a.subarray(cdOffset-tail.lo,cdOffset-tail.lo+cdSize);
 else cd=(await range(`bytes=${cdOffset}-${cdOffset+cdSize-1}`,cdSize)).a;
 const cv=view(cd);let at=0,main=null,seen=0;const files=[];
 while(at<cd.length){
  if(at+46>cd.length||cv.getUint32(at,true)!==0x02014b50)fail('BAD_DIRECTORY');
  const flags=cv.getUint16(at+8,true),method=cv.getUint16(at+10,true),crc=cv.getUint32(at+16,true),nl=cv.getUint16(at+28,true),el=cv.getUint16(at+30,true),cl=cv.getUint16(at+32,true);let compressed=cv.getUint32(at+20,true),uncompressed=cv.getUint32(at+24,true),offset=cv.getUint32(at+42,true),disk=cv.getUint16(at+34,true);
  const next=at+46+nl+el+cl;if(next>cd.length)fail('BAD_DIRECTORY');
  const name=text(cd.subarray(at+46,at+46+nl));
  const isMain=/^Payload\/[^/]+\.app\/Info\.plist$/.test(name);
  if(isMain||/^Payload\/[^/]+\.app\/(?:[^/]+\.png|Assets\.car)$/.test(name)){
   if(isMain&&main)fail('MULTIPLE_MAIN_APPS');
   if(compressed===0xffffffff||uncompressed===0xffffffff||offset===0xffffffff||disk===65535){
    let q=at+46+nl,end=q+el,found=false;while(q+4<=end){const tag=cv.getUint16(q,true),n=cv.getUint16(q+2,true);q+=4;if(q+n>end)fail('BAD_ZIP64');if(tag===1){let b=q;const read64=()=>{if(b+8>q+n)fail('BAD_ZIP64');const x=safe(Number(cv.getBigUint64(b,true)));b+=8;return x;};if(uncompressed===0xffffffff)uncompressed=read64();if(compressed===0xffffffff)compressed=read64();if(offset===0xffffffff)offset=read64();if(disk===65535){if(b+4>q+n)fail('BAD_ZIP64');disk=cv.getUint32(b,true);}found=true;break;}q+=n;}if(!found)fail('BAD_ZIP64');
   }
   if(disk)fail('MULTIDISK_UNSUPPORTED');
   const entry={name,flags,method,crc,compressed,uncompressed,offset};if(isMain)main=entry;else files.push(entry);
  }
  seen++;at=next;
 }
 if(seen!==count)fail('BAD_DIRECTORY');if(!main)fail('MAIN_PLIST_NOT_FOUND');
 async function readEntry(entry,compressedLimit,outputLimit,limitCode){
  if(entry.flags&1)fail('ENCRYPTED_UNSUPPORTED');if(![0,8].includes(entry.method))fail('COMPRESSION_UNSUPPORTED');
  if(entry.compressed<1||entry.compressed>compressedLimit||entry.uncompressed>outputLimit)fail(limitCode);
  const local=(await range(`bytes=${entry.offset}-${entry.offset+29}`,30)).a,lv=view(local);
  if(lv.getUint32(0,true)!==0x04034b50||lv.getUint16(8,true)!==entry.method||lv.getUint16(6,true)!==entry.flags)fail('BAD_LOCAL_HEADER');
  const nameLen=lv.getUint16(26,true),extraLen=lv.getUint16(28,true);
  const localName=(await range(`bytes=${entry.offset+30}-${entry.offset+29+nameLen}`,nameLen)).a;
  if(text(localName)!==entry.name)fail('BAD_LOCAL_HEADER');
  const dataStart=entry.offset+30+nameLen+extraLen;if(dataStart+entry.compressed>cdOffset)fail('BAD_LOCAL_HEADER');
  const compressed=(await range(`bytes=${dataStart}-${dataStart+entry.compressed-1}`,entry.compressed)).a;
  let blob;try{blob=entry.method===0?compressed:new Uint8Array(inflateRawSync(compressed,{maxOutputLength:outputLimit}));}catch{fail('DECOMPRESSION_FAILED');}
  if(blob.length!==entry.uncompressed)fail('ENTRY_SIZE_MISMATCH');if(crc32(blob)!==entry.crc)fail('CRC_MISMATCH');return blob;
 }
 const blob=await readEntry(main,131072,524288,'PLIST_LIMIT'),crc=crc32(blob);
 const binary=blob.length>=8&&text(blob.subarray(0,8))==='bplist00';const info=binary?binaryPlist(blob):xmlPlist(blob);
 const string=(key,required=false)=>{const x=info?.[key];if(x===undefined&&!required)return null;if(typeof x!=='string'||!x.trim()||x.length>1024)fail('INVALID_METADATA',key);return x;};
 const metadata={name:string('CFBundleDisplayName')||string('CFBundleName'),bundleIdentifier:string('CFBundleIdentifier',true),version:string('CFBundleShortVersionString',true),buildVersion:string('CFBundleVersion'),minOSVersion:string('MinimumOSVersion')};
 if(!metadata.name)fail('INVALID_METADATA','CFBundleDisplayName / CFBundleName');
 let icon=null;
 if(options.extractIcon!==false){
  const primary=info.CFBundleIcons?.CFBundlePrimaryIcon??info['CFBundleIcons~ipad']?.CFBundlePrimaryIcon;
  const iconNames=[primary?.CFBundleIconName].filter(x=>typeof x==='string'&&x.length<=200);
  const iconFiles=[...(Array.isArray(primary?.CFBundleIconFiles)?primary.CFBundleIconFiles:[]),...(Array.isArray(info.CFBundleIconFiles)?info.CFBundleIconFiles:[]),info.CFBundleIconFile].filter(x=>typeof x==='string'&&x.length<=200&&!x.includes('/')&&!x.includes('..'));
  const prefix=main.name.slice(0,-'Info.plist'.length),rootFiles=files.filter(f=>f.name.startsWith(prefix));
  const pngs=rootFiles.filter(f=>f.name.endsWith('.png')&&iconFiles.some(n=>{const base=n.replace(/\.png$/i,'');return new RegExp('^'+base.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+'(?:@[123]x)?(?:~(?:iphone|ipad))?\\.png$','i').test(f.name.slice(prefix.length));}));
  pngs.sort((a,b)=>b.uncompressed-a.uncompressed);
  const car=rootFiles.find(f=>f.name===prefix+'Assets.car');let lastError;
  const iconFailure=e=>{if(e instanceof SourceError||['TimeoutError','AbortError'].includes(e.name)||['OBJECT_CHANGED','TRUNCATED_RANGE','RANGE_UNSUPPORTED','BAD_CONTENT_RANGE','ENCODED_RANGE'].includes(e.code))throw e;return e;};
  for(const f of pngs.slice(0,8))try{icon={...normalizeIconPNG(await readEntry(f,2*1024*1024,4*1024*1024,'ICON_LIMIT')),entry:f.name};break;}catch(e){lastError=iconFailure(e);}
  if(!icon&&car)try{icon={...extractCARIcon(await readEntry(car,8*1024*1024,16*1024*1024,'ICON_LIMIT'),iconNames.length?iconNames:['AppIcon'],options.makeLZFSE),entry:car.name};}catch(e){lastError=iconFailure(e);}
  if(!icon&&(iconNames.length||iconFiles.length||car))fail('ICON_EXTRACTION_FAILED',lastError?.code||lastError?.message||'Primary icon is missing');
 }
 return {metadata,icon,entry:main.name,plistFormat:binary?'binary':'xml',compression:main.method,compressedBytes:main.compressed,uncompressedBytes:main.uncompressed,crc32:crc.toString(16).padStart(8,'0'),zip64,entryCount:count,centralDirectoryBytes:cdSize,requests,requestCount:requests.length,downloadedBytes:requests.reduce((n,r)=>n+r.bytes,0),fullBytes:total,originalURL:url,finalHost:new URL(resolved).hostname,strongETag:etag,elapsedMs:Date.now()-started};
}
