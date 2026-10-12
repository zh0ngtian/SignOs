import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
import check_release_batch
from signos_release_adapter import Adapter, version


def git(root,*args):return subprocess.check_output(['git','-C',str(root),*args],text=True,stderr=subprocess.DEVNULL).strip()


class FrozenManifestTests(unittest.TestCase):
    def test_tasks_ancestry_version_and_exact_introducing_commit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);git(root,'init','-b','main');git(root,'config','user.name','Test');git(root,'config','user.email','test@example.invalid')
            (root/'Feather.xcodeproj').mkdir();(root/'Feather.xcodeproj/project.pbxproj').write_text('CURRENT_PROJECT_VERSION = 23;')
            (root/'Feather.xcconfig').write_text('FEATHER_PROJECT_VERSION=1.1.1\n');git(root,'add','.');git(root,'commit','-m','task');task=git(root,'rev-parse','HEAD')
            data={'schemaVersion':1,'batchId':'11111111-1111-1111-1111-111111111111','project':'signos-production','scope':'test','target':'com.signos.app','environment':'production',
                  'tasks':[{'id':'task','sha':task,'validation':{'checks':[{'name':'unit','status':'passed'}]}}],
                  'prepared':{'version':'1.1.1','buildNumber':'23'}}
            manifest=root/'.release-batch.json';manifest.write_text(json.dumps(data));git(root,'add','.');git(root,'commit','-m','freeze');frozen=git(root,'rev-parse','HEAD')
            result=check_release_batch.validate(root,frozen);self.assertEqual(result['batchId'],data['batchId'])
            (root/'README.md').write_text('later docs');git(root,'add','.');git(root,'commit','-m','later')
            with self.assertRaisesRegex(ValueError,'exact commit'):check_release_batch.validate(root,git(root,'rev-parse','HEAD'))
            git(root,'checkout',frozen);data['tasks'][0]['sha']='f'*40;manifest.write_text(json.dumps(data));git(root,'add','.');git(root,'commit','-m','invalid participant')
            with self.assertRaisesRegex(ValueError,'not included'):check_release_batch.validate(root,git(root,'rev-parse','HEAD'))


class AdapterRecoveryTests(unittest.TestCase):
    def adapter(self,root):
        a=Adapter.__new__(Adapter);a.root=root;a.artifacts=root;a.repository='owner/repo';a.data={'id':'batch','frozen':{'sha':'a'*40,'version':'1.1.1','buildNumber':'23'}}
        return a
    def test_existing_successful_ci_does_not_start_a_second_build(self):
        with tempfile.TemporaryDirectory() as directory:
            a=self.adapter(Path(directory));commands=[]
            a.cmd=lambda args:commands.append(args) or ('a'*40 if args[:2]==['git','rev-parse'] else '')
            a.runs=lambda branch:[{'id':10,'status':'completed','conclusion':'success','run_attempt':1}]
            a.wait_run=lambda *args:None;a.check_build=lambda:{'done':True}
            with patch('signos_release_adapter.find_artifact',return_value={'run_id':10,'artifact_id':20}):a.run_build()
            self.assertFalse(any('push' in c or 'rerun' in c for c in commands))
    def test_ci_failure_reruns_same_run_once(self):
        with tempfile.TemporaryDirectory() as directory:
            a=self.adapter(Path(directory));commands=[]
            a.cmd=lambda args:commands.append(args) or ('a'*40 if args[:2]==['git','rev-parse'] else '')
            a.runs=lambda branch:[{'id':10,'status':'completed','conclusion':'failure','run_attempt':1}]
            attempts=[];a.wait_run=lambda *args:attempts.append(args);a.check_build=lambda:{'done':True}
            with patch('signos_release_adapter.find_artifact',side_effect=ValueError('No retained IPA')):a.run_build()
            self.assertEqual([c for c in commands if 'rerun' in c],[['gh','run','rerun','10','-R','owner/repo']])
            self.assertEqual(attempts,[('main',2)])
    def test_ci_artifact_download_uses_fresh_verified_attempt_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);a=self.adapter(root);a.repository='owner/repo';a.artifacts=root/'artifacts';a.artifacts.mkdir()
            a.data['frozen'].update({'manifestSha256':'c'*64});commands=[]
            def cmd(args):
                commands.append(args)
                target=Path(args[args.index('-D')+1]);target.mkdir(parents=True,exist_ok=True)
                (target/'SignOs.ipa').write_bytes(b'ipa')
                (target/'build-metadata.json').write_text(json.dumps({'buildNumber':'23','batchId':'batch','batchManifestSha256':'c'*64}))
                (target/'release-batch.json').write_text('{}')
            a.cmd=cmd
            with patch('signos_release_adapter.find_artifact',return_value={'run_id':10}),patch('signos_release_adapter.prepare_release'):
                first,_=a.ci_package();second,_=a.ci_package()
            downloads=[command for command in commands if command[:3]==['gh','run','download']]
            self.assertEqual(len(downloads),1)
            self.assertNotIn('--clobber',downloads[0])
            self.assertEqual(first.resolve(),second.resolve())
            self.assertTrue((a.artifacts/'ci-current.json').exists())
    def test_published_tag_is_never_moved(self):
        with tempfile.TemporaryDirectory() as directory:
            a=self.adapter(Path(directory));commands=[]
            def cmd(args):
                commands.append(args)
                if args[:2]==['git','tag']:return 'v1.1.1'
                if args[:2]==['git','rev-list']:return 'b'*40
                return ''
            a.cmd=cmd
            with self.assertRaisesRegex(ValueError,'cannot move'):a.run_github()
            self.assertFalse(any('push' in c for c in commands))
    def test_bad_downloaded_checksums_are_not_overwritten_into_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);a=self.adapter(root);target=root/'github';target.mkdir()
            (target/'SHA256SUMS').write_text('tampered');(target/'SignOs.ipa').write_bytes(b'ipa');(target/'build-metadata.json').write_bytes(b'{}')
            ci=root/'ci';ci.mkdir();(ci/'SignOs.ipa').write_bytes(b'ipa');(ci/'build-metadata.json').write_bytes(b'{}');(ci/'release-batch.json').write_text('{}')
            a.api=lambda *args,**kw:{'draft':False,'html_url':'https://example.invalid/release','assets':[{'name':n} for n in ['SignOs.ipa','build-metadata.json','SHA256SUMS']]}
            a.runs=lambda branch:[{'id':1,'status':'completed','conclusion':'success'}];a.cmd=lambda args:'';a.ci_package=lambda:(ci,{'sha256':'test'})
            with patch('signos_release_adapter.prepare_release'):
                with self.assertRaisesRegex(ValueError,'checksums mismatch'):a.check_github()
    def test_version_format(self):
        self.assertEqual(version('1.1.0'),(1,1,0))
        with self.assertRaises(ValueError):version('v1.1.0')

if __name__=='__main__':unittest.main()
