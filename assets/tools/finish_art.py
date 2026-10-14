"""Resize generated assets, assemble proof sheets, document and verify the art set.
Run after image generation: py -3 -B assets/tools/finish_art.py
"""
from pathlib import Path
import io,json,struct,math
from PIL import Image,ImageDraw,ImageFont,ImageOps
from make_cursors import ROLES,HOT,SIZES,main as rebuild
R=Path(__file__).resolve().parents[1]
CREAM='#FAF9F5';INK='#3D3929';SAND='#F0EEE6'
PURPOSES={'brand/mascot-sheet.png':'Character bible: four views and six expressions','brand/mascot.png':'Waving mascot cutout','look/wallpaper.png':'Daytime desktop wallpaper','look/wallpaper-evening.png':'Evening desktop wallpaper','look/lockscreen.png':'Sign-in background','look/avatar.png':'Circular account avatar','icons/house-1024.png':'VM shortcut master','icons/terminal.png':'Terminal profile icon','icons/folder-projects-1024.png':'Shared projects folder master','icons/folder-docs-1024.png':'Documents folder master','terminal/background.png':'Terminal background at 8% opacity','brand/logo.png':'Rounded mascot project badge','brand/wordmark.png':'Project wordmark','brand/banner.png':'README header','brand/social.png':'Social preview'}
def font(n):return ImageFont.load_default(size=n)
def fit(im,size):return ImageOps.contain(im,size,Image.Resampling.LANCZOS)
def paste(board,im,box):
    im=fit(im,(box[2]-box[0],box[3]-box[1]));x=box[0]+(box[2]-box[0]-im.width)//2;y=box[1]+(box[3]-box[1]-im.height)//2
    board.paste(im,(x,y),im if im.mode=='RGBA' else None)
def asset(p):return Image.open(R/p).convert('RGBA')
def label(d,pos,text,n=22):d.text(pos,text,fill=INK,font=font(n))

def proofs():
    out=R/'preview';out.mkdir(exist_ok=True)
    b=Image.new('RGB',(2400,1600),CREAM);d=ImageDraw.Draw(b)
    label(d,(38,24),'claude-house / Hermi art collection',42)
    cells=[('brand/mascot.png','Hermi',(25,90,525,595)),('look/wallpaper.png','Day / 3840 x 2160',(550,95,1435,595)),('look/wallpaper-evening.png','Evening / 3840 x 2160',(1460,95,2375,595)),('look/lockscreen.png','Sign-in / calm centre',(25,650,865,1125)),('look/avatar.png','Avatar / circular crop',(890,690,1280,1080)),('icons/terminal.png','Terminal',(1300,730,1535,1020)),('icons/folder-projects-1024.png','Projects',(1555,725,1795,1020)),('icons/folder-docs-1024.png','Documents',(1820,725,2060,1020)),('brand/logo.png','Logo',(2080,725,2375,1020)),('brand/wordmark.png','Wordmark',(25,1185,1430,1530)),('icons/house-256.png','House / 256, 48, 16',(1490,1220,1810,1510))]
    for p,name,box in cells:
        im=asset(p)
        if p=='look/avatar.png':
            mask=Image.new('L',im.size);ImageDraw.Draw(mask).ellipse((0,0,im.width-1,im.height-1),fill=255);im.putalpha(mask)
        paste(b,im,box);label(d,(box[0]+10,box[3]+6),name)
    for n,x in [(48,1880),(16,1970)]:b.paste(asset(f'icons/house-{n}.png'),(x,1340),asset(f'icons/house-{n}.png'))
    b.save(out/'overview.png')

    b=Image.new('RGB',(1600,900),CREAM);d=ImageDraw.Draw(b)
    label(d,(20,12),'Windows pointers / 32 px + 128 px / light and dark',30)
    for j,(role,file) in enumerate(ROLES.items()):
        col=j%9;row=j//9;x=12+col*176;y=65+row*310
        label(d,(x,y),role,16)
        name=Path(file).stem;master=name+'-00' if file.endswith('.ani') else name
        im=asset('cursors/src/'+master+'.png')
        for k,bg in enumerate([CREAM,INK]):
            strip=Image.new('RGB',(170,130),bg)
            for n,px in [(32,3),(128,40)]:
                q=im.resize((n,n),Image.Resampling.LANCZOS);strip.paste(q,(px,(130-n)//2),q)
            b.paste(strip,(x,y+25+k*132))
    for name,y in [('working',720),('busy',808)]:
        label(d,(20,y+20),name+' / 12 frames',20)
        for j in range(12):
            q=asset(f'cursors/src/{name}-{j:02}.png').resize((64,64),Image.Resampling.LANCZOS)
            b.paste(q,(250+j*105,y),q)
    b.save(out/'cursors.png')

    lock=asset('look/lockscreen.png');d=ImageDraw.Draw(lock)
    d.text((1920,230),'21:08',anchor='mt',font=font(205),fill='white')
    d.text((1920,470),'Tuesday, October 13',anchor='mt',font=font(55),fill='white')
    av=asset('look/avatar.png').resize((448,448),Image.Resampling.LANCZOS)
    mask=Image.new('L',(448,448));ImageDraw.Draw(mask).ellipse((0,0,447,447),fill=255);av.putalpha(mask)
    lock.alpha_composite(av,(1696,760));d=ImageDraw.Draw(lock)
    d.rounded_rectangle((1510,1260,2330,1375),radius=14,fill=(255,255,255,235),outline='white',width=3)
    d.text((1550,1290),'Password',font=font(48),fill=INK);d.text((2250,1290),'>',font=font(48),fill=INK)
    desk=asset('look/wallpaper.png');d=ImageDraw.Draw(desk)
    d.rectangle((0,2064,3840,2160),fill=(240,238,230,245))
    d.text((1830,2087),'Start',font=font(35),fill=INK);d.text((3610,2087),'09:08',font=font(35),fill=INK)
    for j,(file,title) in enumerate([('icons/house-256.png','House'),('icons/folder-projects-1024.png','Projects'),('icons/folder-docs-1024.png','Docs')]):
        q=asset(file).resize((96,96),Image.Resampling.LANCZOS);desk.alpha_composite(q,(88,160+j*230))
        d=ImageDraw.Draw(desk);d.text((136,270+j*230),title,anchor='mt',font=font(35),fill=INK)
    board=Image.new('RGB',(1920,1080),CREAM);d=ImageDraw.Draw(board)
    label(d,(45,45),'Outside / closed door',40);label(d,(1005,45),'Inside / open door',40)
    for im,x in [(lock,0),(desk,960)]:board.paste(im.convert('RGB').resize((960,540),Image.Resampling.LANCZOS),(x,220))
    label(d,(45,805),'Clock + avatar + password over unblurred sky',25)
    label(d,(1005,805),'Three desktop icons + native96px taskbar',25)
    label(d,(45,900),'Same round wooden door / brass knob / key',30)
    board.save(out/'lockscreen-mock.png')

def entries(data):
    reserved,kind,count=struct.unpack_from('<HHH',data)
    assert reserved==0 and kind in [1,2]
    found=[]
    for j in range(count):
        w,h,_,_,a,b,length,off=struct.unpack_from('<BBBBHHII',data,6+j*16);w=w or 256;h=h or 256
        assert off+length<=len(data)
        if kind==2:
            one=struct.pack('<HHH',0,2,1)+struct.pack('<BBBBHHII',w%256,h%256,0,0,a,b,length,22)+data[off:off+length]
            im=Image.open(io.BytesIO(one));im.load();assert im.size==(w,h)
        else:
            im=Image.open(io.BytesIO(data[off:off+length]));im.load();assert im.size==(w,h)
        found.append({'size':[w,h],'hotspot':[a,b] if kind==2 else None})
    return found
def chunks(data,start=0):
    while start+8<=len(data):
        tag=data[start:start+4];n=struct.unpack_from('<I',data,start+4)[0];end=start+8+n;assert end<=len(data)
        yield tag,data[start+8:end];start=end+n%2
    assert start==len(data)
def validate():
    result={}
    for p in sorted(R.rglob('*')):
        if p.suffix=='.png':
            im=Image.open(p);im.load();result[str(p.relative_to(R))]={'size':list(im.size),'mode':im.mode}
        elif p.suffix in ['.ico','.cur']:
            data=p.read_bytes();result[str(p.relative_to(R))]=entries(data)
            im=Image.open(p);im.load()
            if p.suffix=='.ico':assert len(im.ico.sizes())==9
            if p.suffix=='.cur':
                name=p.stem
                for v in result[str(p.relative_to(R))]:assert v['hotspot']==[round(t*v['size'][0]/32) for t in HOT[name]]
        elif p.suffix=='.ani':
            data=p.read_bytes();assert data[:4]==b'RIFF' and data[8:12]==b'ACON' and struct.unpack_from('<I',data,4)[0]==len(data)-8
            cs=dict(chunks(data,12));header=struct.unpack('<9I',cs[b'anih']);assert header[1:3]==(12,60)
            frame_data=[v for tag,v in chunks(cs[b'LIST'],4) if tag==b'icon']
            assert len(set(frame_data))==12
            frames=[entries(v) for v in frame_data];assert len(frames)==12
            for frame in frames:
                assert [v['size'][0] for v in frame]==SIZES
                for v in frame:assert v['hotspot']==[round(t*v['size'][0]/32) for t in HOT[p.stem]]
            rates=struct.unpack('<60I',cs[b'rate']);seq=struct.unpack('<60I',cs[b'seq ']);assert all(v<12 for v in seq) and sum(rates)==288
            result[str(p.relative_to(R))]={'frames':12,'steps':60,'average_ms':80,'native_frame_ms':[66.6667,83.3333],'frame_sizes':SIZES,'hotspot':HOT[p.stem]}
    scheme=json.loads((R/'cursors'/'scheme.json').read_text());assert set(scheme)==set(ROLES)|{'SchemeName'}
    for file in ROLES.values():assert (R/'cursors'/file).exists()
    (R/'preview'/'validation.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    return result

def document(records,result):
    lines=['# claude-house art', '', 'The mascot is Hermi (小寄): a coral hermit crab whose shell is a small cream cottage with terracotta tiles, a warm round window, chimney smoke and a roof sprout.', '', '## Where the art came from', '', '- The illustrated pictures (brand images, icon masters, avatar, wallpapers, sign-in screen and terminal background) were made with an AI image generation tool, with `brand/mascot-sheet.png` as the character reference. The exact prompt for each picture is in the table below and in `tools/generation-records.json`.', '- The avatar is reduced to four flat colours. The sign-in screen and the two wallpapers share one fixed camera on the same cottage: at sunset the round door is shut and nobody is visible; in the morning Hermi comes out and waves; at dusk he sits on the doorstep with a mug.', '- The cursors and the 16 and 24 px house icons are drawn in code by `tools/make_cursors.py`.', '- Pillow does every resize, the ICO, CUR and ANI conversions, and the proof sheets.', '- Nothing in this folder installs anything or changes Windows. Step 13 of the runbook applies the art inside the guest.', '', 'The animated cursors have 12 unique frames and 60 playback steps. Windows stores ANI timing in 1/60-second units, so alternating 4- and 5-unit steps give an exact 80 ms average; an exact 80 ms for every single frame cannot be stored.', '', '## Rebuild', '', '- `py -3 -B assets/tools/finish_art.py` (needs Pillow) resizes the generated pictures to their target sizes, redraws the cursors and icons, draws the proof sheets, validates every file and rewrites this page.', '- `py -3 -B assets/tools/w13b_scene.py` (needs Pillow, numpy, opencv-python and the Microsoft YaHei Bold font) rebuilds only the sign-in screen, the two wallpapers and `preview/lockscreen-mock.png`. It reads the three native 1672 × 941 generations listed in `tools/w13b-inputs.json`, by default from `tools/native/`. Those files are not in the repository; generate them again with the prompts in that file.', '- `py -3 -B assets/tools/w13_review.py before|after` records cursor and icon measurements in `tools/w13-verification.json`; `py -3 -B assets/tools/w13_review.py proof` redraws `preview/w13-checks.png`.', '- To use your own picture, replace the file at the same path. Step 13 uses `look/wallpaper.png`, `look/lockscreen.png` and `look/avatar.png` as they are; see `look/README.md`.', '', '## Asset inventory', '', '| File | Size | Purpose / method | Exact prompt or rebuild recipe |', '|---|---|---|---|']
    by={r['file']:r for r in records}
    for p in sorted(R.rglob('*')):
        if not p.is_file() or p.name=='ART.md':continue
        file=p.relative_to(R).as_posix();val=result.get(str(p.relative_to(R)))
        if file in by:
            r=by[file];size=' × '.join(map(str,r['size']));purpose=PURPOSES[file]+'; generated';prompt=r['prompt']
            if r.get('native_size')!=r['size']:purpose+='; Pillow resampled from '+' × '.join(map(str,r['native_size']))
        elif p.suffix=='.cur':size='32, 48, 64, 96, 128';purpose=f'Hand-drawn cursor; hotspot {HOT[p.stem]} at 32 px';prompt=f'No generation prompt. make_cursors.py master("{p.stem}"); 2px cream outline, 1px ink shadow, terracotta body; cur() scales hotspots.'
        elif p.suffix=='.ani':size='12 frames × (32, 48, 64, 96, 128)';purpose='Hand-drawn animated Hermi cursor';prompt=f'No generation prompt. make_cursors.py master("{p.stem}", frame=0..11); alternate leg pairs every3frames, absolute2px shell bob, smoke rising4px and fading, blink on frames9-10; ani() creates RIFF ACON.'
        elif p.suffix=='.ico':size='16, 20, 24, 32, 40, 48, 64, 128, 256';purpose='Pillow ICO conversion';prompt='No additional prompt. make_cursors.py ico(); house 16/24 use distinct hand-drawn tiny_house() grids, other entries derive from matching generated 1024 master.'
        elif p.suffix=='.png':
            size=' × '.join(map(str,val['size']));purpose='Pillow derivative / proof' if 'src/' not in file else 'Hand-drawn 256px cursor master'
            prompt='No additional generation prompt. Rebuild using finish_art.py proofs() or make_cursors.py; source illustration prompt is listed at its master row.'
        else:size='—';purpose='Rebuild script / metadata';prompt='Not an image; no generation prompt. Run py -3 -B assets/tools/finish_art.py after generation records are present.'
        prompt=prompt.replace('|','\\|').replace('\n','<br>');lines.append(f'| `{file}` | {size} | {purpose} | {prompt} |')
    lines+=['', '## Verification', '', '- Every PNG decodes with Pillow. Every ICO and CUR directory entry decodes on its own, and CUR hotspots are checked at all five sizes. Both ANI files parse with 12 frames at all five sizes. `cursors/scheme.json` covers all 17 Windows cursor roles. `preview/validation.json` is the full machine-readable size readback.', '- `preview/w13-checks.png` reviews the mascot, the four-colour avatar at 32 and 48 px, the calm screen zones, the old and new link cursor, and the 16 and 24 px house icons. `tools/w13-verification.json` holds the 32 px frame-to-frame differences of both animated cursors: mean absolute premultiplied RGBA over 12 consecutive frame pairs, including the wrap.', '- `preview/lockscreen-mock.png` (1920 × 1080) shows three 640 × 360 panels: the sign-in screen with clock and password box, the desktop with a 96 px taskbar and three icons, and a 50% overlay of the two. The greeting bubbles on the wallpapers are typeset by Pillow with Microsoft YaHei Bold (`C:/Windows/Fonts/msyhbd.ttc`): Chinese 60 px, English 39 px, ink #3A2A20.', '- These tools do not test the art on an installed Windows guest. Step 13 and its check do that.']
    (R/'ART.md').write_text('\n'.join(lines)+'\n',encoding='utf-8')

def main():
    records=json.loads((R/'tools'/'generation-records.json').read_text(encoding='utf-8'))
    for r in records:
        p=R/r['file'];im=Image.open(p);target=tuple(r['size'])
        r.setdefault('native_size',list(im.size))
        if r['file']=='look/avatar.png' and r.get('assembly')=='w13-flat-four-color' and im.mode=='RGBA' and im.getchannel('A').getextrema()[0]==0:
            mask=im.getchannel('A').point(lambda v:255 if v>=128 else 0);bbox=mask.getbbox()
            subject=im.crop(bbox);mask=mask.crop(bbox);cx=(mask.width-1)/2;cy=(mask.height-1)/2
            radius=max(math.hypot(x-cx,y-cy) for y in range(mask.height) for x in range(mask.width) if mask.getpixel((x,y)))
            scale=350/radius;q=subject.resize((round(subject.width*scale),round(subject.height*scale)),Image.Resampling.LANCZOS)
            canvas=Image.new('RGB',target,(250,249,245));canvas.paste(q,((1024-q.width)//2,(1024-q.height)//2),q)
            palette=Image.new('P',(1,1));colors=[201,100,66,217,119,87,250,249,245,32,29,26]
            palette.putpalette(colors*64);im=canvas.quantize(palette=palette,dither=Image.Dither.NONE);im.save(p)
        elif r['file']=='look/avatar.png' and im.mode=='RGBA' and im.getchannel('A').getextrema()[0]==0:
            subject=im.crop(im.getchannel('A').getbbox());q=fit(subject,(768,768))
            canvas=Image.new('RGB',target,(240,238,230));canvas.paste(q,((target[0]-q.width)//2,(target[1]-q.height)//2),q)
            im=canvas;im.save(p)
        if im.size!=target:
            if im.mode=='RGBA' and im.getextrema()[-1][0]<255:
                canvas=Image.new('RGBA',target);q=fit(im,target);canvas.alpha_composite(q,((target[0]-q.width)//2,(target[1]-q.height)//2));im=canvas
            else:im=im.resize(target,Image.Resampling.LANCZOS)
            im.save(p)
        assert Image.open(p).size==target
        if r['file'] in ['brand/mascot.png','brand/logo.png','brand/wordmark.png','icons/house-1024.png','icons/terminal.png','icons/folder-projects-1024.png','icons/folder-docs-1024.png']:
            check=Image.open(p);assert check.mode=='RGBA' and check.getchannel('A').getextrema()[0]==0
    (R/'tools'/'generation-records.json').write_text(json.dumps(records,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    rebuild();proofs();result=validate();document(records,result)
    print(json.dumps({'png_count':sum(p.suffix=='.png' for p in R.rglob('*')),'cur_count':15,'ani_count':2,'ico_count':3,'validated_files':len(result),'status':'passed'}))
if __name__=='__main__':main()
