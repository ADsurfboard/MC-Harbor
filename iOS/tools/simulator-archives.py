"""Adapt pinned ARM64 C/C++ archive build-version metadata for simulator QA.

The archived machine code, symbol table, offsets and object order are preserved.
This mirrors upstream's simulator adaptation for dylibs; it is not device testing.
"""
import struct
from pathlib import Path

def retarget_archive(path: Path) -> dict:
    data=bytearray(path.read_bytes())
    if not data.startswith(b'!<arch>\n'): raise ValueError('Expected a regular ar archive: '+str(path))
    cursor=8; objects=0; changed=0
    while cursor<len(data):
        header=data[cursor:cursor+60]
        if len(header)!=60 or header[58:60]!=b'`\n': raise ValueError('Malformed ar member')
        size=int(header[48:58].strip()); start=cursor+60; end=start+size
        if end>len(data): raise ValueError('Truncated ar member')
        name=bytes(header[:16]).decode('ascii').strip()
        if name.startswith('#1/'):start+=int(name[3:])
        if data[start:start+4]==b'\xcf\xfa\xed\xfe':
            objects+=1
            _,cpu,_,_,ncmds,sizeofcmds,_,_=struct.unpack_from('<8I',data,start)
            if cpu!=0x0100000c: raise ValueError('Non-ARM64 archive member')
            command=start+32
            if command+sizeofcmds>end: raise ValueError('Invalid load commands')
            for _ in range(ncmds):
                cmd,length=struct.unpack_from('<2I',data,command)
                if length<8 or command+length>start+32+sizeofcmds: raise ValueError('Invalid command size')
                if cmd==0x32:
                    platform=struct.unpack_from('<I',data,command+8)[0]
                    if platform==2:
                        struct.pack_into('<I',data,command+8,7);changed+=1
                    elif platform!=7: raise ValueError('Unexpected source platform: '+str(platform))
                command+=length
        cursor=end+(size%2)
    if cursor!=len(data): raise ValueError('Archive padding mismatch')
    if changed:path.write_bytes(data)
    return {'file':path.name,'objects':objects,'changedBuildVersions':changed,'bytes':len(data)}


def retarget_tapi(path: Path) -> dict:
    import re
    text=path.read_text()
    if text.startswith('--- !tapi-tbd-v3'):
        assert re.search(r'(?m)^platform:\s*ios$',text), 'Unexpected upstream TAPI platform'
        assert 'archs:' in text and 'arm64' in text
        text=text.replace('--- !tapi-tbd-v3','--- !tapi-tbd\ntbd-version: 4')
        text=re.sub(r'(?m)^uuids:.*\n','',text)
        text=re.sub(r'(?m)^platform:.*\n','',text)
        text=re.sub(r'archs:\s*\[ arm64 \]', 'targets: [ arm64-ios-simulator ]',text)
    else:
        assert 'tbd-version: 4' in text and 'arm64-ios-simulator' in text, 'Unsupported TAPI format'
    path.write_text(text)
    return {'file':path.name,'format':4,'target':'arm64-ios-simulator'}
