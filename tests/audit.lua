-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Run from the plugin root; see tests/README.md for dependencies.
local koreader = assert(os.getenv('KOREADER_ROOT'), 'set KOREADER_ROOT')
local simpleui = assert(os.getenv('SIMPLEUI_ROOT'), 'set SIMPLEUI_ROOT')
package.path = './?.lua;' .. koreader .. '/?.lua;' .. koreader .. '/frontend/?.lua;' .. package.path
local json = require('rapidjson')
local lfs = require('lfs')
local socket = require('socket')
local tmp = os.tmpname(); os.remove(tmp); assert(lfs.mkdir(tmp))
local count = 0
local scheduled, due, shown, log_errors = {}, {}, {}, {}
local Async
local function drain()
    local deadline=socket.gettime()+10
    while Async and Async:isBusy() do
        assert(socket.gettime()<deadline, 'asynchronous task stalled')
        local ready={}
        for fn,when in pairs(due) do if when<=socket.gettime() then ready[#ready+1]=fn end end
        for _,fn in ipairs(ready) do if due[fn] then scheduled[fn]=nil;due[fn]=nil;fn() end end
        socket.sleep(.01)
    end
end
local function eq(a, b) assert(a == b, tostring(a) .. ' ~= ' .. tostring(b)) end
local function test(name, fn)
    scheduled, due = {}, {}
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then error(name .. '\n' .. err, 0) end
    count = count + 1; print('ok ' .. count .. ' - ' .. name)
end
local function put(path, content) local f=assert(io.open(path,'wb')); assert(f:write(content)); assert(f:close()) end
local function read(path) local f=assert(io.open(path,'rb')); local s=f:read('*a'); f:close(); return s end
local function template(s, ...) for i,v in ipairs({...}) do s=s:gsub('%%'..i,tostring(v)) end return s end
local Widget = {}
function Widget:extend(o) return setmetatable(o or {}, {__index=self}) end
function Widget:new(o) return self:extend(o) end
function Widget:switchItemTable(title, items) self.title=title; self.item_table=items end
function Widget:updateItems() end
local UI = {
    show=function(_, widget) shown[#shown+1]=widget end,
    close=function() end, forceRePaint=function() end,
    scheduleIn=function(_, delay, fn) scheduled[fn]=delay;due[fn]=socket.gettime()+delay end,
    unschedule=function(_, fn) scheduled[fn]=nil;due[fn]=nil end,
    nextTick=function(_, fn) scheduled[fn]=0;due[fn]=socket.gettime() end,
    preventStandby=function() end, allowStandby=function() end,
}
local network = { connected=true, runWhenConnected=function(_,fn) fn() end,
    isConnected=function(self) return self.connected end,
    goOnlineToRun=function() return false end }
package.loaded['datastorage']={getDataDir=function() return tmp end,getSettingsDir=function() return tmp end}
package.loaded['libs/libkoreader-lfs']=lfs
package.loaded['docsettings']={getSidecarDir=function(_,p) return p..'.sdr' end}
package.loaded['ui/uimanager']=UI
package.loaded['ui/network/manager']=network
package.loaded['gettext']=function(s) return s end
package.loaded['device']={model='audit'}
package.loaded['version']={getShortVersion=function() return 'v2026.07.2' end}
package.loaded['ffi/util']=nil -- exercise the installed KOReader process and fsync helpers
package.loaded['ffi/utf8proc']={lowercase=string.lower}
package.loaded['util']={fixUtf8=function(s) return s end,splitToChars=function(s) local t={} for c in s:gmatch('.') do t[#t+1]=c end return t end}
package.loaded['logger']={warn=function(...) log_errors[#log_errors+1]={...} end}
package.loaded['infra/sui_core']={getContentHeight=function() return 1000 end,getContentTop=function() return 0 end}
package.loaded['dispatcher']={registerAction=function() end}
package.loaded['apps/reader/readerui']={showReader=function() end}
package.loaded['ui/event']={new=function(_,...) return {...} end}
for _,name in ipairs({'buttondialog','infomessage','menu','inputdialog','confirmbox','container/widgetcontainer'}) do
    package.loaded['ui/widget/'..name]=Widget
end
local log={info=function() end,warn=function() end,error=function() end}
Async=require('st_async')
local Models=require('st_models')
local Config=require('st_config')
local Http=require('st_http')
local Api=require('st_api')
local Auth=require('st_auth')
local Sync=require('st_sync')
local Sidecar=require('st_sidecar')
local Epub=require('st_epub')
local Locator=require('st_locator')
local sha=require('ffi/sha2')
G_reader_settings={readSetting=function() return nil end}
local config=Config:open()
local function link(server)
    assert(config:setServerUrl(server or 'https://example.test'))
    config:saveAuth({access_token='TEST_TOKEN',token_type='bearer'}, {id='user-1',username='test'})
end
link()
local handler
local realTransport=Http.transportFor
function Http:transportFor() return {request=function(req) return handler(req) end} end
local http=Http:new(config,log)
local api=Api:new(http)
local function response(status, body, headers, complete)
    handler=function(req)
        eq(req.redirect,false)
        if body and #body>0 then assert(req.sink(body)) end
        if complete ~= false then assert(req.sink(nil)) end
        return 1,status,headers or {},'HTTP/1.1 '..status
    end
end
local book={uuid='book-1',title='Fixture',createdAt='2026-10-01T01:02:03.000Z',
    authors={{uuid='author-1',name='Author'}},collections={{uuid='collection-1',name='Collection'}},
    series={{uuid='series-1',name='Series',position=1}},status=json.null,position=json.null,
    ebook={uuid='asset-1',filepath='/library/book.epub',missing=false,updatedAt='2026-10-01T01:02:03.000Z'},
    readaloud=json.null}
local function clone(v) return json.decode(json.encode(v)) end

test('all v2 API methods, encoded book IDs, auth flags and body contract',function()
    local requests={};local client=Api:new({request=function(_,args) requests[#requests+1]=args;return {ok=true} end,
        download=function(_,args) requests[#requests+1]=args;return {ok=true} end})
    client:deviceStart();client:deviceToken('code');client:getUser('override');client:listBooks()
    client:listCollections();client:listSeries();client:getBook('b/c');client:getPosition('b/c')
    client:savePosition('b/c',{href='OPS/ch.xhtml',type='application/xhtml+xml'},1234)
    client:downloadFile('b/c','ebook','out')
    local expected={'/device/start','/device/token','/user','/books','/collections','/series','/books/b%2Fc','/books/b%2Fc/positions','/books/b%2Fc/positions','/books/b%2Fc/files?format=ebook'}
    for i,path in ipairs(expected) do eq(requests[i].path,'/api/v2'..path) end
    eq(requests[1].authenticated,false);eq(requests[2].body.device_code,'code');eq(requests[3].token,'override')
    eq(requests[9].body.timestamp,1234);eq(requests[9].handled_statuses[409],true)
end)
test('no invalid empty-resource position is sent',function()
    eq(api:savePosition('b',{href='',type='application/xhtml+xml'},100).kind,'invalid_position')
end)
test('current schema and legacy readaloud availability',function()
    local b={readaloud={uuid='r',filepath='/r.epub',missing=false}}
    eq(Models.selectFormat(b,'ebook'),'readaloud')
    b.readaloud.status='ALIGNED';eq(Models.hasDownloadableFormat(b),true)
    b.readaloud.status='PROCESSING';eq(Models.hasDownloadableFormat(b),false)
    b.readaloud.status=nil;b.readaloud.missing=true;eq(Models.hasDownloadableFormat(b),false)
    b.readaloud.missing=false;b.readaloud.filepath=nil;eq(Models.hasDownloadableFormat(b),false)
end)
test('shared config and changed server revoke old credentials',function()
    local other=Config:open();eq(other,config)
    config:set('server_url','https://other.test');eq(other:isLoggedIn(),false);eq(other:get('access_token'),nil)
    link();config:set('server_url','https://example.test/api/v2/');eq(config:isLoggedIn(),true)
end)
test('URL validation rejects credentials, query, fragment and unsupported scheme',function()
    for _,url in ipairs({'https://user:pass@host','https://host?x=1','https://host/#part','ftp://host','https://bad host'}) do eq(config:normalizeServerUrl(url),nil) end
    eq(config:normalizeServerUrl('server.local:8001/'),'http://server.local:8001')
end)
test('JSON null becomes nil without adding HTTP status to books or arrays',function()
    response(200,json.encode({book}));local result=api:listBooks()
    assert(result.ok);eq(result.data.status,nil);eq(result.data[1].status,nil);eq(result.data[1].position,nil);eq(result.data[1].readaloud,nil)
end)
test('HTML 401 is authentication failure; 403 is permission failure',function()
    response(401,'<html>unauthorized</html>');eq(api:listBooks().kind,'not_authenticated')
    response(403,'<html>forbidden</html>');eq(api:listBooks().kind,'permission_denied')
end)
test('204/404/409 and device polling errors keep endpoint semantics',function()
    response(204,'');assert(api:savePosition('b',{href='c.xhtml',type='application/xhtml+xml'},123).ok)
    response(404,'{"message":"No position found"}');eq(api:getPosition('b').kind,'handled_error')
    response(409,'{"message":"Conflict"}');eq(api:savePosition('b',{href='c.xhtml',type='application/xhtml+xml'},123).kind,'handled_error')
    response(400,'{"error":"authorization_pending"}');eq(api:deviceToken('code').data.error,'authorization_pending')
end)
test('transport failure and timeout cannot appear successful',function()
    handler=function() return nil,'timeout' end;eq(api:listBooks().kind,'timeout')
    handler=function() return nil,200,{} end;eq(api:listBooks().kind,'network_error')
    handler=function() error('socket failure') end;eq(api:listBooks().kind,'network_error')
end)
local download=tmp..'/download.epub'
local bytes='PK\003\004fixture ebook bytes'
local headers={['Content-Type']='application/epub+zip',['Content-Length']=tostring(#bytes),['X-Storyteller-Hash']=sha.sha256(bytes)}
test('complete download verified against actual SHA-256 bytes',function()
    response(200,bytes,headers);assert(api:downloadFile('b','ebook',download).ok);eq(read(download),bytes)
end)
for _,case in ipairs({
    {'truncated length',200,bytes:sub(1,-2),headers,true,'incomplete_download'},
    {'partial response',206,bytes,headers,true,'http_error'},
    {'hash mismatch',200,bytes,{['X-Storyteller-Hash']=string.rep('0',64)},true,'hash_mismatch'},
    {'missing hash',200,bytes,{},true,'hash_mismatch'},
    {'unclosed response',200,bytes,headers,false,'incomplete_download'},
    {'empty file',200,'',headers,true,'empty_download'},
    {'HTML login page',200,'login',{['Content-Type']='text/html'},true,'unexpected_content_type'},
    {'permission denied',403,'',{},true,'permission_denied'},
}) do test('reject download: '..case[1],function()
    response(case[2],case[3],case[4],case[5]);eq(api:downloadFile('b','ebook',download).kind,case[6]);eq(lfs.attributes(download),nil)
end) end

test('device polling handles pending, slow_down, denial and server changes',function()
    local plugin={config=config,api=api,log=log};local auth=Auth:new(plugin)
    auth.device_code='code';auth.server_url=config:get('server_url');auth.expires_at=os.time()+100
    response(400,'{"error":"authorization_pending"}');auth:poll();drain();eq(scheduled[auth.task],5)
    response(400,'{"error":"slow_down"}');auth:poll();drain();eq(scheduled[auth.task],10)
    response(400,'{"error":"access_denied"}');auth:poll();drain();eq(auth.device_code,nil)
    auth.device_code='code';auth.server_url='https://old.test';handler=function() error('must not send old device code') end
    auth:poll();drain();eq(auth.device_code,nil)
end)
test('successful link verifies user before saving token',function()
    local auth=Auth:new({config=config,log=log,api={getUser=function(_,token) eq(token,'NEW_TOKEN');return {ok=true,data={id='user-1'}} end}})
    auth:onToken({access_token='NEW_TOKEN'});eq(config:get('access_token'),'NEW_TOKEN');link()
end)
local local_book=tmp..'/fixture.epub';put(local_book,bytes)
local sidecar=Sidecar:build(config,local_book,book,'ebook',sha.sha256(bytes));assert(Sidecar:writeFull(local_book,sidecar))
local function payload(p,t) return {timestamp=t,locator={href='OPS/ch.xhtml',type='application/xhtml+xml',locations={totalProgression=p}}} end
local plugin={config=config,log=log,api=api,ui={document={file=local_book,info={has_pages=false},getCurrentPage=function() return 10 end}}}
local sync=Sync:new(plugin)
test('newer server rewind wins over farther local progress',function()
    eq(sync:remoteDecision({last_sync_timestamp=100},payload(.8,200),payload(.2,300)),'remote_newer')
end)
test('pre-push check preserves original local reading timestamp',function()
    response(200,json.encode(payload(.1,100)));local p=payload(.8,200)
    assert(sync:checkRemoteBeforeLocalPush({book_uuid='b',last_sync_timestamp=100},p));eq(p.timestamp,200)
end)
test('409 is never retried automatically with a new timestamp',function()
    response(200,json.encode(payload(.1,300)))
    local prompted=false;local old=sync.showConflict;sync.showConflict=function() prompted=true end
    eq(sync:handleSaveConflict({book_uuid='b',last_sync_timestamp=100},local_book,payload(.8,200)),false)
    assert(prompted);sync.showConflict=old
end)
test('expired debounce never schedules a zero-delay retry',function()
    sync.active=true;sync.pending_progress_payload=payload(.5,100);sync.pending_progress_dirty_since=1;sync.last_auto_push_timestamp=0
    sync:schedulePush();assert(scheduled[sync.progress_push_task]>=1)
end)
test('offline close persists position and reopening restores its original timestamp',function()
    sync.active=true;sync.filepath=local_book;sync.sidecar=sidecar;sync.pending_progress_payload=payload(.5,200)
    network.connected=false;sync:onCloseDocument();eq(Sidecar:read(local_book).pending_position.timestamp,200)
    sync:startAuto();eq(sync.pending_progress_payload.timestamp,200);eq(sync.last_page,10)
    network.connected=true
end)
test('acknowledged sync clears persisted pending position',function()
    assert(Sidecar:updateSyncFields(local_book,300,'local_push',payload(.5,300).locator))
    eq(Sidecar:read(local_book).pending_position,nil)
end)
test('same-size local replacement cannot sync under another book identity',function()
    local p=tmp..'/replaced.epub';put(p,bytes)
    local sc=Sidecar:build(config,p,book,'ebook',sha.sha256(bytes));assert(Sidecar:writeFull(p,sc))
    put(p,string.rep('X',#bytes));local valid,_,reason=Sidecar:validate(p,config)
    eq(valid,false);eq(reason,'hash_mismatch')
end)
test('sidecar blocks wrong identity, changed file and changed server asset',function()
    assert(Sidecar:validate(local_book,config));assert(Sidecar:assetFresh(sidecar,book))
    local b=clone(book);b.ebook.updatedAt='new';eq(Sidecar:assetFresh(sidecar,b),false)
    config:set('user_id','different');eq(Sidecar:validate(local_book,config),false);config:set('user_id','user-1')
    put(local_book,bytes..'changed');eq(Sidecar:validate(local_book,config),false);put(local_book,bytes)
end)
local files={
 ['META-INF/container.xml']='<container><rootfiles><rootfile full-path="OPS/content.opf"/></rootfiles></container>',
 ['OPS/content.opf']='<package><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml"/><item id="c" href="Text/ch 1.xhtml" media-type="application/xhtml+xml" media-overlay="smil"/><item id="smil" href="Audio/ch.smil" media-type="application/smil+xml"/></manifest><spine><itemref idref="nav" linear="no"/><itemref idref="c"/></spine></package>',
 ['OPS/nav.xhtml']='<html><body>Nav</body></html>',
 ['OPS/Text/ch 1.xhtml']='<html><body><p id="a">Hello world.</p><p id="b">Second line.</p></body></html>',
 ['OPS/Audio/ch.smil']='<smil><body><par><text src="../Text/ch%201.xhtml#a"/></par><par><text src="../Text/ch%201.xhtml#b"/></par></body></smil>',
}
local doc={getDocumentFileContent=function(_,p) return files[p] end,getNormalizedXPointer=function(_,p) return p end}
test('EPUB locators use publication paths, preserve nonlinear spine indices and SMIL fragments',function()
    local locator=Epub:xpointerToLocator(doc,'/body/DocFragment[2]/body/p[2]/text().2',.6,'readaloud')
    eq(locator.href,'OPS/Text/ch 1.xhtml');eq(locator.locations.fragments[1],'b');eq(locator.locations.totalProgression,.6)
    local xp,precise=Epub:locatorToXPointer(doc,locator);assert(xp:find('DocFragment[2]',1,true));eq(precise,true)
end)
test('URL-encoded upstream resource hrefs resolve to the correct chapter',function()
    local index=Epub:resolveHref(doc,'/api/v2/books/b/read/OPS/Text/ch%201.xhtml#b');eq(index,1)
end)
test('Readium encoded fragment href restores through its fragment',function()
    local xp,precise,diagnostic=Epub:locatorToXPointer(doc,{href='OPS/Text/ch%201.xhtml%23b',type='application/xhtml+xml'})
    assert(xp);eq(precise,true);eq(diagnostic.method,'fragment')
    eq(Epub:resolveHref(doc,'1.xhtml'),nil)
end)
test('invalid XPointer falls back to an actual publication resource',function()
    local ui={document=doc,rolling={getLastPercent=function() return .5 end,getLastProgress=function() return 'unknown' end}}
    doc.info={has_pages=false};local p=Locator:build(ui,{format='ebook'},100);eq(p.locator.href,'OPS/Text/ch 1.xhtml')
end)
local Downloader=require('st_downloader')
local opened
local dl=Downloader:new(plugin)
local originalFind,originalDir,originalSelect=dl.findExisting,dl.defaultDir,dl.selectAndOpen
function dl:findExisting() return nil,'missing' end
function dl:defaultDir() return tmp end
function dl:selectAndOpen(b) opened=b.uuid end
local function libraryHandler(req)
    local path=req.url:match('https://example.test(.*)')
    local data=path=='/api/v2/books' and {book,{uuid='readaloud-book',title='Readaloud',authors={},collections={},series={},status=json.null,position=json.null,readaloud={uuid='r',filepath='/r.epub',missing=false}}}
        or path=='/api/v2/collections' and {{uuid='collection-1',name='Collection'}}
        or path=='/api/v2/series' and {{uuid='series-1',name='Series'}}
    assert(data,path);assert(req.sink(json.encode(data)));assert(req.sink(nil));return 1,200,{}
end
package.loaded['apps/filemanager/filemanager']={instance={storyteller={config=config,api=api,downloader=dl}}}
local screen=dofile(simpleui..'/screens/sui_storyteller.lua')
test('actual SimpleUI Storyteller page loads nullable v3 books and every shelf',function()
    handler=libraryHandler;screen.show();drain();assert(screen._instance)
    local menu=screen._instance
    for _,key in ipairs({'open_currently_reading','open_recently_added','open_all_books','open_collections','open_series','open_authors'}) do
        menu:onMenuSelect({[key]=true});assert(menu.item_table[1].back);menu:onMenuSelect({back=true})
    end
    menu:onMenuSelect({open_all_books=true});eq(#menu.item_table,3)
    menu:onMenuSelect(menu.item_table[2]);eq(opened,'book-1');eq(#log_errors,0)
end)
test('SimpleUI fallback uses the same live settings without a FileManager instance',function()
    package.loaded['apps/filemanager/filemanager']=nil;handler=libraryHandler;screen.show();drain();assert(screen._instance)
    screen._instance:onMenuSelect({open_all_books=true});eq(#screen._instance.item_table,3);eq(#log_errors,0)
end)
test('standalone Storyteller browser shares current library and shelf contracts',function()
    handler=libraryHandler;plugin.downloader=dl
    local browser=require('st_browser'):new(plugin);browser:open();drain();eq(#browser.books,2)
    for _,item in ipairs(browser:rootItems()) do item.callback() end
end)
test('logs redact token, device code, headers and nested credentials',function()
    local logger=require('st_log');logger:setConfig(config)
    logger:warn('audit_redaction',{access_token='SECRET',headers={Authorization='SECRET'},data={device_code='SECRET'}})
    local output=read(tmp..'/storyteller.log');assert(not output:find('SECRET',1,true));assert(output:find('REDACTED',1,true))
end)
test('upstream oversized expiry is ignored and ordinary millisecond expiry is retained',function()
    eq(config:computeTokenExpiresAt(9999999999999999),nil)
    local now=config:nowMs();local expires=config:computeTokenExpiresAt(60000)
    assert(expires>=now+60000 and expires<now+61000)
end)
test('plugin main initializes with KOReader menu and dispatcher contracts',function()
    local Main=dofile('main.lua');local p=Main:new{ui={menu={registerToMainMenu=function() end}}};p:init();eq(p.config,config);assert(p.api and p.auth and p.sync and p.browser and p.downloader)
end)
local Storage=require('st_storage')
local ffiutil=require('ffi/util')
test('checked settings writes preserve the previous file when storage fails',function()
    local path=tmp..'/atomic.lua';assert(Storage:write(path,{value='old'}))
    local original=ffiutil.fsyncOpenedFile
    ffiutil.fsyncOpenedFile=function() return false,'injected failure' end
    local ok,reason=Storage:write(path,{value='new'})
    ffiutil.fsyncOpenedFile=original
    eq(ok,false);eq(reason,'sync_failed');eq(dofile(path).value,'old')
    eq(lfs.attributes(path..'.storyteller-writing'),nil)
end)
test('checked settings writes detect open, write, flush, close and rename failure',function()
    for _,failure in ipairs({'open','write','flush','close','rename'}) do
        local path=tmp..'/fault-'..failure..'.lua';assert(Storage:write(path,{value='old'}))
        local open,rename=io.open,os.rename
        io.open=function(name,mode)
            if name~=path..'.storyteller-writing' then return open(name,mode) end
            if failure=='open' then return nil,'injected' end
            local f=assert(open(name,mode))
            return {
                write=function(_,...) if failure=='write' then return nil end return f:write(...) end,
                flush=function() if failure=='flush' then return nil end return f:flush() end,
                close=function() local ok=f:close();if failure=='close' then return nil end return ok end,
                file=f,
            }
        end
        local fsync=ffiutil.fsyncOpenedFile
        ffiutil.fsyncOpenedFile=function(f) return fsync(f.file or f) end
        os.rename=function(src,dest) if failure=='rename' and dest==path then return nil end return rename(src,dest) end
        local ok=Storage:write(path,{value='new'})
        io.open,os.rename,ffiutil.fsyncOpenedFile=open,rename,fsync
        eq(ok,false);eq(dofile(path).value,'old')
    end
end)
test('failed pending-position save reports failure and remains retryable in memory',function()
    local write=Storage.write
    Storage.write=function() return false,'injected' end
    eq(Sidecar:setPendingPosition(local_book,payload(.6,600)),false)
    eq(Sidecar:read(local_book).pending_position.timestamp,600)
    Storage.write=write
    eq(Sidecar:read(local_book).pending_position.timestamp,600)
    eq(dofile(Sidecar:pathFor(local_book)).pending_position.timestamp,600)
end)
test('successful network push retains acknowledgement when local save fails',function()
    local state=Sync:new(plugin);state.active=true;state.filepath=local_book;state.sidecar=sidecar
    state.pending_progress_payload=payload(.6,600)
    local write=Storage.write;Storage.write=function() return false,'injected' end
    eq(state:recordLocalPushSuccess(local_book,sidecar,state.pending_progress_payload),false)
    assert(state.pending_ack);assert(state:hasPendingProgress())
    Storage.write=write
    assert(state:recordLocalPushSuccess(local_book,sidecar,state.pending_progress_payload))
    eq(state.pending_ack,nil);eq(state:hasPendingProgress(),false)
end)
test('a page turn during a request survives acknowledgement of the earlier position',function()
    local state=Sync:new(plugin);state.active=true;state.filepath=local_book;state.sidecar=sidecar
    state.progress_revision=2;local newer=payload(.7,700);newer.local_revision=2;state.pending_progress_payload=newer
    local sent=payload(.6,600);sent.local_revision=1
    assert(state:recordLocalPushSuccess(local_book,sidecar,sent))
    eq(state.pending_progress_payload,newer);eq(Sidecar:read(local_book).pending_position.timestamp,700)
end)
test('failed journal creation never replaces the previous EPUB',function()
    local path=tmp..'/transaction.epub';put(path,'original');put(path..'.storyteller.tmp',bytes)
    local data=Sidecar:build(config,path..'.storyteller.tmp',book,'ebook',sha.sha256(bytes))
    local write=Storage.write;Storage.write=function() return false,'injected' end
    eq(Sidecar:commitDownload(path,path..'.storyteller.tmp',data),false)
    Storage.write=write;eq(read(path),'original')
end)
test('interrupted metadata commit recovers across a fresh module load',function()
    local path=tmp..'/recover.epub';put(path,'original');put(path..'.storyteller.tmp',bytes)
    local data=Sidecar:build(config,path..'.storyteller.tmp',book,'ebook',sha.sha256(bytes))
    local write=Storage.write;local metadata=Sidecar:pathFor(path)
    Storage.write=function(self,p,d) if p==metadata then return false,'injected' end return write(self,p,d) end
    local ok,reason=Sidecar:commitDownload(path,path..'.storyteller.tmp',data)
    Storage.write=write;eq(ok,false);eq(reason,'metadata_pending');eq(read(path),bytes)
    assert(lfs.attributes(metadata..'.pending'))
    local fresh=dofile('st_sidecar.lua');assert(fresh:validate(path,config));eq(lfs.attributes(metadata..'.pending'),nil)
end)
test('an interruption before the EPUB rename preserves old metadata and book',function()
    local path=tmp..'/before-rename.epub';put(path,'original')
    local old=Sidecar:build(config,path,book,'ebook',sha.sha256('original'));assert(Sidecar:writeFull(path,old))
    put(path..'.storyteller.tmp',bytes)
    local data=Sidecar:build(config,path..'.storyteller.tmp',book,'ebook',sha.sha256(bytes))
    assert(Storage:write(Sidecar:pathFor(path)..'.pending',data))
    local fresh=dofile('st_sidecar.lua');assert(fresh:validate(path,config));eq(read(path),'original')
    eq(fresh:read(path).downloaded_hash,old.downloaded_hash)
end)
test('actual worker waits leave UI callbacks runnable',function()
    handler=function(req) socket.sleep(.25);req.sink('{}');req.sink(nil);return 1,200,{} end
    local completed,heartbeat=false,false
    local started=socket.gettime()
    api:run(function() assert(api:listBooks().ok);completed=true end)
    assert(socket.gettime()-started<.2);eq(completed,false)
    UI:scheduleIn(.02,function() heartbeat=true end)
    drain();eq(heartbeat,true);eq(completed,true)
end)
test('cancelled worker never applies its result',function()
    handler=function(req) socket.sleep(2);req.sink('{}');req.sink(nil);return 1,200,{} end
    local applied=false;local owner={}
    api:run(function() api:listBooks();applied=true end,{owner=owner,key='cancel'})
    UI:scheduleIn(.02,function() api:cancel(owner) end)
    drain();eq(applied,false)
end)
test('a response from a previous account is discarded',function()
    handler=function(req) socket.sleep(.25);req.sink('{}');req.sink(nil);return 1,200,{} end
    local applied=false
    api:run(function() api:listBooks();applied=true end)
    UI:scheduleIn(.02,function() config:set('access_token','OTHER_TOKEN') end)
    drain();eq(applied,false);link()
end)
test('reader generation changes cancel old requests before applying results',function()
    handler=function(req) socket.sleep(.25);req.sink('{}');req.sink(nil);return 1,200,{} end
    local state=Sync:new(plugin);local applied=false
    state:runNetwork(function() api:listBooks();applied=true end)
    UI:scheduleIn(.02,function() state.generation=state.generation+1 end)
    drain();eq(applied,false)
end)
test('queued reader work runs after an existing task without blocking the UI',function()
    handler=function(req) socket.sleep(.15);req.sink('{}');req.sink(nil);return 1,200,{} end
    local state=Sync:new(plugin);local first,second=false,false
    state:runNetwork(function() api:listBooks();first=true end)
    state:runNetwork(function() api:listBooks();second=true end)
    local deadline=socket.gettime()+5
    while not second do
        assert(socket.gettime()<deadline)
        local ready={};for fn,when in pairs(due) do if when<=socket.gettime() then ready[#ready+1]=fn end end
        for _,fn in ipairs(ready) do if due[fn] then due[fn]=nil;scheduled[fn]=nil;fn() end end
        socket.sleep(.01)
    end
    eq(first,true);drain()
end)
test('manual network work queued behind auto-sync is not discarded',function()
    handler=function(req) socket.sleep(.15);req.sink('{}');req.sink(nil);return 1,200,{} end
    local state=Sync:new(plugin);local second=false
    state:runNetwork(function() api:listBooks() end)
    state:whenConnected(function() api:listBooks();second=true end)
    local deadline=socket.gettime()+5
    while not second do
        assert(socket.gettime()<deadline)
        local ready={};for fn,when in pairs(due) do if when<=socket.gettime() then ready[#ready+1]=fn end end
        for _,fn in ipairs(ready) do if due[fn] then due[fn]=nil;scheduled[fn]=nil;fn() end end
        socket.sleep(.01)
    end
    drain()
end)
test('task cleanup closes each dialog only once, including external dismissal',function()
    local original=UI.close;local closes=0
    UI.close=function(_,widget) closes=closes+1;if widget.onCloseWidget then widget:onCloseWidget() end end
    api:run(function()
        local widget={};local close=Async:trackWidget(widget);close();close()
    end)
    eq(closes,1)
    api:run(function() local widget={};Async:trackWidget(widget);UI:close(widget) end)
    eq(closes,2);UI.close=original
end)
test('closing SimpleUI while its library is loading cancels the response',function()
    handler=function(req) socket.sleep(.2);return libraryHandler(req) end
    package.loaded['apps/filemanager/filemanager']={instance={storyteller={config=config,api=api,downloader=dl}}}
    screen.show();local menu=screen._instance;local items=menu.item_table
    UI:scheduleIn(.02,function() menu.onCloseWidget() end)
    drain();eq(screen._instance,nil);eq(menu.item_table,items)
end)
test('updated SimpleUI still supports a companion without the async entry point',function()
    api.run=false;handler=libraryHandler;screen.show();assert(screen._instance)
    screen._instance:onMenuSelect({open_all_books=true});eq(#screen._instance.item_table,3)
    api.run=nil
end)
test('cancelling a download removes partial bytes and preserves the previous book',function()
    handler=function(req)
        if req.url:find('/files?',1,true) then req.sink(bytes);socket.sleep(2);req.sink(nil);return 1,200,headers end
        req.sink(json.encode(book));req.sink(nil);return 1,200,{}
    end
    local downloader=Downloader:new(plugin);local dest=tmp..'/cancelled.epub';put(dest,'original')
    downloader:download(book,'ebook',dest,true)
    UI:scheduleIn(.3,function() api:cancel(downloader) end)
    drain();eq(read(dest),'original');eq(lfs.attributes(dest..'.storyteller.tmp'),nil)
end)
test('suspending cancels a request while retaining unsent progress',function()
    handler=function(req) socket.sleep(.5);req.sink('{}');req.sink(nil);return 1,200,{} end
    local state=Sync:new(plugin);state.active=true;state.filepath=local_book;state.sidecar=sidecar
    state.pending_progress_payload=payload(.6,666);local applied=false
    state:runNetwork(function() api:listBooks();applied=true end)
    UI:scheduleIn(.02,function() state:onSuspend() end)
    drain();eq(applied,false);eq(Sidecar:read(local_book).pending_position.timestamp,666)
end)
test('intentional backward-progress protection remains in place',function()
    eq(sync:remoteDecision({last_sync_timestamp=100},payload(.2,200),payload(.8,100)),'remote_ahead')
end)
test('15-second suppression remains unchanged',function()
    local apply=Locator.apply;Locator.apply=function() return true,true,{} end
    local state=Sync:new(plugin);state.active=true;state.filepath=local_book;state.sidecar=sidecar;state.last_page=10
    assert(state:applyRemote(payload(.5,500),local_book));eq(scheduled[state.remote_apply_release_task],15)
    state:onPageUpdate(11);eq(state:hasPendingProgress(),false)
    Locator.apply=apply
end)
Http.transportFor=realTransport
local server=os.getenv('AUDIT_SERVER')
if server then
    link(server)
    test('real HTTP device linking, user verification and nullable book list',function()
        local start=api:deviceStart();assert(start.ok);eq(start.data.device_code,'device-code')
        local token=api:deviceToken(start.data.device_code);assert(token.ok)
        local user=api:getUser(token.data.access_token);assert(user.ok);eq(user.data.id,'user-1')
        local list=api:listBooks();assert(list.ok);eq(list.data[1].status,nil)
    end)
    test('real HTTP position lifecycle and equal-timestamp conflict',function()
        local no=api:getPosition('wire-book');eq(no.status,404)
        local p=payload(.8,1000);assert(api:savePosition('wire-book',p.locator,p.timestamp).ok)
        eq(api:getPosition('wire-book').data.timestamp,1000)
        eq(api:savePosition('wire-book',payload(.2,1000).locator,1000).status,409)
        eq(api:savePosition('wire-book',p.locator,999).status,409)
        assert(api:savePosition('wire-book',p.locator,1000).ok)
    end)
    test('real HTTP streamed EPUB with checksum and download metadata checks',function()
        local result=api:downloadFile('wire-book','ebook',download);assert(result.ok,result.kind)
        eq(sha.sha256(read(download)),result.downloaded_hash)
        local actual=Downloader:new(plugin);actual.downloaded=function(_,p) opened=p end
        local dest=tmp..'/downloaded.epub';actual:download({uuid='wire-book'},'ebook',dest,false);drain()
        eq(opened,dest);assert(Sidecar:validate(dest,config))
    end)
    test('closing the reader finishes a captured upload without accessing the closed document',function()
        local dest=tmp..'/downloaded.epub'
        assert(Sidecar:updateSyncFields(dest,1000,'local_push',payload(.8,1000).locator))
        local ui={document={file=dest,info={has_pages=false}}}
        local state=Sync:new{config=config,api=api,log=log,ui=ui}
        state.active=true;state.filepath=dest;state.sidecar=Sidecar:read(dest);state.pending_progress_payload=payload(.9,2000)
        state:onCloseDocument();api:cancel();ui.document=nil;drain()
        eq(api:getPosition('wire-book').data.timestamp,2000)
        eq(Sidecar:read(dest).pending_position,nil)
    end)
    test('real HTTP truncation, redirect and permission responses are rejected',function()
        eq(api:downloadFile('truncated','ebook',download).ok,false);eq(lfs.attributes(download),nil)
        eq(api:downloadFile('redirect','ebook',download).status,302);eq(lfs.attributes(download),nil)
        eq(api:getBook('forbidden').kind,'permission_denied')
    end)
    test('server asset change during transfer never replaces a local book',function()
        local actual=Downloader:new(plugin);actual.downloaded=function() error('changed asset accepted') end
        local dest=tmp..'/kept.epub';put(dest,'old local content')
        actual:download({uuid='changing'},'ebook',dest,true);drain()
        eq(read(dest),'old local content');eq(lfs.attributes(dest..'.storyteller.tmp'),nil)
    end)
end
print(string.format('PASS: %d tests (UI mocked; real KOReader process, settings, socketutil and SHA-256 helpers)',count))
-- Only this test run's generated data is removed.
local function cleanup(dir) for name in lfs.dir(dir) do if name~='.' and name~='..' then local p=dir..'/'..name;if lfs.attributes(p,'mode')=='directory' then cleanup(p) else os.remove(p) end end end assert(lfs.rmdir(dir)) end
cleanup(tmp)
