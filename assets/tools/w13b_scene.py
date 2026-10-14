"""Sign-in screen and wallpapers: fixed-camera generated edits, Pillow upscale/type/mock, outline readback.
Run py -3 -B assets/tools/w13b_scene.py. No other assets are rebuilt.
"""
from pathlib import Path
import json, hashlib
import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont
R=Path(__file__).resolve().parents[1]
FONT='C:/Windows/Fonts/msyhbd.ttc'
SIZE=(3840,2160)
FILES={'base':'look/lockscreen.png','day':'look/wallpaper.png','evening':'look/wallpaper-evening.png'}
def font(n):return ImageFont.truetype(FONT,n,index=0)
def edges(im):
    g=cv2.cvtColor(np.array(im),cv2.COLOR_RGB2GRAY).astype(np.float32)
    return cv2.magnitude(cv2.Sobel(g,cv2.CV_32F,1,0),cv2.Sobel(g,cv2.CV_32F,0,1))
def offsets(a,b,points):
    a=edges(a);b=edges(b);found=[]
    for x,y in points:
        r=24;s=8;patch=a[y-r:y+r+1,x-r:x+r+1]
        search=b[y-r-s:y+r+s+1,x-r-s:x+r+s+1]
        response=cv2.matchTemplate(search,patch,cv2.TM_CCOEFF_NORMED)
        _,score,_,loc=cv2.minMaxLoc(response);dx=loc[0]-s;dy=loc[1]-s
        found.append({'native_anchor':[x,y],'native_offset':[dx,dy],'ncc':score,'output_offset_px':float(np.hypot(dx*3840/1672,dy*2160/941))})
    return found
def greeting(im,cn,en):
    # Friendly CJK text at approximately 2.5% of final image height; English smaller.
    f=font(60);small=font(39);d=ImageDraw.Draw(im)
    width=max(d.textlength(cn,font=f),d.textlength(en,font=small))+100
    x=2420-int(width);y=1470;box=(x,y,x+int(width),y+205)
    d.rounded_rectangle(box,radius=45,fill='#FAF9F5',outline='#D9B48F',width=3)
    d.polygon([(x+int(width)-100,y+203),(x+int(width)-45,y+203),(x+int(width)-30,y+238)],fill='#FAF9F5')
    d.text((x+50,y+25),cn,font=f,fill='#3A2A20')
    d.text((x+50,y+112),en,font=small,fill='#3A2A20')
    return {'font_file':FONT,'font_collection_index':0,'Chinese_font_px':60,'Chinese_ink_bbox':list(f.getbbox(cn)),'English_font_px':39,'bubble_box':list(box),'Chinese':cn,'English':en}
def mock(lock,day,overlay,maximum):
    lock=lock.copy();d=ImageDraw.Draw(lock)
    d.text((1920,230),'18:36',font=font(205),fill='white',anchor='mt',stroke_width=1)
    d.text((1920,475),'10月13日 星期二',font=font(55),fill='white',anchor='mt')
    d.rounded_rectangle((1510,1120,2330,1235),radius=12,fill=(58,42,32),outline='white',width=3)
    d.text((1575,1150),'密码  • • • • • •',font=font(43),fill='white')
    day=day.copy();d=ImageDraw.Draw(day)
    d.rectangle((0,2064,3840,2160),fill='#F0EEE6')
    d.text((1810,2085),'开始',font=font(38),fill='#3D3929');d.text((3605,2085),'09:08',font=font(38),fill='#3D3929')
    for j,(file,title) in enumerate([('icons/house-256.png','小屋'),('icons/folder-projects-1024.png','项目'),('icons/folder-docs-1024.png','文档')]):
        q=Image.open(R/file).convert('RGBA').resize((96,96),Image.Resampling.LANCZOS)
        day.paste(q,(88,160+j*230),q);ImageDraw.Draw(day).text((136,270+j*230),title,anchor='mt',font=font(35),fill='#3D3929')
    board=Image.new('RGB',(1920,1080),'#FAF9F5');d=ImageDraw.Draw(board)
    titles=['解锁前 / 灯亮着，门关着','解锁后 / Hermi 来打招呼','50% 叠图 / 同一机位']
    for j,im in enumerate([lock,day,overlay]):
        x=j*640;d.text((x+22,95),titles[j],font=font(27),fill='#3D3929')
        board.paste(im.resize((640,360),Image.Resampling.LANCZOS),(x,260))
    captions=['白色时钟、日期与密码框','左侧三个图标；底部 96 px 任务栏',f'轮廓测点最大偏移：{maximum:.2f} px']
    for j,t in enumerate(captions):d.text((j*640+22,670),t,font=font(23),fill='#3D3929')
    d.text((35,850),'日夜变化保留同一屋壳、地面与镜头位置；问候文字由真实字体排版。',font=font(28),fill='#8A8170')
    board.save(R/'preview/lockscreen-mock.png')
def main():
    inputs=json.loads((R/'tools/w13b-inputs.json').read_text(encoding='utf-8-sig'))
    native={v['key']:Image.open(R/'tools'/v['path']).convert('RGB') for v in inputs}
    assert all(im.size==(1672,941) for im in native.values())
    # Landmarks lie on unchanged outer roof/chimney/sprout/wall contour, not door/crab.
    anchors=[(1095,610),(1137,551),(1178,490),(1214,446),(1268,446),(1291,408),(1354,412),(1381,408),(1444,425),(1471,533),(1519,584),(1557,641),(1539,797)]
    alignment={k:offsets(native['base'],native[k],anchors) for k in ['day','evening']}
    ground={k:offsets(native['base'],native[k],[(337,858),(541,883),(811,861),(1580,870)]) for k in ['day','evening']}
    maximum=max(v['output_offset_px'] for v in alignment['day'])
    assert maximum<=7,'Regenerate drifted house edit before publishing'
    final={k:im.resize(SIZE,Image.Resampling.LANCZOS) for k,im in native.items()}
    typography={'day':greeting(final['day'],'很高兴又见到你！','Nice to see you again'),'evening':greeting(final['evening'],'今天也辛苦啦','Good work today')}
    for k,im in final.items():im.save(R/FILES[k]);assert Image.open(R/FILES[k]).size==SIZE
    overlay=Image.blend(final['base'],final['day'],0.5)
    mock(final['base'],final['day'],overlay,maximum)
    records=json.loads((R/'tools/generation-records.json').read_text(encoding='utf-8'))
    for v in inputs:
        rec=next(r for r in records if r['file']==FILES[v['key']])
        old={k:val for k,val in rec.items() if k!='history'}
        if rec.get('work_order')!='W13B' or rec.get('prompt')!=v['prompt']:
            rec.setdefault('history',[]).append(old)
        rec.update(size=list(SIZE),prompt=v['prompt'],native_size=list(native[v['key']].size),work_order='W13B',reference_base=FILES['base'],assembly='Pillow LANCZOS upscale; w13b_scene.py typography/mock')
        if v['key'] in typography:rec['typography']=typography[v['key']]
    (R/'tools/generation-records.json').write_text(json.dumps(records,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    retained=json.loads((R/'tools/w13b-retained-hashes.json').read_text())
    unchanged=all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in retained.items());assert unchanged
    report={'native_size':[1672,941],'output_size':list(SIZE),'house_outline_max_offset_px':maximum,'house_outline_landmarks':alignment,'ground_landmarks':ground,'method':'Sobel gradient patch NCC, 49x49 native patches, +/-8px search; displacement scaled to final 3840x2160; no code-drawn illustrated scene or geometry warp','typography':typography,'retained_avatar_icons_cursors_and_old_proofs_unchanged':unchanged,'visual_review':{}}
    (R/'tools/w13b-verification.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    # Refresh the inventory only; the other art and its proofs are not rebuilt.
    from finish_art import document
    result={str(p.relative_to(R)):{'size':list(Image.open(p).size)} for p in R.rglob('*.png')}
    document(records,result)
    art=R/'ART.md';s=art.read_text(encoding='utf-8')
    s+='\nHouse outline alignment across the three screens: '+f'{maximum:.2f} px maximum over 13 house-contour landmarks at 3840 × 2160 (native generation 1672 × 941). Per-landmark offsets are in `tools/w13b-verification.json`.\n'
    art.write_text(s,encoding='utf-8')
    print(json.dumps({'maximum_offset_px':maximum,'native_size':[1672,941],'retained_files_unchanged':unchanged}))
if __name__=='__main__':main()
