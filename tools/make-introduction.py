"""Create the Chinese product and technical introduction, with embedded CJK fonts."""
from pathlib import Path
from xml.sax.saxutils import escape
from reportlab.pdfgen import canvas
from reportlab.lib.colors import HexColor, Color
from reportlab.lib.utils import ImageReader
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import Paragraph
from reportlab.lib.styles import ParagraphStyle

ROOT=Path(__file__).resolve().parent.parent
OUT=ROOT.parents[1]/'outputs/MC-Harbor-启动器介绍.pdf';OUT.parent.mkdir(exist_ok=True)
pdfmetrics.registerFont(TTFont('CJK','/System/Library/Fonts/Supplemental/Arial Unicode.ttf'))
W,H=595.276,841.89
INK=HexColor('#10271E');GREEN=HexColor('#29825B');MUTED=HexColor('#5C6E65');PALE=HexColor('#EDF4EE');LINE=HexColor('#D9E5DD')
DOC=canvas.Canvas(str(OUT),pagesize=(W,H),pageCompression=1)
DOC.setTitle('MC Harbor | 启动器介绍');DOC.setAuthor('morben 墨尔本');DOC.setSubject('1.5.0：原生 macOS Minecraft 启动器，架构、功能与实例资源汉化')
README=['# MC Harbor','1.5.0 · Apple Silicon · macOS 26 及以上','[下载最新版](https://github.com/ADsurfboard/MC-Harbor/releases/latest) · [产品介绍 PDF](https://github.com/ADsurfboard/MC-Harbor/releases/download/v1.5.0/MC-Harbor-Introduction.pdf) · [作者 GitHub](https://github.com/ADsurfboard) · [作者 B站](https://space.bilibili.com/1628767816) · [问题与功能建议](https://github.com/ADsurfboard/MC-Harbor/issues/new/choose)','以下正文与随包 PDF 同版。']
STYLE=ParagraphStyle('body',fontName='CJK',fontSize=10.4,leading=17.4,textColor=INK,wordWrap='CJK',spaceAfter=0)

def txt(text,x,y,size=11,color=INK,font='CJK'):
    DOC.setFont(font,size);DOC.setFillColor(color);DOC.drawString(x,y,text)
def para(text,x,y,width,size=10.4,color=INK,leading=None):
    README.append(text)
    style=ParagraphStyle('p',parent=STYLE,fontSize=size,leading=leading or size*1.65,textColor=color)
    block=Paragraph(escape(text).replace('\n','<br/>'),style);bw,bh=block.wrap(width,1000)
    if y-bh<64:raise ValueError('Paragraph extends into footer: '+text[:48])
    block.drawOn(DOC,x,y-bh);return y-bh
def rule(y):
    DOC.setStrokeColor(LINE);DOC.setLineWidth(.7);DOC.line(46,y,W-46,y)
def page(number,tag,title,description):
    DOC.setFillColor(HexColor('#FCFDFC'));DOC.rect(0,0,W,H,fill=1,stroke=0)
    txt('MC Harbor',46,H-42,10,GREEN);txt(tag,W-185,H-42,9,MUTED)
    README.append('## '+title)
    size=min(29,(W-92)/max(1,pdfmetrics.stringWidth(title,'CJK',1)))
    txt(title,46,H-109,size)
    y=para(description,46,H-132,W-92,11,MUTED)
    rule(y-21);return y-52
def finish(number):
    rule(52);txt('MC Harbor  ·  1.5.0  ·  2026.10.26',46,33,8,MUTED)
    txt(f'{number:02d} / 10',W-86,33,8,MUTED);DOC.showPage()
def section(title,text,y):
    README.append('### '+title)
    txt(title,46,y,15);y=para(text,46,y-17,W-92);return y-27
def card(title,text,x,y,width,height):
    README.append('### '+title)
    DOC.setFillColor(PALE);DOC.roundRect(x,y-height,width,height,15,fill=1,stroke=0)
    txt(title,x+16,y-27,13);bottom=para(text,x+16,y-43,width-32,10)
    if bottom<y-height+12:raise ValueError('Card too short '+title)
def source(title,url,y):
    README.append('['+title+']('+url+')')
    txt(title,46,y,10);DOC.setFillColor(GREEN);DOC.setFont('CJK',8)
    # Short labels keep the clickable reference page readable.
    label=url.replace('https://','')
    DOC.drawString(46,y-15,label);DOC.linkURL(url,(46,y-18,min(W-46,46+pdfmetrics.stringWidth(label,'CJK',8)),y-6),relative=0)
    return y-42

# 01 - Product cover
DOC.setFillColor(INK);DOC.rect(0,0,W,H,fill=1,stroke=0)
DOC.setFillColor(HexColor('#BCE2C8'));DOC.setFont('CJK',10);DOC.drawString(48,H-47,'NATIVE MINECRAFT LAUNCHER')
DOC.drawImage(ImageReader(str(ROOT/'Assets/Brand/Icon.png')),W-215,H-270,180,180,mask='auto')
txt('MC Harbor',46,490,43,HexColor('#F4F8F4'))
txt('原生，清晰，随手可用。',48,440,23,HexColor('#D6EADC'))
para('为 macOS 重新设计的 Minecraft 启动器。\n保留 HMCL 的游戏能力，采用真实 WinHarbor 原生界面，\n把账号、下载、实例资源与汉化工作集中在一个窗口。',48,395,W-96,12,HexColor('#C0D0C6'),21)
DOC.setStrokeColor(HexColor('#375448'));DOC.line(48,269,W-48,269)
for x,big,small in [(48,'SwiftUI','原生界面'),(218,'HMCL','稳定内核'),(388,'Liquid Glass','系统材质')]:
    txt(big,x,231,17,HexColor('#F4F8F4'));txt(small,x,207,10,HexColor('#A9C7B4'))
para('1.5.0 · Apple Silicon · macOS 26 及以上\n本机验证：Apple M3 / 8GB / macOS 27',48,132,W-96,10,HexColor('#ADC4B5'),17)
txt('产品与技术介绍 / 2026.10.26',48,51,9,HexColor('#A9C7B4'));txt('01 / 10',W-91,51,9,HexColor('#A9C7B4'));DOC.showPage()

# 02 - Features
y=page(2,'DAILY USE','日常操作，一处完成。','以实例为中心。默认加载器图标高清重绘，保留实例资源原图标、可视化资源管理与明确的下载目标。')
col=(W-104)/2
card('游戏库','搜索、收藏、显示名称、加载器识别、实例设置、启动与依赖修复。实例可更换图标，也可恢复原图标。',46,y,col,133)
card('实例资源','模组、资源包、光影、地图等统称实例资源。原图标优先；支持多选、启停、本地导入与打开原项目页面。',58+col,y,col,133)
y-=147
card('下载中心','联动 Modrinth 与 CurseForge。搜索模组、资源包、光影、地图和整合包，筛选兼容版本与加载器，解析必要依赖并校验文件。',46,y,col,151)
card('账号与角色','导入原 HMCL 账号；Microsoft、第三方认证、离线身份。真实皮肤头部头像、开源 3D 预览、导入皮肤并按身份能力应用。',58+col,y,col,151)
y-=165
card('外观与声音','主题调色盘、图片 / 视频背景、三层叠片、0 至 100 通透度与独立深浅毛玻璃选项、可关闭的局部彩虹色散。弹层过渡、欢迎动画、四种原音播报与界面音效。',46,y,col,151)
card('存档与前置补全','原生编辑模式、天数、经验和生命等状态。可选前置补全在启动前检测并补齐必需模组；另有存档备份与便携模式。',58+col,y,col,151)
y-=183
para('操作细节：实例更多按钮扩大为 38pt 圆形；按钮命中覆盖完整外形与内边距。下载搜索结果按整个圆角矩形选择，空白部分也可点击。',46,y,W-92,10,MUTED)
finish(2)

# 03 - Localization
y=page(3,'INSTANCE RESOURCES','让汉化成为原生工作流。','读取原文、筛选范围、对照编辑、导出资源包。整个流程保留原实例资源。')
steps=[('01','读取全部 lang','扫描本体、已下载原版语言资产、模组 / 资源包与 KubeJS、resources 语言目录。保留所有语言原文件，原文与中文按命名空间和语言键对应。'),('02','选择全部或部分资源','左侧列表显示语言数量与翻译进度。可全选、清空或逐项勾选，也能搜索语言键、原文和译文，单独查看待翻译项。'),('03','社区补全与逐条编辑','一键按版本 / 加载器读取 CFPA 社区译库，校验 MD5 后补齐可用译文。已有中文和手动译文保留；未覆盖的英语原文继续由本机引擎补齐；无法安全处理的条目标记待翻译。'),('04','命名并导出汉化资源包','自定义名称，格式号优先读取实际游戏 JAR，兼容 JSON 与旧 LANG。保存 / 导入时检查 %s、%1$s、{0} 等占位符，导出附元数据与社区署名。'),('05','提取给 AI，再导回','未汉化包包含英文 zh_cn 模板、全部原始 lang、语言键目录与说明。让 AI 翻译模板值，保留键与占位符，再将同结构 ZIP 导入。')]
for n,title,body in steps:
    README.append('### '+title)
    DOC.setFillColor(PALE);DOC.roundRect(46,y-31,33,33,10,fill=1,stroke=0);txt(n,53,y-19,10,GREEN)
    txt(title,94,y-7,13);bottom=para(body,94,y-22,W-140,10.3);y=bottom-28
y=para('工作区自动保存编辑草稿。译库不覆盖所有实例资源；当前版本没有内置付费 AI 账号或云翻译密钥。导出的社区译文遵循 CC BY-NC-SA 4.0，已附许可与项目来源。',46,y,W-92,10,MUTED)
finish(3)

# 04 - FTB quests and datapack text
y=page(4,'QUESTS & DATAPACKS','任务与数据包，也能汉化。','同一工作区继续深入 FTB Quests 与存档数据包，按原结构提取与应用显示文本。')
y=section('FTB Quests 的核心文本','读取章节与章节组标题、任务标题 / 副标题 / 说明、任务与奖励的自定义标题，以及章节图片悬浮说明。支持旧版内联 SNBT、中期 lang/en_us.snbt 和新版按章节拆分的 JSON5 语言文件；已有中文与额外语言键保留。',y)
y=section('存档数据包与书页','自动发现 saves/<世界>/datapacks 中的 ZIP 和文件夹，以及实例 datapacks。提取进度的标题 / 说明、Patchouli 书页，以及 tellraw 和 title 指令的文字组件，覆盖聊天、标题与动作栏显示。只处理识别出的文本，任务 ID、物品 ID、触发条件与指令结构保留。',y)
y=section('一套编辑与 AI 导回流程','任务和数据包同样支持全部 / 部分选择、原文对照、逐条编辑和草稿重读。提取给 AI 会保留原始 SNBT / JSON5 / 数据文件，并提供带映射键的未汉化模板；翻译后用导入译文接回。颜色代码、格式占位符与物品链接等标记会校验。',y)
y=section('资源包与任务补丁分开应用','普通 lang 导出为资源包；任务配置与数据包译文使用“应用任务 / 数据包”。先检查文件修订和存档占用，再保存原字节备份、校验 ZIP 并原子写回，失败回滚。导出的 ZIP 也包含 overrides 目录，可按实例根目录合并；原 JAR 不改写。',y)
para('自写 FTB 任务通常没有现成社区译文，1.5 可使用系统翻译补齐英语文本，仍支持逐条人工校对或提取给 AI。新增流程已完成 39 项隔离协议检查并完整复跑，包含中途写入失败的回滚；未替用户修改真实存档，也未冒称完成 FTB 游戏内全流程试玩。',46,y,W-92,9.5,MUTED)
finish(4)

# 04 - World editor and dependency completion
y=page(5,'WORLD & DEPENDENCIES','编辑世界，补齐前置。','实例中的存档可直接编辑。需要时开启前置补全，把缺失检查放在游戏启动之前。')
y=section('原生存档编辑','实例 → 存档 → 编辑。可修改存档名称、游戏模式、难度、作弊与极限选项；设置游戏天数、日内时间和世界累计时间。玩家状态包括生命、饱食度、饱和度、经验等级与进度，总经验联动计算。',y)
y=section('先备份，再写回','支持本地玩家与独立 UUID 玩家文件。保存前检查 session.lock 和文件修订，自动保存本次涉及 NBT 文件的原字节 ZIP；保留背包、模组能力、未知标签与原数值类型。完整世界备份入口也保留。',y)
y=section('前置补全，按需开启','设置 → 运行 → 前置补全，默认关闭。启用后先检查本地必需声明、Modrinth 与 CurseForge 的精确文件依赖，按游戏版本和加载器递归寻找前置；下载后校验哈希与真实模组 ID，全部准备完成再添加并启动游戏。',y)
y=section('明确处理例外','内嵌前置与模组别名也算已安装，不重复补入。可选依赖不强装，停用项不擅自启用，冲突版本不覆盖。无法确认版本、下载受限或未公开的前置会说明缺失项并停止本次启动；可自行调整或关闭此开关。',y)
para('当前验证：25 项存档隔离检查、32 项前置图与事务检查，以及真实 Controlling → Searchables 下载 / 校验 / 重复检查通过。测试未改动玩家的真实存档与实例。',46,y,W-92,10,MUTED)
finish(5)

# 05 - Foundation and data
y=page(6,'FOUNDATION','熟悉的内核，原生的外壳。','基于 HMCL 3.16.4 稳定内核与真实 WinHarbor SwiftUI / AppKit 代码进行适配。')
rows=[('Swift / SwiftUI / AppKit','窗口、系统玻璃、导航、实例管理、偏好、动画与原生汉化编辑器。'),('Java 17 字节码 / JDK 21','无窗口桥接 HMCL 认证、游戏依赖、下载、启动、元数据与语言文件处理。'),('JavaScript / Three.js','本地离线 skinview3d 角色与披风渲染；使用真实 Minecraft 皮肤 UV。'),('JavaScript / SQL / Python','Cloudflare Workers、SQLite Durable Objects 与 D1 提供内置好友和实时聊天；Python / SQLite 自建版随源码提供。')]
for title,body in rows:
    README.append('### '+title)
    txt(title,46,y,12,GREEN);y=para(body,46,y-14,W-92,10.3)-23
y-=1
DOC.setFillColor(PALE);DOC.roundRect(46,y-70,W-92,70,13,fill=1,stroke=0)
txt('原生界面',62,y-28,12);txt('JSON Lines',209,y-28,10,MUTED);txt('HMCL 内核',365,y-28,12)
DOC.setStrokeColor(GREEN);DOC.line(142,y-25,192,y-25);DOC.line(288,y-25,347,y-25)
txt('SwiftUI / AppKit',62,y-50,9,MUTED);txt('按需启动任务进程',209,y-50,9,MUTED);txt('认证 · 下载 · 游戏启动',365,y-50,9,MUTED)
y-=101
y=section('数据与账号','接入原 HMCL 游戏目录，避免复制产生两套存档。账号身份元数据与凭据分开，完整会话存入当前 Mac 的 Keychain；3D 皮肤网页只接收图像，不接收凭据。',y)
y=section('兼容与便携','默认数据目录沿用 ~/Library/Application Support/ShengganLauncher，以兼容已有设置。应用旁放 MCHarbor.portable 后使用旁边的 MCHarborData；原 HMCL JAR 保持不变。',y)
y=section('性能策略','Java 任务按需启动；原壁纸和缩略图按文件修订缓存，资源索引批量发布，语言表后台解码，视频与流体只在状态变化时更新。保留既有视听效果；通透度为 0 至 100 的单调范围，毛玻璃使用独立原生背景扩散材质，分别适配深浅色。',y)
finish(6)

# 06 - Validation and sources
y=page(7,'VERIFICATION & SOURCES','可核对的功能与边界。','功能、许可和验证范围随对应源码与交付记录保留。')
y=section('本轮验证','公网原生客户端 59 项、24 好友客户端 17 项、Worker 59 项、Python 服务 45 项、增量后端 22 项通过；实例资源 / 汉化 38 项、FTB / 数据包 39 项复跑通过。测试覆盖真实消息推送、离线未读、串聊隔离、长备注、皮肤头像与撤销好友权限。',y)
y=section('已有基线','此前 20 项原生业务、11 项账号与资源、5 项下载事务通过；隔离环境实际安装 / 启动 1.20.1，并验证坏源回退、备份与 MultiMC 世界字节回环。初次接入时记录 27 个有效实例与 2 个账户；当前列表以目录扫描结果为准。',y)
y=para('验证边界：没有逐个长时间试玩 27 个整合包，没有替用户在线身份上传测试皮肤；本包为 ARM64、本机临时签名，未 Apple 公证。外部服务可用性与任意模组包帧率不能作永久保证。',46,y,W-92,9.5,MUTED)-27
txt('主要开源来源',46,y,15);y-=24
y=source('HMCL · GPL-3.0-or-later', 'https://github.com/HMCL-dev/HMCL',y)
y=source('skinview3d / Three.js / skinview-utils · MIT', 'https://github.com/bs-community/skinview3d',y)
y=source('CFPA 社区译库 · CC BY-NC-SA 4.0', 'https://github.com/CFPAOrg/Minecraft-Mod-Language-Package',y)
y=source('I18nUpdateMod3 更新元数据 · AGPL-3.0', 'https://github.com/xfl03/I18nUpdateMod3',y)
y=source('Terracotta · AGPL-3.0 与 IPC 例外', 'https://github.com/burningtnt/Terracotta',y)
para('界面源于用户提供的 WinHarbor；材质使用系统 Liquid Glass。界面音效：JDSherbert；欢迎播报：用户提供的 Clara、Adam、Clara 2、Morgan 四份原 MP3。标准 h 源于参考设计，正式图标以透明原生矢量绘制，外围交由系统呈现。OpenJFX / BellSoft OpenJDK 为 GPLv2 + Classpath Exception，随包保留许可。',46,y,W-92,8.8,MUTED,14)
finish(7)
# 08 - Native 1.5 update
y=page(8,'LIBRARIES & TRANSLATION','更完整的汉化，更顺手的素材库。','1.5 更新继续保留已有玻璃、叠片、粒子、音效和原始 Clara 播报。')
y=section('一键汉化：社区优先，本机补齐','先使用 CFPA 社区中文，未覆盖的英语文本继续调用 macOS 原生 Translation 引擎。FTB 任务、KubeJS、存档数据包的已识别显示文本与普通 lang 使用同一补全流程。无需云翻译密钥；系统首次使用可能需要下载语言模型。机器译文仍建议人工校对，未能安全处理的条目会保留并显示待翻译数量。',y)
y=section('长段落与文本格式保护','长任务说明按词边界拆分，格式占位符、颜色代码、物品 / 任务链接和网址留在翻译引擎之外，写回前继续校验。保留已有中文与手动译文，拒绝写入原文已经改变的旧结果；可停止任务并保留完成部分。对照编辑区支持上下拖动、隐藏 / 再显示，并记住高度与显示状态。',y)
y=section('LittleSkin 原生皮肤库','在账号页搜索公共皮肤、按收藏或最新排序、翻页、收藏与打开作者原网页。标准皮肤下载后验证 SHA256 与 PNG 尺寸，用现有 skinview3d 渲染真实 Minecraft 三维角色。确认后应用到所选账号；在线上传仍取决于该账号服务能力。高清皮肤会明确提示标准账号尺寸要求。',y)
y=section('命名、预览、切换壁纸','壁纸库支持批量导入图片 / 视频，逐张命名、预览和切换。视频缩略图右下角显示视频标记，预览默认静音；原有背景登记到库中。新导入内容使用受管理的副本，移除不会删除原始文件。',y)
para('七个默认游戏 / 加载器图标已用 imagegen 重绘成高清透明素材；自定义实例图标与实例资源自带图标继续优先。浅色界面使用黑色折面 h，深色界面保留白色 h。实例设置新增文件大小与磁盘分配空间统计，跳过符号链接并对硬链接去重；APFS 共享块以文件系统分配统计为准。',46,y,W-92,9.5,MUTED)
finish(8)

# 09 - Built-in friends and chat
y=page(9,'FRIENDS & CHAT','好友与聊天，已经连通。','默认内置公共服务。玩家无需创建 Cloudflare 账号、部署数据库或填写服务地址。')
y=section('好友身份与多好友列表','首次打开好友页，设置昵称并创建好友身份，交换好友码、双方确认后成为好友。支持接受 / 拒绝、移除、搜索昵称 / 备注 / 好友码；列表独立滚动，长昵称自动省略，备注只存本机。24 个测试好友已检查消息、头像与历史隔离。',y)
y=section('皮肤头像与最近游戏','共享的标准皮肤生成真实 Minecraft 头部头像，并可预览三维角色。主动开启共享后，好友可查看最近实例、整合包、版本、加载器、最近修改的存档目录名与时长。可筛选与特定好友的记录；同行由玩家选择，不自动推断双方已经进入同一服务器。',y)
y=section('文字消息与联机邀请','内置聊天通过 HTTPS 发送、WebSocket 实时通知，断线退回安全刷新并恢复未读提示。每位好友各有会话与草稿，重试复用消息编号避免重复发送。可发送陶瓦房间码、已开启的 Sakura 地址或普通服务器地址；收到后打开联机入口，邀请 30 分钟有效。',y)
y=section('共享、恢复与保存范围','皮肤和最近游戏默认不共享，随时可撤销；移除好友后服务撤销历史、皮肤与聊天访问。消息保留 30 天，当前显示最近 100 条，服务端可处理明文，并非端到端加密。游戏登录令牌、文件、私有路径和本机备注不会上传。恢复密钥单独导出，换 Mac 可恢复同一好友身份。',y)
para('默认服务由作者维护，当前使用 Cloudflare 免费 Workers + D1 + SQLite Durable Objects。玩家无需购买服务器；第三方额度与持续运营仍有边界，不能承诺永久无限容量。服务端及迁移配置开源，可按需自建，正常玩家不需要配置。',46,y,W-92,9.5,MUTED)
finish(9)

# 10 - Multiplayer and service boundaries
y=page(10,'PLAY TOGETHER','跨启动器，按标准联机。','陶瓦房间码与 Sakura Frp 两条路径；Minecraft 服务器地址不绑定启动器品牌。')
y=section('标准地址，没有启动器品牌门槛','联机页填写服务器地址、选择兼容实例，可启动并直接加入。复制地址后，使用其他启动器的朋友也能加入同一服务器。游戏版本、模组配置、服务器认证与外部服务额度仍然适用，启动器不承诺绕过这些条件。',y)
y=section('Sakura Frp：创建并开启 TCP 隧道','先在游戏中对局域网开放，再填写或从近期日志读取端口，选择节点并创建 TCP 隧道。官方 ARM64 frpc 按需下载、校验大小和 MD5；访问密钥保存在钥匙串，运行配置为私有权限文件，停止时删除。确认隧道成功后才显示可复制的地址。公开服务器模式只列服务允许的节点。',y)
y=section('陶瓦房间：无需配置中转服务器','基于官方 Terracotta / EasyTier 模块，优先 P2P，按需从官方发布页下载并验证 SHA256。macOS 直接运行官方进程、读取本机端口并管理生命周期，无需安装系统后台服务。先进入存档、开放局域网，再创建房间；朋友通过支持陶瓦的启动器或独立客户端加入。',y)
y=section('使用边界','好友聊天不需要玩家部署服务。陶瓦使用社区公共节点，NAT、网络质量和节点状态会影响连通；Sakura 需要玩家自己的访问密钥、可用节点及相应额度。普通地址可用于其他启动器，但 Minecraft 版本、模组配置和服务器认证仍须匹配，不绕过正版或服务器权限。',y)
para('已实测官方 ARM64 陶瓦核心的 11 项端口 / 状态 / 扫描 / 退出检查，原生启动与退出另行验证；Sakura 官方客户端下载与版本校验通过。没有宣称完成两台外网设备长时间 Minecraft 联机，也未使用真实 Sakura 账号建立测试隧道。新版本读取 Mojang 实时清单，失败时使用镜像与缓存；后续格式、认证或 Java 要求变化仍需维护适配。',46,y,W-92,9.5,MUTED)
finish(10)
DOC.save();README += ['## 构建与许可','构建、开发测试、音效授权与免费服务边界详见 [BUILDING.md](BUILDING.md) 和 [docs/SERVICES.md](docs/SERVICES.md)。本工程为 GPL-3.0-or-later；第三方素材按各自许可分发。','如果喜欢，记得 Star 我（'];(ROOT/'README.md').write_text('\n\n'.join(README)+'\n');print(OUT)
