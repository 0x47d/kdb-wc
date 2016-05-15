# <kdb-connect srvUser="u" srvPass="p" target="h" query="starting sequence"/>
(() ->
  try
    new CustomEvent 'test'
  catch
    CE = (event, params) ->
      params = params ||  bubbles: false, cancelable: false, detail: undefined
      evt = document.createEvent 'CustomEvent'
      evt.initCustomEvent(event, params.bubbles, params.cancelable, params.detail)
      return evt
    CE.prototype = window.CustomEvent.prototype
    window.CustomEvent = CE
)()

extractInfo = (v) ->
  return v if typeof v is 'string'
  txt = ''
  if v.nodeName is 'SELECT'
    txt = v.options[v.selectedIndex].text
  else if v.nodeName is 'INPUT'
    if v.type is 'checkbox'
      txt = if v.checked then '1b' else '0b'
    else if v.type is 'radio'
      txt = v.form.querySelector("input[type='radio'][name='#{v.name}']:checked")?.value || ''
    else
      txt = v?.value || 'unsupported'
  else if v.nodeName is 'TEXTAREA'
    txt = v.value
  else
    txt = v.textContent
  txt

class _KDBSrv extends HTMLElement
  createdCallback: ->
    @srvType = @attributes['k-srv-type']?.textContent || "http"
    @target = @attributes['k-target']?.textContent || null
    @wsSrv = @attributes['k-srv-uri']?.textContent || location.host
    @srvUser = @attributes['k-srv-user']?.textContent || null
    @srvPass = @attributes['k-srv-pass']?.textContent || null
    @qPrefix = @attributes['k-prefix']?.textContent || ""
    @debug = @attributes['debug']?.textContent || null
    @rType = @attributes['k-return-type']?.textContent || "json"
    @fixJson = @attributes['fix-json']?.textContent || null
    @kFeed = (@attributes['k-feed']?.textContent || "false") is "true"
    @hidden = true
    @ws = @wsReq = null
    @wsQueue = []
    console.log "kdb-srv inited: srvType:#{@srvType}, target:#{@target}, prefix:#{@qPrefix}, rType:#{@rType}" if @debug
    if @target
      @target = (document.querySelector "[k-id='#{@target}']") || @target
  runQuery: (q,cb) ->
    (cb = (r,e) -> null) unless cb
    return @sendHTTP q,cb if @srvType is 'http'
    @sendWS q,cb
  sendWS: (qq,clb) ->
    @wsQueue.push q:qq, cb:clb
    if !@ws
      @ws = new WebSocket("ws://#{@wsSrv}/")
      @ws.binaryType = 'arraybuffer'
      @ws.onopen = =>
        console.log "kdb-srv-ws: opened" if @debug
        @processWSQueue()
      @ws.onclose = =>
        console.log "kdb-srv-ws: closed" if @debug
        @ws = null
        @sendWSRes null,'closed'
      @ws.onerror = (e) =>
        console.log "kdb-srv-ws: error #{e.data}" if @debug
        @sendWSRes null,e.data
      @ws.onmessage = (e) =>
        console.log "kdb-srv-ws: msg" if @debug
        try
          res = if @rType is "json" and typeof e.data is 'string' then JSON.parse e.data else if typeof e.data is 'object' then deserialize(e.data) else e.data
        catch error
          console.log "kdb-srv-ws: exception in ws parse #{error}" if @debug
          return @sendWSRes null, "result parse error: "+error.toString()
        @sendWSRes res, null
      return
    @processWSQueue() if @ws.readyState is 1
  sendWSRes: (r,e) ->
    return unless req=@wsReq
    @wsReq = null unless @kFeed
    try
      req.cb r,e
    catch err
      console.log "kdb-srv-ws: exception in callback"
      console.log err
    @processWSQueue()
  processWSQueue: ->
    return if @wsReq or @wsQueue.length is 0
    @wsReq = @wsQueue.shift()
    req = @wsReq.q
    req = @qPrefix + req if typeof req is 'string' and @qPrefix
    req = "%target=#{extractInfo @target}%" + req if @target
    if @rType is 'q'
      try
        req = ' '+req if typeof req is 'string' and req[0] is '`' # compensate the strange behavior of serialize
        req = serialize req
      catch error
        console.log "kdb-srv-ws: exception in ws send #{error}" if @debug
        return @sendWSRes null,'send'
    return @ws.send req if @ws and @ws.readyState is 1
    @sendWS @wsReq.q,@wsReq.cb
    @wsReq = null
  sendHTTP: (q,cb) ->
    if @fixJson and !@target
      @fixJson = null
      @qPrefix = "jsn?enlist " unless @qPrefix
      return @runQuery "{.h.tx[`jsn]:(.j.j');1}[]", (r,e) => @runQuery q, cb
    @qPrefix = "json?enlist " if !@qPrefix and @srvType is "http" and @rType is "json"
    xhr = new XMLHttpRequest()
    xhr.onerror = =>
      console.log "kdb-srv error: "+xhr.statusText if @debug
      cb null, xhr.statusText
    xhr.ontimeout = =>
      console.log "kdb-srv timeout" if @debug
      cb null, "timeout"
    xhr.onload = =>
      return xhr.onerror() unless xhr.status is 200
      console.log "kdb-srv data: "+xhr.responseText.slice(0,50) if @debug
      try
        res = if @rType is "json" then JSON.parse xhr.responseText else if @rType is "xml" then xhr.responseXML else xhr.responseText
      catch error
        console.log "kdb-srv: exception in JSON.parse" if @debug
        return cb null, "JSON.parse error: "+error.toString()
      try
        cb res, null
      catch err
        console.log "kdb-srv: HTTP callback exception"
        console.log err
    q = @qPrefix + encodeURIComponent q
    q = q + "&target=" + extractInfo @target if @target
    console.log "kdb-srv sending request:"+q if @debug
    xhr.open 'GET', q, true, @srvUser, @srvPass
    xhr.send()

class _KDBQuery extends HTMLElement
  createdCallback: ->
    @hidden = true
    @setupQuery()
  setupQuery: ->
    prvExec = @exec
    clearTimeout @ktimer if @ktimer
    @ktimer = null
    @iterationNumber = 0
    @query = @attributes['k-query']?.textContent || @textContent
    @srv = @attributes['k-srv']?.textContent || ""
    @exec = @attributes['k-execute-on']?.textContent.split(' ').filter((e)-> e.length > 0) || ["load"]
    @debug = @attributes['debug']?.textContent || null
    @escapeQ = @attributes['k-escape-q']?.textContent || ""
    @updObjs = @attributes['k-update-elements']?.textContent.split(' ').filter((e)-> e.length > 0) || []
    @kInterval = @attributes['k-interval']?.textContent || "0"
    @kInterval = if Number.parseInt then Number.parseInt @kInterval else Number @kInterval
    @kDelay = @attributes['k-delay']?.textContent || "0"
    @kDelay = if Number.parseInt then Number.parseInt @kDelay else Number @kDelay
    if @kFilter = @attributes['k-filter']?.textContent
      @kFilter = @kFilter.split(".").reduce ((x,y) -> return x[y]), window
    @result = null
    if 'load' in @exec and (!prvExec or !('load' in prvExec))
      if document.readyState in ['complete','interactive']
        setTimeout (=> @runQuery()), 100
      else
        document.addEventListener "DOMContentLoaded", (ev) => @runQuery()
    for el in @exec when !(el in ['load','manual','timer'])
      @addUpdater v if v = document.querySelector "[k-id='#{el}']"
    @kRefs = @query.match(/\$\w+\$/g)?.map (e) -> e.slice 1,e.length-1
    @kMap = null
    if 'timer' in @exec
      setTimeout (=> @rerunQuery()), if @kDelay then @kDelay else @kInterval
    console.log "kdb-query inited: srv:#{@srv}, query:#{@query}, executeOn:#{@exec}, updateObs:#{@updObjs}, refs:#{@kRefs}, delay:#{@kDelay}, interval:#{@kInterval}" if @debug
  rerunQuery: ->
    @result = null
    @runQuery()
  runQuery: ->
    return if @result
    if typeof @srv is 'string'
      @srv = if @srv is "" then document.getElementsByTagName("kdb-srv")?[0] else document.querySelector "[k-id='#{@srv}']"
    console.log "kdb-query: executing query" if @debug
    @srv.runQuery @resolveRefs(@query), (r,e) =>
      @iterationNumber += 1
      console.log "kdb-query: got response with status #{e}" if @debug
      if !e
        r = (if typeof @kFilter is 'object' then @kFilter.filter r else @kFilter r) if @kFilter
        @result = r
        @sendEv()
        @updateObjects()
      setTimeout (=> @rerunQuery()), @kInterval if @kInterval and 'timer' in @exec
  sendEv: -> @dispatchEvent @getEv() if @result
  getEv: ->
    new CustomEvent "newResult",
      detail: @result
      bubbles: true
      cancelable: true
  onresult: (f) ->
    @addEventListener 'newResult', f
    f @getEv() if @result
  addUpdater: (v) ->
    if v.nodeName is 'BUTTON'
      v.addEventListener 'click', (ev) => @rerunQuery()
    else
      v.addEventListener 'click', (ev) => @kLastEvent = ev; @rerunQuery()
  updateObjects: -> @updateObj document.querySelector "[k-id='#{o}']" for o in @updObjs
  updateObj: (o) ->
    return unless o
    if o.kdbUpd
      try
        o.kdbUpd @result
      catch err
        console.log "kdb-query:exception in kdbUpd"
        console.log err
    else if o.nodeName in ['SELECT','DATALIST']
      o.innerHTML = ''
      for e,i in @result
        opt = document.createElement 'option'
        opt.value = e.toString()
        opt.text = e.toString()
        o.appendChild opt
    else
      a = o.attributes['k-append']?.textContent || 'overwrite'
      ty = o.attributes['k-content-type']?.textContent || 'text'
      s = if o.textContent then '\n' else ''
      if ty is 'text'
        if a is 'top' then o.textContent = @result.toString()+s+o.textContent else if a is 'bottom' then o.textContent += s+@result.toString() else o.textContent = @result.toString()
      else
        if a is 'top' then o.innerHTML = @result.toString()+s+o.innerHTML else if a is 'bottom' then o.innerHTML += s+@result.toString() else o.innerHTML = @result.toString()
  resolveRefs: (q)->
    return q unless @kRefs
    if !@kMap
      @kMap = {}
      @kMap[e] = null for e in @kRefs
      @kMap[e] = document.querySelector "[k-id='#{e}']" for e of @kMap
    for n,v of @kMap
      if !v
        txt = if n is "i" then @iterationNumber.toString() else if n is 'txt' then @kLastEvent.target?.textContent else n
      else
        txt = extractInfo v
      q = q.replace (new RegExp "\\$#{n}\\$", "g"), @escape txt
    q
  escape: (s) -> if @escapeQ then s.replace(/\\/g,"\\\\").replace(/"/g,'\\"').replace(/\240/g," ") else s

class _KDBTable extends HTMLElement
  createdCallback: ->
    @srv = @attributes['k-srv']?.textContent || ""
    @query = @attributes['k-query']?.textContent || @textContent
    @debug = @attributes['debug']?.textContent || null
    @escHtml = (@attributes['k-escape-html']?.textContent || 'true') == 'true'
    @inited = false
  attachedCallback: ->
    if !@inited
      console.log "kdb-table: initing" if @debug
      @inited = true
      return if @query is ""
      if /\w+/.test @query
        @query = srv if srv = document.querySelector "[k-id='#{@query}']"
      if typeof @query is 'string'
        console.log "kdb-table: creating a query" if @debug
        q = new KDB.KDBQuery()
        q.setAttribute 'k-query', @query
        q.setAttribute 'k-srv', @srv if @srv
        q.setAttribute 'debug', @debug if @debug
        q.setupQuery()
        @query = q
      return unless @query?.runQuery
      @query.onresult (ev) => @onResult ev
      console.log "kdb-table: init complete" if @debug
  onResult: (ev) ->
    console.log "kdb-table: got event" if @debug
    console.log ev.detail if @debug
    @updateTbl ev.detail
  kdbUpd: (r) -> @updateTbl r
  updateTbl: (r) ->
    return if (r.length || 0) is 0
    tbl = "<table class='kdb-table'><tr>"
    tbl += "<th>#{@escapeHtml c}</th>" for c of r[0]
    tbl += "</tr>"
    for e in r
      tbl += "<tr>"
      tbl += "<td>#{@escapeHtml d}</td>" for c,d of e
      tbl += "</tr>"
    tbl += "</table>"
    @innerHTML = tbl
  escapeHtml: (s) ->
    s = s.toString()
    if @escHtml then s.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;') else s

class _KDBChart extends HTMLElement
  createdCallback: ->
    @srv = @attributes['k-srv']?.textContent || ""
    @query = @attributes['k-query']?.textContent || @textContent
    @debug = @attributes['debug']?.textContent || null
    @kFlow = (@attributes['k-flow']?.textContent || "false") is "true"
    @kConfig = @attributes['k-config']?.textContent
    kClass = @attributes['k-class']?.textContent || ""
    kStyle = @attributes['k-style']?.textContent || ""
    @kChType = @attributes['k-chart-type']?.textContent || "line"
    @kTime = @attributes['k-time-col']?.textContent
    @kData = @attributes['k-data-cols']?.textContent.split(' ').filter (el) -> el.length>0
    @inited = false
    @chart = null
    @chSrc = ''
    @kCont = document.createElement 'div'
    @kCont.className = kClass
    @kCont.style.cssText = kStyle
    this.appendChild @kCont
    console.log "kdb-chart: query:#{@query}, type:#{@kChType}, cfg:#{@kConfig}" if @debug
  attachedCallback: ->
    if !@inited
      console.log "kdb-chart: initing" if @debug
      @inited = true
      return if @query is ""
      if /\w+/.test @query
        @query = srv if srv = document.querySelector "[k-id='#{@query}']"
      if typeof @query is 'string'
        console.log "kdb-chart: creating a query" if @debug
        q = new KDB.KDBQuery()
        q.setAttribute 'k-query', @query
        q.setAttribute 'k-srv', @srv if @srv
        q.setAttribute 'debug', @debug if @debug
        q.setupQuery()
        @query = q
      return unless @query?.runQuery
      @query.onresult (ev) => @onResult ev
      console.log "kdb-chart: init complete" if @debug
  onResult: (ev) ->
    console.log "kdb-chart: got event" if @debug
    console.log ev.detail if @debug
    @updateChart ev.detail
  kdbUpd: (r) ->
    console.log "kdb-chart: got update" if @debug
    console.log r if @debug
    @updateChart r
  updateChart: (r) ->
    if @chart and @kFlow
      if @chSrc is 'c3'
        return @updateFlowWithData r
      tbl = r
      cfg = {}
      if r['data']
        cfg.to = r.to if r.to
        cfg.length = r.length if r.length
        cfg.duration = r.duration if r.duration
        tbl = r.data
      cfg.rows = @convertAllTbl tbl if @chSrc is 'user'
      cfg.rows = @convertTbl tbl,@dtCfg.time,@dtCfg.data if @chSrc is 'auto'
      cfg.columns = ([n].concat v for n,v of tbl) if @chSrc is 'dict'
      return @updateFlowWithData cfg
    if @kChType is 'use-config'
      return unless @kConfig and typeof r is 'object'
      return if r.length is 0
      console.log "kdb-chart: will use provided cfg" if @debug
      cfg = @getConfig @kConfig
      cfg.data.rows = @convertAllTbl r
      @chSrc = 'user'
    else if typeof r is 'object' and r.data
      console.log "C3 format detected" if @debug
      console.log r if @debug
      @chSrc = 'c3'
      return @updateChartWithData r
    else if typeof r is 'object' and r.length>0
      # detect format
      console.log "Will detect the user format" if @debug
      return unless tm = @detectTime r[0]
      fmt = @detectTimeFmt r[0][tm]
      xfmt = @detectTimeXFmt r, tm, fmt
      console.log "Time is #{tm}, fmt is #{fmt}, xfmt is #{xfmt}" if @debug
      dt = @detectData r[0]
      console.log "Data is #{dt}" if @debug
      @dtCfg = data: dt, time: tm
      return if dt.length is 0
      cfg =
        data:
          x: tm
          rows: @convertTbl r,tm,dt
          type: @kChType
          xFormat: fmt
        point:
          show: false
        axis:
          x:
            type: 'timeseries'
            tick:
              fit: true
              format: xfmt
      @chSrc = 'auto'
    else if typeof r is 'object'
      # pie
      t = @attributes['k-chart-type']?.textContent || "pie"
      d = ([n].concat v for n,v of r)
      cfg =
        data:
          columns: d
          type: t
      @chSrc = 'dict'
    if @kChType is 'merge-config'
      console.log "kdb-chart: will merge cfgs" if @debug
      cfg = @mergeCfgs cfg, @getConfig @kConfig
    console.log "kdb-chart: cfg is" if @debug
    console.log cfg if @debug
    return @updateChartWithData cfg
  updateChartWithData: (d) ->
    d['bindto'] = @kCont
    @chart = c3.generate d
  updateFlowWithData: (d) -> @chart.flow d
  convertTbl: (t,tm,dt) ->
    cols = []
    for n of t[0]
      cols.push n if n is tm or n in dt
    rows = [cols]
    for rec in t
      rows.push ((if n is tm then @convTime(rec[n]) else rec[n]) for n in cols)
    rows
  convertAllTbl: (t) ->
    t = [t] unless t.length
    cols = []; fmts = []
    for n,v of t[0]
      cols.push n
      fmts[n] = d3.time.format f if f = @detectTimeFmt v
    rows = [cols]
    for rec in t
      rows.push ((if fmts[n] then (fmts[n].parse @convTime rec[n]) else rec[n]) for n in cols)
    rows
  detectData: (r) ->
    return @kData if @kData
    for n,v of r
      return [n] if typeof v is 'number' or v instanceof Number
    []
  detectTime: (r) ->
    return @kTime if @kTime and r[@kTime]
    t = null
    for n,v of r
      return n if v instanceof Date
      return n if typeof v is 'string' and @detectTimeFmt v
      t = n if !t and v instanceof Number
    t
  detectTimeFmt: (v) ->
    return ((d) -> d) if v instanceof Date
    return '%H:%M:%S.%L' if /^\d\d:\d\d:\d\d\.\d\d\d/.test v
    return '%Y-%m-%dT%H:%M:%S.%L'if /^\d\d\d\d[-\.]\d\d[-\.]\d\d[DT]\d\d:\d\d:\d\d\.\d\d\d/.test v
    return '%Y-%m-%d' if /^\d\d\d\d-\d\d-\d\d/.test v
    return '%Y.%m.%d' if /^\d\d\d\d\.\d\d\.\d\d/.test v
    return '%jT%H:%M:%S.%L' if /^\d+D\d\d:\d\d:\d\d\.\d\d\d/.test v
    return '%H:%M:%S' if /^\d\d:\d\d:\d\d/.test v
    return '%H:%M' if /^\d\d:\d\d/.test v
  detectTimeXFmt: (r,tm,f) ->
    return f if typeof f is 'string' and f.length<12
    if typeof f is 'string'
      fmt = d3.time.format f
      f = (d) -> fmt.parse d
    i = Math.abs (f @convTime r[r.length-1][tm])-(f @convTime r[0][tm])
    return '%H:%M:%S.%L' if i < 86400000
    '%Y.%m.%dT%H:%M'
  convTime: (d) ->
    return d unless typeof d is 'string' and d.length>=20
    d = d.slice(0,-6) unless d[d.length-4] is "."
    d = d.replace('.','-').replace('.','-') if d[4] is '.'
    d.replace('D','T')
  mergeCfgs: (c1,c2) ->
    for n,v of c1
      continue unless v2 = c2[n]
      if typeof v2 is 'object' and typeof v is 'object' and !v2.length and !v.length
        c1[n] = @mergeCfgs v, v2
      else
        c1[n] = v2
    for n,v of c2
      continue if c1[n]
      c1[n] = v
    c1
  copyCfg: (c) ->
    cc = {}
    for n,v of c
      if typeof v is 'object' and !v.length
        cc[n] = @copyCfg v
      else
        cc[n] = v
    cc
  getConfig: (c) ->
    return @copyCfg (c.split(".").reduce ((x,y) -> return x[y]), window) if /^[\w\.]+$/.test c
    try
      cfg = JSON.parse c
    catch err
      console.log "kdb-chart: config parse exception"
      return console.log err

window.KDB ?= {}
KDB.KDBChart = document.registerElement('kdb-chart', prototype: _KDBChart.prototype)
KDB.KDBSrv = document.registerElement('kdb-srv', prototype: _KDBSrv.prototype)
KDB.KDBQuery = document.registerElement('kdb-query', prototype: _KDBQuery.prototype)
KDB.KDBTable = document.registerElement('kdb-table', prototype: _KDBTable.prototype)
