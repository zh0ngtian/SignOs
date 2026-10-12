#!/usr/bin/env python3
"""Validate the frozen SignOs batch at the exact commit introducing its manifest."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


def validate(root, commit):
    root=Path(root);path=root/'.release-batch.json';data=json.loads(path.read_text())
    if data.get('schemaVersion')!=1 or not re.fullmatch(r'[0-9a-f-]{36}',data.get('batchId','')):raise ValueError('Invalid frozen batch manifest')
    if data.get('project')!='signos-production' or data.get('target')!='com.signos.app' or data.get('environment')!='production':raise ValueError('Unexpected SignOs release scope')
    introduced=subprocess.check_output(['git','-C',str(root),'log','-1','--format=%H','--','.release-batch.json'],text=True).strip()
    if introduced!=commit:raise ValueError('Build the exact commit introducing this frozen batch; do not borrow a later main commit')
    tasks=data.get('tasks',[])
    if not tasks:raise ValueError('No participating tasks')
    for task in tasks:
        if not re.fullmatch('[0-9a-f]{40}',task.get('sha','')):raise ValueError('Task SHA must be immutable')
        if subprocess.run(['git','-C',str(root),'merge-base','--is-ancestor',task['sha'],commit],capture_output=True).returncode:raise ValueError('Participating task not included in release commit')
        checks=task.get('validation',{}).get('checks',[])
        if not checks or any(c.get('status')!='passed' for c in checks):raise ValueError('Missing passed task validation')
    prepared=data['prepared'];version=re.search(r'^FEATHER_PROJECT_VERSION=(.+)$',(root/'Feather.xcconfig').read_text(),re.M).group(1)
    builds=set(re.findall(r'CURRENT_PROJECT_VERSION = (\d+);',(root/'Feather.xcodeproj/project.pbxproj').read_text()))
    if prepared['version']!=version or builds!={prepared['buildNumber']}:raise ValueError('Frozen version/build differs from project')
    return {'batchId':data['batchId'],'batchManifestSha256':hashlib.sha256(path.read_bytes()).hexdigest(),'releaseScope':data['scope']}

if __name__=='__main__':
    try:print(json.dumps(validate(Path.cwd(),sys.argv[1])))
    except (ValueError,KeyError,OSError,IndexError) as e:raise SystemExit(str(e))
