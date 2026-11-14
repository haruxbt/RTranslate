from pathlib import Path
import shutil
root=Path(__file__).resolve().parent.parent
out=root/'work/extension-ui-preview';out.mkdir(parents=True,exist_ok=True)
for src in (root/'SafariExtension/Resources').iterdir():
    if src.is_file():shutil.copy2(src,out/src.name)
shutil.copy2(root/'Tests/Browser/r-translate-mock.js',out/'r-translate-mock.js')
html=(root/'SafariExtension/Resources/popup.html').read_text().replace('<script type="module" src="popup.js">','<script type="module" src="r-translate-mock.js"></script><script type="module" src="popup.js">')
(out/'r-popup-preview.html').write_text(html)
(out/'r-timeline-preview.html').write_text('''<!doctype html><html lang="ja"><meta charset="utf-8"><title>R翻訳 デザイン確認</title><body data-preview="timeline" style="font:20px system-ui;background:#f6f8fa;color:#17213a;padding:60px;max-width:650px"><p style="color:#718099;font-size:13px">表示確認用・音声取得なし</p><h1>CISSP Webinar</h1><p>Risk management and security operations</p><p style="color:#718099;font-size:15px">R翻訳のタイムライン表示を確認しています。</p><script type="module" src="r-translate-mock.js"></script></body></html>''')
print(out)
