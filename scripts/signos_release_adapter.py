#!/usr/bin/env python3
"""SignOs adapter for the standalone release-coordinator JSON protocol."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zipfile
import uuid

from find_release_artifact import find_artifact
from prepare_github_release import prepare_release


def atomic(path, value):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    temp=path.with_suffix('.tmp');temp.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n');temp.chmod(0o600);os.replace(temp,path)


def version(value):
    if not re.fullmatch(r'\d+\.\d+\.\d+',value):raise ValueError('Invalid version: '+value)
    return tuple(map(int,value.split('.')))


def fingerprint(root):
    digest=hashlib.sha256()
    names=subprocess.check_output(['git','-C',str(root),'ls-files','-z']).decode().split('\0')
    for name in sorted(filter(None,names)):
        if name=='.release-batch.json':continue
        path=root/name;digest.update(name.encode())
        if path.is_file():digest.update(path.read_bytes())
        elif path.is_dir():digest.update(subprocess.check_output(['git','-C',str(path),'rev-parse','HEAD']))
    return digest.hexdigest()


class Adapter:
    def __init__(self,context):
        self.context_path=Path(context);self.data=json.loads(self.context_path.read_text());self.root=Path(self.data['workspace'])
        self.options=self.data['config'].get('options',{})
        self.repository=self.options.get('github_repository','zh0ngtian/SignOs')
        self.private=Path(self.options['ota_config']).expanduser()
        self.config=json.loads(self.private.read_text())
        self.artifacts=self.context_path.parent.parent/'artifacts'/self.data['id'];self.artifacts.mkdir(parents=True,exist_ok=True,mode=0o700)
        self.log=self.artifacts/'adapter.log';self.log.touch(mode=0o600,exist_ok=True)
        self.tls=ssl.create_default_context(cafile=self.config.get('caFile'))

    def progress(self,phase,**fields):
        path=self.data.get('progressPath')
        if path:atomic(path,{'phase':phase,'updatedAt':time.time(),**fields})

    def cmd(self,args,allow_missing=False):
        p=subprocess.run([str(a) for a in args],cwd=self.root,text=True,capture_output=True,
                         env={**os.environ,'GIT_TERMINAL_PROMPT':'0'})
        with self.log.open('a') as f:f.write(p.stdout);f.write(p.stderr)
        if p.returncode:
            if allow_missing and 'HTTP 404' in p.stderr:return None
            raise RuntimeError(f'{Path(str(args[0])).name} exited {p.returncode}: {p.stderr[-3000:]}')
        return p.stdout.strip()

    def gh(self,args,missing=False):
        read_only=(len(args)==2 and args[0]=='api') or args[:2]==['release','list']
        for attempt in range(3):
            try:
                out=self.cmd(['gh',*args],allow_missing=missing)
                return json.loads(out) if out is not None else None
            except RuntimeError as error:
                transient=re.search(r'\b(EOF|connection reset by peer|TLS handshake timeout|i/o timeout)\b',str(error))
                # Retry only read queries. Publishing actions retain their
                # existing effect reconciliation and are never replayed here.
                if not read_only or not transient or attempt==2:raise
                time.sleep(attempt+1)

    def api(self,path,missing=False):return self.gh(['api',path],missing)

    def fetch(self,url):
        with urllib.request.urlopen(url,context=self.tls,timeout=60) as response:return response.read()

    def current(self):return json.loads(self.fetch(self.config['baseUrl']+'/current/latest-ios.json'))

    def frozen(self):return self.data['frozen']
    def tag(self):return 'v'+self.frozen()['version']

    def prepare(self):
        path=self.artifacts/'prepared.json'
        if path.exists():prepared=json.loads(path.read_text())
        else:
            text=(self.root/'Feather.xcconfig').read_text()
            current=re.search(r'^FEATHER_PROJECT_VERSION=(.+)$',text,re.M).group(1)
            build=max(map(int,re.findall(r'CURRENT_PROJECT_VERSION = (\d+);',(self.root/'Feather.xcodeproj/project.pbxproj').read_text())))
            ota=self.current();floor=[version(current),version(ota['version'])];build=max(build,int(ota['buildNumber']))
            releases=self.gh(['release','list','-R',self.repository,'--limit','100','--json','tagName,isDraft'])
            for release in releases:
                if not release['isDraft'] and re.fullmatch(r'v\d+\.\d+\.\d+',release['tagName']):floor.append(version(release['tagName'][1:]))
            output=Path(self.config['outputRoot'])
            if output.exists():
                for directory in output.iterdir():
                    if directory.is_dir() and re.fullmatch(r'\d+\.\d+\.\d+',directory.name):
                        floor.append(version(directory.name))
                        for metadata in [directory/'ota/latest-ios.json',directory/'signed.ipa.signing.json']:
                            if metadata.exists():build=max(build,int(json.loads(metadata.read_text()).get('buildNumber',0)))
            major,minor,patch=max(floor)
            prepared={'version':f'{major}.{minor}.{patch+1}','buildNumber':str(build+1),'bundleIdentifier':'com.signos.app'}
            atomic(path,prepared)  # Reserve before edits so interruption cannot allocate a second version.
        p=self.root/'Feather.xcconfig';text=p.read_text()
        p.write_text(re.sub(r'^FEATHER_PROJECT_VERSION=.+$', 'FEATHER_PROJECT_VERSION='+prepared['version'],text,flags=re.M))
        p=self.root/'Feather.xcodeproj/project.pbxproj'
        p.write_text(re.sub(r'CURRENT_PROJECT_VERSION = \d+;', 'CURRENT_PROJECT_VERSION = '+prepared['buildNumber']+';',p.read_text()))
        before=fingerprint(self.root)
        marker=self.artifacts/'local-validation.json'
        if not marker.exists() or json.loads(marker.read_text())['fingerprint']!=before:
            self.progress('prepare',status='local-validation',version=prepared['version'],buildNumber=prepared['buildNumber'])
            self.cmd(['python3','-B','-m','unittest','discover','-s','Tests','-p','test_release_artifact.py'])
            self.cmd(['python3','-B','-m','unittest','discover','-s','Tests','-p','test_signos_release_adapter.py'])
            self.cmd(['python3','-B','Tests/GitHubReleaseRegression.py'])
            self.cmd(['make','iphoneos'])
            with zipfile.ZipFile(self.root/'packages/SignOs.ipa') as archive:
                info=plistlib.loads(archive.read('Payload/SignOs.app/Info.plist'))
            if info['CFBundleShortVersionString']!=prepared['version'] or info['CFBundleVersion']!=prepared['buildNumber'] or info['CFBundleIdentifier']!='com.signos.app':
                raise ValueError('Local Release package identity or version differs from allocated batch')
            if fingerprint(self.root)!=before:raise ValueError('Build modified tracked source/dependency inputs; inspect retained worktree before resume')
            atomic(marker,{'fingerprint':before,'passed':True})
        return {'done':True,'result':{**prepared,'localValidation':'passed','inputFingerprint':before}}

    def runs(self,branch):
        from urllib.parse import urlencode
        query=urlencode({'head_sha':self.frozen()['sha'],'branch':branch,'per_page':100})
        runs=self.api(f'repos/{self.repository}/actions/workflows/ios-build.yml/runs?{query}')['workflow_runs']
        return sorted([r for r in runs if r['head_sha']==self.frozen()['sha'] and r['head_branch']==branch and r['event'] in ('push','workflow_dispatch')],key=lambda r:r['id'],reverse=True)

    def wait_run(self,branch,min_attempt=0):
        deadline=time.monotonic()+3000
        while time.monotonic()<deadline:
            runs=self.runs(branch)
            if runs:
                run=runs[0]
                if run['run_attempt']<min_attempt:
                    time.sleep(5);continue
                self.progress('build' if branch=='main' else 'github',runId=run['id'],status=run['status'],attempt=run['run_attempt'])
                if run['status']=='completed':
                    if run['conclusion']!='success':raise RuntimeError(f'CI run {run["id"]} completed with {run["conclusion"]}; retain batch and resume after repair')
                    return run
            time.sleep(15)
        raise RuntimeError('Timed out waiting for exact-commit CI; resume will inspect the existing run')

    def ci_package(self):
        def validate(target):
            prepare_release(target,self.tag(),self.frozen()['sha'])
            meta=json.loads((target/'build-metadata.json').read_text())
            if meta['buildNumber']!=self.frozen()['buildNumber']:raise ValueError('Frozen build number differs from CI artifact')
            if meta.get('batchId')!=self.data['id'] or meta.get('batchManifestSha256')!=self.frozen()['manifestSha256']:
                raise ValueError('CI artifact does not belong to this frozen batch')
            return meta

        pointer=self.artifacts/'ci-current.json'
        if pointer.exists():
            try:
                target=Path(json.loads(pointer.read_text())['path']).resolve()
                target.relative_to(self.artifacts.resolve())
                return target,validate(target)
            except (KeyError,ValueError,OSError,json.JSONDecodeError,zipfile.BadZipFile):
                pass

        artifact=find_artifact(self.repository,self.frozen()['sha'])
        target=self.artifacts/'ci-downloads'/f"{artifact['run_id']}-{uuid.uuid4().hex}"
        target.mkdir(parents=True,exist_ok=False,mode=0o700)
        self.cmd(['gh','run','download',str(artifact['run_id']),'-R',self.repository,'-n','SignOs-ci-'+self.frozen()['sha'],'-D',str(target)])
        meta=validate(target)
        atomic(pointer,{'path':str(target),'runId':artifact['run_id'],'sha':self.frozen()['sha'],
                        'manifestSha256':self.frozen()['manifestSha256']})
        return target,meta

    def check_build(self):
        successful=[r for r in self.runs('main') if r['status']=='completed' and r['conclusion']=='success']
        if not successful:return {'done':False}
        try:target,metadata=self.ci_package()
        except ValueError as e:
            if 'No retained IPA' in str(e):return {'done':False}
            raise
        return {'done':True,'result':{'runId':successful[0]['id'],'commit':metadata['commit'],'sha256':metadata['sha256'],
                                     'version':metadata['version'],'buildNumber':metadata['buildNumber']}}

    def run_build(self):
        sha=self.frozen()['sha']
        self.cmd(['git','fetch','origin','main'])
        remote=self.cmd(['git','rev-parse','origin/main'])
        if remote!=sha:
            is_ancestor=subprocess.run(['git','merge-base','--is-ancestor',sha,'origin/main'],cwd=self.root,capture_output=True).returncode==0
            if not is_ancestor:self.cmd(['git','push','origin',sha+':refs/heads/main'])
        runs=self.runs('main')
        minimum=0
        if runs and runs[0]['status']=='completed':
            try:find_artifact(self.repository,sha)
            except ValueError:
                minimum=runs[0]['run_attempt']+1
                atomic(self.artifacts/'build-retry-intent.json',{'runId':runs[0]['id'],'minimumAttempt':minimum})
                self.cmd(['gh','run','rerun',str(runs[0]['id']),'-R',self.repository])
        self.wait_run('main',minimum)
        return {'done':True}

    def check_github(self):
        release=self.api(f'repos/{self.repository}/releases/tags/{self.tag()}',missing=True)
        if not release or release['draft']:return {'done':False}
        if not {'SignOs.ipa','build-metadata.json','SHA256SUMS'}<={a['name'] for a in release['assets']}:return {'done':False}
        runs=[r for r in self.runs(self.tag()) if r['status']=='completed' and r['conclusion']=='success']
        if not runs:return {'done':False}
        asset_state=[{k:a.get(k) for k in ('id','name','size','updated_at','digest')} for a in release['assets']]
        cache=self.artifacts/'github-verified.json'
        if cache.exists():
            previous=json.loads(cache.read_text())
            if previous['assets']==asset_state and previous['commit']==self.frozen()['sha']:
                return {'done':True,'result':previous['result']}
        target=self.artifacts/'github';target.mkdir(exist_ok=True)
        self.download_verified_release(target)
        downloaded_sums=(target/'SHA256SUMS').read_text()
        ci,meta=self.ci_package()
        (target/'release-batch.json').write_bytes((ci/'release-batch.json').read_bytes())
        prepare_release(target,self.tag(),self.frozen()['sha'])
        if (target/'SignOs.ipa').read_bytes()!=(ci/'SignOs.ipa').read_bytes() or (target/'build-metadata.json').read_bytes()!=(ci/'build-metadata.json').read_bytes():
            raise ValueError('Release assets differ from the exact frozen CI artifact')
        # prepare_release verifies both checksums directly; compare the originally downloaded sums too.
        expected=hashlib.sha256((target/'SignOs.ipa').read_bytes()).hexdigest()+'  SignOs.ipa\n'+hashlib.sha256((target/'build-metadata.json').read_bytes()).hexdigest()+'  build-metadata.json\n'
        if downloaded_sums!=expected:raise ValueError('Release checksums mismatch')
        result={'url':release['html_url'],'runId':runs[0]['id'],'sha256':meta['sha256']}
        atomic(cache,{'assets':asset_state,'commit':self.frozen()['sha'],'result':result})
        return {'done':True,'result':result}

    def download_verified_release(self,target):
        # Called only after REST assets and the exact tag workflow are verified.
        # GitHub's CLI lookup can briefly lag a newly published REST release.
        for attempt in range(3):
            try:
                self.cmd(['gh','release','download',self.tag(),'-R',self.repository,'-D',str(target),'--clobber'])
                return
            except RuntimeError as error:
                if 'release not found' not in str(error) or attempt==2:raise
                time.sleep(attempt+1)

    def run_github(self):
        tag=self.tag();sha=self.frozen()['sha']
        self.cmd(['git','fetch','origin','--tags'])
        tags=self.cmd(['git','tag','--list',tag])
        if tags:
            if self.cmd(['git','rev-list','-n','1',tag])!=sha:raise ValueError('Existing tag points to another commit; published tags cannot move')
        else:self.cmd(['git','tag','-a',tag,sha,'-m','SignOs '+self.frozen()['version']])
        remote=self.cmd(['git','ls-remote','origin','refs/tags/'+tag])
        if not remote:self.cmd(['git','push','origin','refs/tags/'+tag])
        minimum=0
        runs=self.runs(tag)
        if runs and runs[0]['status']=='completed' and runs[0]['conclusion']!='success':
            minimum=runs[0]['run_attempt']+1
            atomic(self.artifacts/'github-retry-intent.json',{'runId':runs[0]['id'],'minimumAttempt':minimum})
            self.cmd(['gh','run','rerun',str(runs[0]['id']),'-R',self.repository])
        self.wait_run(tag,minimum)
        return {'done':True}

    def ota_receipt(self,check_fixed=True):
        current=self.current()
        expected=self.frozen()
        if current['version']!=expected['version'] or current['buildNumber']!=expected['buildNumber']:return None
        if current.get('signed') is not True or current['bundleId']!='com.signos.app':raise ValueError('Unexpected OTA identity')
        cached=self.artifacts/'ota-receipt.json'
        public_keys=['version','buildNumber','bundleId','signed','size','sha256','installUrl','downloadUrl','manifestUrl']
        if cached.exists():
            previous=json.loads(cached.read_text())
            if previous.get('sourceCommit')==expected['sha'] and all(previous.get(k)==current.get(k) for k in public_keys):
                manifest=plistlib.loads(self.fetch(self.config['baseUrl']+'/current/manifest.plist'))['items'][0]
                if manifest['metadata']['bundle-version']!=expected['buildNumber'] or manifest['assets'][0]['url']!=current['downloadUrl']:
                    raise ValueError('Fixed manifest changed after full package verification')
                return previous
        sys.path.insert(0,str(Path(self.options['ota_publisher']).parent))
        from ios_ota import verify_published
        os.environ['IOS_ADHOC_OTA_CA_FILE']=self.config.get('caFile','')
        verify_published(current,fixed=check_fixed)
        blob=self.fetch(self.config['baseUrl']+'/current/latest.ipa')
        if len(blob)!=current['size'] or hashlib.sha256(blob).hexdigest()!=current['sha256']:raise ValueError('Fixed OTA package checksum mismatch')
        local=Path(self.config['outputRoot'])/expected['version']/'signed.ipa'
        if not local.exists() or local.read_bytes()!=blob:raise ValueError('Fixed IPA does not match retained signed original')
        provenance=json.loads((self.artifacts/'ota-input.json').read_text())
        _,ci=self.ci_package()
        if provenance['sourceCommit']!=expected['sha'] or provenance['unsignedIpaSha256']!=ci['sha256']:
            raise ValueError('OTA signing intent belongs to another commit or artifact')
        with zipfile.ZipFile(local) as archive:
            info=plistlib.loads(archive.read('Payload/SignOs.app/Info.plist'))
        if info['CFBundleShortVersionString']!=expected['version'] or info['CFBundleVersion']!=expected['buildNumber'] or info['CFBundleIdentifier']!='com.signos.app':raise ValueError('Signed OTA Info.plist mismatch')
        self.cmd(['python3',str(Path(self.options['ota_publisher']).with_name('ios_sign.py')),'--verify-ipa',str(local)])
        result={k:current[k] for k in ['version','buildNumber','bundleId','signed','size','sha256','installUrl','downloadUrl','manifestUrl']}
        result['sourceCommit']=expected['sha']
        atomic(self.artifacts/'ota-receipt.json',result)
        return result

    def check_ota(self):
        receipt=self.ota_receipt()
        return {'done':receipt is not None,'result':receipt or {}}

    def run_ota(self):
        target,meta=self.ci_package()
        args=['python3',self.options['ota_publisher'],'--config',str(self.private),'--ipa',str(target/'SignOs.ipa'),
              '--version',self.frozen()['version'],'--build-number',self.frozen()['buildNumber'],'--notes','SignOs coordinated release batch '+self.data['id']]
        plan=self.cmd([*args,'--plan']);atomic(self.artifacts/'ota-plan.json',json.loads(plan))
        output=Path(self.config['outputRoot'])/self.frozen()['version']
        intent=self.artifacts/'ota-input.json'
        expected={'sourceCommit':self.frozen()['sha'],'unsignedIpaSha256':meta['sha256'],'version':self.frozen()['version'],'buildNumber':self.frozen()['buildNumber']}
        if intent.exists() and json.loads(intent.read_text())!=expected:
            raise ValueError('Signing intent does not match this batch')
        if output.exists():
            if not intent.exists():raise ValueError('Existing staged version has no matching signing intent; do not overwrite it')
            # Resume a completely signed immutable stage; incomplete stages are retained for a linked higher-version repair.
            sys.path.insert(0,str(Path(self.options['ota_publisher']).parent))
            from ios_ota import check_package, stage_local, activate_staged, verify_published
            stage=output/'ota';receipt=check_package(stage)
            signed=output/'signed.ipa'
            if hashlib.sha256(signed.read_bytes()).hexdigest()!=receipt['sha256']:raise ValueError('Staged signature package mismatch')
            self.cmd(['python3',str(Path(self.options['ota_publisher']).with_name('ios_sign.py')),'--verify-ipa',str(signed)])
            os.environ['IOS_ADHOC_OTA_CA_FILE']=self.config.get('caFile','')
            channel=Path(self.config['localRoot']);remote=channel/'releases'/receipt['version']
            if remote.exists():
                if check_package(remote)!=receipt:raise ValueError('Immutable channel stage differs from retained publisher output')
            else:stage_local(stage,channel)
            verify_published(receipt,fixed=False)
            activate_staged(stage,channel);verify_published(receipt)
            atomic(self.artifacts/'ota-publication.json',receipt)
        else:
            atomic(intent,expected)
            result=json.loads(self.cmd(args));atomic(self.artifacts/'ota-publication.json',result)
        return {'done':True}

    def check_verify(self):
        github=self.check_github();ota=self.check_ota()
        if not github['done'] or not ota['done']:return {'done':False}
        return {'done':True,'result':{'github':github['result'],'ota':ota['result'],'httpsFullDownloadVerified':True}}

    def call(self,action,phase):
        if phase=='prepare':return self.prepare()
        fn=getattr(self,('check_' if action=='check' else 'run_')+phase,None)
        if not fn and action=='run' and phase=='verify':return self.check_verify()
        if not fn:raise ValueError('Unsupported adapter phase')
        return fn()


def main():
    p=argparse.ArgumentParser();p.add_argument('action',choices=['check','run']);p.add_argument('phase');p.add_argument('--context',required=True)
    a=p.parse_args()
    try:result=Adapter(a.context).call(a.action,a.phase)
    except Exception as e:print(str(e),file=sys.stderr);return 1
    print(json.dumps(result,ensure_ascii=False));return 0

if __name__=='__main__':raise SystemExit(main())
