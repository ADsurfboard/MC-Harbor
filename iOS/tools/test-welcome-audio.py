#!/usr/bin/env python3
"""Decode the actual bundled four MP3s without playback or real audio output."""
from pathlib import Path
import hashlib, json, subprocess, tempfile
root = Path(__file__).resolve().parents[2]
source = r'''
import Foundation
import AVFoundation
@main struct Run {
  static func main() throws {
    var reports:[[String:Any]]=[]
    for name in ["welcome","welcome-female2","welcome-male","welcome-male2"] {
      let url=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(name+".mp3")
      let file=try AVAudioFile(forReading:url)
      guard file.length>0,file.processingFormat.sampleRate>0,let buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:1024) else { throw NSError(domain:"HarborAudioQA",code:1) }
      var decoded:AVAudioFramePosition=0
      while file.framePosition<file.length {
        try file.read(into:buffer,frameCount:1024)
        guard buffer.frameLength>0 else { throw NSError(domain:"HarborAudioQA",code:2) }
        decoded += AVAudioFramePosition(buffer.frameLength)
      }
      guard decoded>0 else { throw NSError(domain:"HarborAudioQA",code:3) }
      reports.append(["asset":name+".mp3","frames":file.length,"sampleRate":file.processingFormat.sampleRate,"duration":Double(file.length)/file.processingFormat.sampleRate,"decodedFrames":decoded])
    }
    print(String(decoding:try JSONSerialization.data(withJSONObject:reports,options:.sortedKeys),as:UTF8.self))
  }
}
'''
with tempfile.TemporaryDirectory(prefix='harbor-welcome-audio-') as temporary:
    folder=Path(temporary);swift=folder/'Decode.swift';swift.write_text(source);binary=folder/'decode'
    subprocess.run(['xcrun','swiftc','-parse-as-library',str(swift),'-o',str(binary)],check=True)
    result=subprocess.run([str(binary),str(root/'Assets/Voice')],capture_output=True,text=True,check=True,timeout=45)
    reports=json.loads(result.stdout)
    assert len(reports)==4
    for item in reports:
        data=(root/'Assets/Voice'/item['asset']).read_bytes();item.update(bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
        assert item['decodedFrames']>0 and 0<item['duration']<120
    print(json.dumps({'passed':True,'scope':'actual MP3 decode; no sound playback or voice-identity listening claim','assets':reports},indent=2))
