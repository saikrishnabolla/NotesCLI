import Foundation

enum NotesMCPWidget {
    static let html = #"""
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{color-scheme:light dark;font:14px -apple-system,BlinkMacSystemFont,sans-serif}body{margin:0;padding:14px;background:Canvas;color:CanvasText}header{display:flex;align-items:center;gap:9px;margin-bottom:10px}.icon{display:grid;place-items:center;width:30px;height:30px;border-radius:8px;background:#ffd84d;color:#3a3000;font-weight:700}h1{font-size:16px;margin:0}.meta{opacity:.65;font-size:12px}input{box-sizing:border-box;width:100%;margin:0 0 9px;padding:7px 9px;border:1px solid color-mix(in srgb,CanvasText 18%,transparent);border-radius:8px;background:Canvas;color:CanvasText}.items{display:grid;gap:7px}.item{padding:9px 10px;border:1px solid color-mix(in srgb,CanvasText 14%,transparent);border-radius:9px;background:color-mix(in srgb,Canvas 94%,CanvasText 6%)}.title{font-weight:600}.snippet{margin-top:3px;opacity:.72;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.empty{opacity:.65;padding:8px 0}[hidden]{display:none}
</style></head><body><header><div class="icon">N</div><div><h1>Apple Notes</h1><div class="meta" id="meta">Ready</div></div></header><input id="filter" type="search" placeholder="Filter results" aria-label="Filter results" hidden><div id="content" class="empty">Run a Notes tool to see its result.</div>
<script>
const content=document.getElementById('content'),meta=document.getElementById('meta'),filter=document.getElementById('filter');let rows=[];
function candidates(v){if(!v||typeof v!=='object')return[];for(const k of ['notes','items','folders','accounts','tags','attachments'])if(Array.isArray(v[k]))return v[k];return[]}
function label(x){return x.title||x.name||x.path?.join(' › ')||x.id||'Note'}
function item(x){const card=document.createElement('div');card.className='item';const title=document.createElement('div');title.className='title';title.textContent=label(x);card.append(title);if(x.snippet){const snippet=document.createElement('div');snippet.className='snippet';snippet.textContent=String(x.snippet);card.append(snippet)}return card}
function draw(list){meta.textContent=list.length?`${list.length} result${list.length===1?'':'s'}`:'No matches';content.className=list.length?'items':'empty';content.replaceChildren();if(list.length){for(const row of list.slice(0,50))content.append(item(row))}else content.textContent='No matching results.'}
function render(v){rows=candidates(v);filter.hidden=!rows.length;filter.value='';if(rows.length){draw(rows);return}meta.textContent='Result';content.className='empty';content.textContent=v?.message||v?.error?.message||'The tool completed.'}
filter.addEventListener('input',()=>{const q=filter.value.toLowerCase();draw(rows.filter(x=>JSON.stringify(x).toLowerCase().includes(q)))});
addEventListener('message',e=>{const m=e.data||{};if(m.id==='notescli-init'&&m.result){parent.postMessage({jsonrpc:'2.0',method:'ui/notifications/initialized',params:{}},'*');return}if(m.method==='ui/notifications/tool-result')render(m.params?.structuredContent||m.params);const r=m.result||m.params?.result;if(r)render(r.structuredContent||r)});
parent.postMessage({jsonrpc:'2.0',id:'notescli-init',method:'ui/initialize',params:{protocolVersion:'2026-01-26',appInfo:{name:'notescli-widget',version:'1.1.1'},appCapabilities:{availableDisplayModes:['inline']}}},'*');
</script></body></html>
"""#

    static var descriptor: [String: Any] {
        [
            "uri": MCPProtocol.widgetURI,
            "name": "Apple Notes results",
            "description": "Interactive Apple Notes result card.",
            "mimeType": MCPProtocol.appsMIMEType,
        ]
    }

    static var contentMetadata: [String: Any] {
        [
            "ui": [
                "csp": ["connectDomains": [String](), "resourceDomains": [String]()],
                "permissions": [String: Any](),
            ],
        ]
    }
}
