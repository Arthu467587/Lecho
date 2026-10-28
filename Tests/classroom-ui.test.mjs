import {test} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
const read=n=>fs.readFileSync(new URL('../Sources/'+n,import.meta.url),'utf8');
test('both swipe directions expose deletion, trash deletion asks and missing records cannot resave',()=>{
 const s=read('LechoApp.swift'),r=read('ClassReviewView.swift');
 assert.ok(s.includes('.swipeActions(edge: .leading, allowsFullSwipe: false)'));
 assert.ok(s.includes('.swipeActions(edge: .trailing, allowsFullSwipe: false)'));
 assert.ok(s.includes('pendingPermanentDelete'));
 assert.ok(s.includes('library.permanentlyDelete(doc.id)'));
 assert.ok(s.includes('.confirmationDialog("永久删除这节课？"'));
 assert.ok(r.includes('guard let latest = library.documents.first'));
});
test('new-class surfaces have explicit colors and wordmark uses the feather and font fallback',()=>{
 const s=read('LechoApp.swift');
 assert.ok(s.includes('struct PaperClassButtonStyle: ButtonStyle'));
 assert.ok(s.includes('SidebarWordmark()'));
 assert.ok(s.includes('Image("LechoFeather")'));
 assert.ok(s.includes('UIFont(name: "SnellRoundhand-Bold"'));
 assert.ok(s.includes('.tint(ClairTheme.forest).preferredColorScheme(.light)'));
 assert.ok(s.includes('.scrollContentBackground(.hidden).background(ClairTheme.canvas)'));
 assert.equal((s.match(/\.buttonStyle\(PaperClassButtonStyle\(\)\)/g)||[]).length,3,
   'Sidebar, empty state and new-class form all need explicit button colors');
 const asset=new URL('../Sources/Assets.xcassets/LechoFeather.imageset/',import.meta.url);
 const entries=JSON.parse(fs.readFileSync(new URL('Contents.json',asset),'utf8')).images;
 assert.equal(entries.length,3);
 for(const e of entries) assert.ok(fs.existsSync(new URL(e.filename,asset)));
});
