"""Export shared palette/localization resources; run after changing the Swift catalogs."""
from pathlib import Path
import re,json,struct
root=Path(__file__).resolve().parent.parent
output=root/'Windows/AISwitcher.Core/Assets'
output.mkdir(parents=True,exist_ok=True)
for language in ['en','vi']:
    source=(root/f'Sources/AISwitcherCore/Resources/{language}.lproj/Localizable.strings').read_text()
    entries=re.findall(r'^("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*");',source,re.M)
    catalog={json.loads(k):json.loads(v) for k,v in entries}
    extra=json.loads((root/'Windows/Strings.vi.json').read_text())
    catalog.update(extra if language=='vi' else {k:k for k in extra})
    if language=='en':catalog['Windows quick start']='Choose an agent, add a profile, and sign in directly in its own window. ChatGPT and Claude support Desktop profiles; web agents use separate browser profiles. Antigravity uses shared application sign-in. Quota-only connects ChatGPT in the background; disabling returns to cards. Connect is disabled while a profile is running. Closing the manager keeps the system tray available. Right-click the tray icon to show the manager or quit. Ctrl+N adds, Ctrl+K searches, Ctrl+1–9 opens a profile. Settings contains appearance themes, language and executable paths. Claude quota uses Claude Code CLI 2.1.270 or newer with a separate sign-in per profile. Antigravity quota uses official CLI 1.1.12 or newer with shared application sign-in. Quota reads never send a model prompt. Use Sign in with official CLI in quota details if needed.'
    (output/f'{language}.json').write_text(json.dumps(catalog,ensure_ascii=False,indent=2)+'\n')
source=(root/'Sources/AISwitcherCore/AppPreferences.swift').read_text()
names={'light':'Light','dark':'Dark','terminal':'Terminal','code':'Code','dracula':'Dracula','playfulRetro':'Playful Retro Neo-Brutalism','terminalBlack':'Terminal Black','halloween':'Halloween','christmas':'Christmas','tetHoliday':'Tet Holiday','blackFriday':'Black Friday'}
themes=[]
for key,body in re.findall(r'case \.(\w+): return \.init\(([^\n]+)\)',source):
    colors={k:'#'+v.zfill(6).upper() for k,v in re.findall(r'(\w+): 0x([a-fA-F0-9]+)',body)}
    if 'canvas'in colors:themes.append(dict(id=key,name=names[key],dark=key not in ['light','playfulRetro'],mono=key in ['terminal','terminalBlack','code','blackFriday'],retro=key=='playfulRetro',**colors))
(output/'SeasonalScenes.json').write_text((root/'Sources/AISwitcherCore/Resources/SeasonalScenes.json').read_text())
(output/'themes.json').write_text(json.dumps(themes,indent=2)+'\n')
# Reuse the original repository icon as a PNG-backed ICO, without image editing.
png=(root/'docs/assets/icon.png').read_bytes()
width,height=struct.unpack('>II',png[16:24])
if width>256 or height>256:
    # Packaging already generates a 256px original icon from repository drawing code.
    candidate=root/'Windows/AISwitcher.Windows/AppIcon.png'
    png=candidate.read_bytes()
    width,height=struct.unpack('>II',png[16:24])
(root/'Windows/AISwitcher.Windows/AppIcon.ico').write_bytes(struct.pack('<HHH',0,1,1)+struct.pack('<BBBBHHII',width%256,height%256,0,0,1,32,len(png),22)+png)
print(f'Synced {len(themes)} palettes and both localization catalogs.')
