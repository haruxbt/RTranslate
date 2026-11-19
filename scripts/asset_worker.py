#!/usr/bin/env python3
"""Pinned data downloads only; no credentials, telemetry, or media content."""
import argparse,fcntl,hashlib,json,os,shutil,tarfile,tempfile,time,urllib.request
from pathlib import Path

def digest(p):
    with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def child(root,name):
    p=root/name
    if Path(name).is_absolute() or '..' in Path(name).parts or not p.resolve().is_relative_to(root.resolve()):raise ValueError('Invalid asset path')
    return p

def download_archive_member(item, partial):
    request = urllib.request.Request(item['url'], headers={'User-Agent': 'RTranslate/0.3'})
    # Keep the archive temporary. Extract only the explicitly named regular file.
    with tempfile.TemporaryFile(dir=partial.parent) as download:
        with urllib.request.urlopen(request, timeout=60) as response:
            if not response.url.startswith('https://'):
                raise ValueError('Insecure redirect')
            shutil.copyfileobj(response, download)
        download.seek(0)
        if hashlib.file_digest(download, 'sha256').hexdigest() != item['archive_sha256']:
            raise ValueError('Asset archive checksum mismatch: ' + partial.name)
        download.seek(0)
        with tarfile.open(fileobj=download, mode='r:gz') as tar:
            member = tar.getmember(item['archive_member'])
            if not member.isfile():
                raise ValueError('Runtime archive member must be a regular file')
            with tar.extractfile(member) as source, partial.open('wb') as destination:
                shutil.copyfileobj(source, destination)

def prepare(catalog,root,support,import_root=None):
    root.mkdir(parents=True,exist_ok=True)
    with (root/'.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        return _prepare_locked(catalog,root,support,import_root)

def _prepare_locked(catalog,root,support,import_root=None):
    marker=root/'ready.json';previous=json.loads(marker.read_text()) if marker.exists() else {}
    state={};total=len(catalog['files'])
    for i,item in enumerate(catalog['files']):
        path=child(root,item['path']);path.parent.mkdir(parents=True,exist_ok=True)
        print(json.dumps({'message':f'モデルを準備中 {i+1}/{total}：{path.name}'}),flush=True)
        stat=path.stat() if path.is_file() and not path.is_symlink() else None
        old=previous.get('files',{}).get(item['path'],{})
        if stat and not item.get('support') and old.get('size')==stat.st_size and old.get('mtime')==stat.st_mtime_ns and old.get('sha256')==item['sha256']:pass
        elif stat and digest(path)==item['sha256']:pass
        else:
            source=child(import_root,item['path']) if import_root else None
            partial=path.with_name(path.name+'.partial')
            if partial.is_file() and digest(partial)==item['sha256']:
                os.replace(partial,path);stat=path.stat();state[item['path']]={'sha256':item['sha256'],'size':stat.st_size,'mtime':stat.st_mtime_ns};continue
            if source and source.is_file() and digest(source)==item['sha256']:shutil.copyfile(source,partial)
            elif item.get('support'):shutil.copyfile(child(support,item['path']),partial)
            elif item.get('archive_member'):
                if not item['url'].startswith('https://'): raise ValueError('HTTPS required')
                download_archive_member(item, partial)
            else:
                url=item['url'];offset=partial.stat().st_size if partial.exists() else 0
                if not url.startswith('https://'):raise ValueError('HTTPS required')
                request=urllib.request.Request(url,headers={'User-Agent':'RTranslate/0.3','Range':f'bytes={offset}-'} if offset else {'User-Agent':'RTranslate/0.3'})
                with urllib.request.urlopen(request,timeout=60) as response:
                    if not response.url.startswith('https://'):raise ValueError('Insecure redirect')
                    append=offset and response.status==206
                    if append and not response.headers.get('Content-Range','').startswith(f'bytes {offset}-'):raise ValueError('Invalid download range')
                    with partial.open('ab' if append else 'wb') as f:
                        last=time.monotonic()
                        while data:=response.read(1024*1024):
                            f.write(data)
                            if time.monotonic()-last>1:
                                print(json.dumps({'message':f'ダウンロード中：{path.name} {f.tell()//1048576} MB'}),flush=True);last=time.monotonic()
            if digest(partial)!=item['sha256']:
                partial.unlink(missing_ok=True);raise ValueError('Asset checksum mismatch: '+path.name)
            os.replace(partial,path)
        stat=path.stat();state[item['path']]={'sha256':item['sha256'],'size':stat.st_size,'mtime':stat.st_mtime_ns}
    archive=root/'open-jtalk-1.11.tar.gz';target=root/'voicevox/dict/open_jtalk_dic_utf_8-1.11'
    dictionary_valid=target.is_dir() and all(child(root,'voicevox/dict/'+n).is_file() and digest(child(root,'voicevox/dict/'+n))==h for n,h in catalog['dictionary'].items())
    if not dictionary_valid:
        temporary=root/'.dictionary-extract';temporary.mkdir(exist_ok=True)
        with tarfile.open(archive,'r:gz') as tar:
            for member in tar.getmembers():
                child(temporary,member.name)
                if not (member.isfile() or member.isdir()):raise ValueError('Archive links are forbidden')
            tar.extractall(temporary,filter='data')
        target.parent.mkdir(parents=True,exist_ok=True)
        if target.exists():os.rename(target,root/('.old-dictionary-'+str(time.time_ns())))
        os.replace(temporary/target.name,target)
    for name,expected in catalog['dictionary'].items():
        if digest(child(root,'voicevox/dict/'+name))!=expected:raise ValueError('Dictionary checksum mismatch')
    temp=root/'ready.json.partial';temp.write_text(json.dumps({'version':catalog['version'],'files':state}));os.replace(temp,marker)
    print(json.dumps({'event':'ready','message':'モデル準備完了'}),flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--catalog',type=Path,required=True);p.add_argument('--root',type=Path,required=True);p.add_argument('--support',type=Path,required=True);p.add_argument('--import-root',type=Path);a=p.parse_args()
    try:prepare(json.loads(a.catalog.read_text()),a.root,a.support,a.import_root)
    except Exception as e:print(json.dumps({'event':'error','message':str(e)}),flush=True);raise SystemExit(1)
