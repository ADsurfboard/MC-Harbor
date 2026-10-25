"""Read CPU time and resident memory from a running local QA app; sends no UI input."""
from pathlib import Path
import ctypes, hashlib, json, statistics, subprocess, sys, time

pid=int(sys.argv[1]);label=sys.argv[2] if len(sys.argv)>2 else 'idle'
class RusageV2(ctypes.Structure):
    _fields_=[('uuid',ctypes.c_uint8*16)]+[(name,ctypes.c_uint64) for name in ['user_time','system_time','pkg_idle_wkups','interrupt_wkups','pageins','wired_size','resident_size','phys_footprint','proc_start_abstime','proc_exit_abstime','child_user_time','child_system_time','child_pkg_idle_wkups','child_interrupt_wkups','child_pageins','child_elapsed_abstime','diskio_bytesread','diskio_byteswritten']]
libproc=ctypes.CDLL('/usr/lib/libproc.dylib');libproc.proc_pid_rusage.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_void_p]
def snapshot():
    values=subprocess.check_output(['ps','-p',str(pid),'-o','time=,rss='],text=True).split()
    parts=values[0].split(':');seconds=float(parts[-1])+60*int(parts[-2])+(3600*int(parts[-3]) if len(parts)>2 else 0)
    return seconds,int(values[1])
preferences=Path.home()/'Library/Application Support/ShengganLauncher/preferences.json'
configBefore=hashlib.sha256(preferences.read_bytes()).hexdigest() if preferences.exists() else None
start=time.monotonic();before=snapshot();samples=[before[1]]
for _ in range(12):time.sleep(1);samples.append(snapshot()[1])
after=snapshot();elapsed=time.monotonic()-start
report={'pid':pid,'scenario':label,'seconds':round(elapsed,2),'cpuPercentOneCore':round((after[0]-before[0])/elapsed*100,2),'rssMiBMean':round(statistics.mean(samples)/1024,2),'rssMiBMax':round(max(samples)/1024,2),'cpuIncludes':'MC harbor process only; one core is 100%; excludes WindowServer and game'}
report['preferencesUnchangedDuringSample']=configBefore==(hashlib.sha256(preferences.read_bytes()).hexdigest() if preferences.exists() else None)
usage=RusageV2()
if libproc.proc_pid_rusage(pid,2,ctypes.byref(usage))==0:report['physicalFootprintMiB']=round(usage.phys_footprint/1024/1024,2)
root=Path(__file__).resolve().parent.parent
(root/'evidence'/('performance-'+label+'.json')).write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
