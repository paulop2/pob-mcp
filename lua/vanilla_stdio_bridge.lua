-- JSON-lines adapter for an unmodified PathOfBuildingCommunity checkout.
-- Run with cwd set to its src/ directory: luajit /path/to/vanilla_stdio_bridge.lua
-- All build operations live in pob_ops.lua (repo-owned); no PoB patches required.
local json = require('dkjson')

-- Locate this script's directory so repo-owned modules load regardless of cwd
local ADAPTER_DIR = (arg and arg[0] or ''):gsub('[^/\\]*$', '')
if ADAPTER_DIR == '' then ADAPTER_DIR = './' end

-- Stock HeadlessWrapper does not define this render stub; define it before the
-- dofile so an upstream version, if one is ever added, takes precedence.
if not GetVirtualScreenSize then
  function GetVirtualScreenSize() return 1920, 1080 end
end

-- The timeless jewel loader caches inflated LUTs to Data/TimelessJewelData/*.bin
-- with "wb+". Headless never reads them back (NewFileSearch is stubbed), and two
-- bridge processes would race on those files, so load with caching disabled.
do
  local okLoader, loadJewelFile = pcall(dofile, 'Modules/DataJewelFileLoader.lua')
  if okLoader and type(loadJewelFile) == 'function' then
    package.loaded['Modules.DataJewelFileLoader'] = function(name) return loadJewelFile(name, false) end
  end
end

-- The upstream wrapper initializes PoB and exposes newBuild/loadBuildFromXML plus `build`.
dofile('HeadlessWrapper.lua')

-- HeadlessWrapper stubs Inflate() to return "", so every timeless jewel
-- (Glorious Vanity, Lethal Pride, ...) is calculated as if its lookup table were
-- missing. Replace it with real zlib inflate through LuaJIT FFI, using the
-- zlib PoB ships next to its runtime (or the system zlib elsewhere).
local INFLATE_STATUS = 'stub'
do
  local okFfi, ffi = pcall(require, 'ffi')
  if okFfi then
    pcall(ffi.cdef, [[
      typedef struct {
        const unsigned char *next_in; unsigned avail_in; unsigned long total_in;
        unsigned char *next_out; unsigned avail_out; unsigned long total_out;
        const char *msg; void *state; void *zalloc; void *zfree; void *opaque;
        int data_type; unsigned long adler; unsigned long reserved;
      } pobmcp_z_stream;
      const char *zlibVersion(void);
      int inflateInit_(pobmcp_z_stream *strm, const char *version, int stream_size);
      int inflate(pobmcp_z_stream *strm, int flush);
      int inflateEnd(pobmcp_z_stream *strm);
    ]])
    local zlib
    for _, name in ipairs({ '../runtime/zlib1.dll', 'zlib1', 'z' }) do
      local okLoad, lib = pcall(ffi.load, name)
      if okLoad then zlib = lib; break end
    end
    if zlib then
      local Z_OK, Z_STREAM_END, CHUNK = 0, 1, 4 * 1024 * 1024
      function Inflate(data)
        local strm = ffi.new('pobmcp_z_stream')
        if zlib.inflateInit_(strm, zlib.zlibVersion(), ffi.sizeof(strm)) ~= Z_OK then
          return nil, 'inflateInit failed'
        end
        local input = ffi.new('unsigned char[?]', #data)
        ffi.copy(input, data, #data)
        strm.next_in, strm.avail_in = input, #data
        local buf, parts = ffi.new('unsigned char[?]', CHUNK), {}
        local ret
        repeat
          strm.next_out, strm.avail_out = buf, CHUNK
          ret = zlib.inflate(strm, 0)
          if ret ~= Z_OK and ret ~= Z_STREAM_END then
            zlib.inflateEnd(strm)
            return nil, 'inflate failed: ' .. ret
          end
          parts[#parts + 1] = ffi.string(buf, CHUNK - strm.avail_out)
        until ret == Z_STREAM_END
        zlib.inflateEnd(strm)
        return table.concat(parts)
      end
      INFLATE_STATUS = 'zlib'
    end
  end
  if INFLATE_STATUS == 'stub' then
    io.stderr:write('pob-mcp: no zlib available; timeless jewels will calculate without their lookup tables\n')
  end
end

-- Headless runs in dev mode, which autosaves the outgoing build to
-- buildPath/~~temp~~.xml on every switch and opens an error popup when that fails.
if __mainObject__ and __mainObject__.main then
  __mainObject__.main.disableDevAutoSave = true
end

-- SkillsTab:ProcessSocketGroup clears `grantedEffect.levels[level].cost` for
-- triggered skills by writing into the shared data.skills tables, so one build
-- zeroes the mana cost of that skill level for every build loaded after it in
-- this process. Remember the original cost tables and put them back before
-- each load.
local skillCostSnapshot = {}
if data and data.skills then
  for _, grantedEffect in pairs(data.skills) do
    if type(grantedEffect) == 'table' and type(grantedEffect.levels) == 'table' then
      for _, levelData in pairs(grantedEffect.levels) do
        if type(levelData) == 'table' then skillCostSnapshot[levelData] = levelData.cost or false end
      end
    end
  end
end
local function restoreSkillCosts()
  for levelData, cost in pairs(skillCostSnapshot) do
    levelData.cost = cost or nil
  end
end

local BuildOps = dofile(ADAPTER_DIR .. 'pob_ops.lua')

-- Set when the last load_build_xml failed: the bridge then refuses to report
-- stats instead of answering with whatever build happens to be in memory.
local lastLoadError = nil

local function closePopups()
  local main = __mainObject__ and __mainObject__.main
  local titles = {}
  if main and main.popups then
    for i, popup in ipairs(main.popups) do titles[i] = tostring(popup.title) end
    while #main.popups > 0 do main:ClosePopup() end
  end
  return titles
end

-- Load a build without inheriting anything from the outgoing one, and fail
-- loudly instead of leaving the previous build's output in place.
local function loadFresh(xml, name)
  __mainObject__.promptMsg = nil
  closePopups()
  -- PoB reuses the build object across loads. Cluster jewel subGraphs from the
  -- outgoing build point at sockets the next load has already replaced, and
  -- PostLoad asserts while trying to remove them.
  if build and build.spec then build.spec.subGraphs = {} end
  -- Loading straight over another build can read the outgoing build's tabs
  -- (e.g. a stale activeSpec index); passing through an empty build resets them.
  _G.newBuild()
  restoreSkillCosts()
  local stale = build and build.calcsTab and build.calcsTab.mainOutput
  _G.loadBuildFromXML(xml, name)
  local prompt = __mainObject__.promptMsg
  __mainObject__.promptMsg = nil
  if prompt then error('PoB prompt: ' .. tostring(prompt), 0) end
  local popups = closePopups()
  if #popups > 0 then error('PoB opened a popup: ' .. table.concat(popups, ' | '), 0) end
  local output = build and build.calcsTab and build.calcsTab.mainOutput
  if not output or output == stale then error('build did not produce a fresh calculation', 0) end
end

local function reply(value)
  -- An unencodable reply (e.g. a reference cycle) must not kill the bridge.
  local ok, encoded = pcall(json.encode, value)
  if not ok then encoded = json.encode({ ok = false, error = 'cannot encode reply: ' .. tostring(encoded) }) end
  io.write(encoded, '\n')
  io.flush()
end

-- Copy only plain data out of a PoB output table: no class instances (tables
-- with a metatable), no cycles, bounded depth. PoB's output references items,
-- gems and mod lists that dkjson cannot encode.
local function plainCopy(t, onPath, depth)
  onPath[t] = true
  local copy = {}
  for k, v in pairs(t) do
    local tk, tv = type(k), type(v)
    if tk == 'string' or tk == 'number' then
      if tv == 'number' or tv == 'boolean' or tv == 'string' then
        copy[k] = v
      elseif tv == 'table' and not onPath[v] and depth < 6 and getmetatable(v) == nil then
        copy[k] = plainCopy(v, onPath, depth + 1)
      end
    end
  end
  onPath[t] = nil
  return copy
end

-- Class name → classId mapping (PoE1)
local CLASS_IDS = {
  Scion=0, Marauder=1, Ranger=2, Witch=3, Duelist=4, Templar=5, Shadow=6,
  scion=0, marauder=1, ranger=2, witch=3, duelist=4, templar=5, shadow=6,
}
-- Ascendancy index matches the order in the tree data ascendancies array (1-based)
local ASCENDANCY_IDS = {
  [0] = { Ascendant=1 },
  [1] = { Juggernaut=1, Berserker=2, Chieftain=3 },
  [2] = { Raider=1, Deadeye=2, Pathfinder=3 },
  [3] = { Occultist=1, Elementalist=2, Necromancer=3 },
  [4] = { Slayer=1, Gladiator=2, Champion=3 },
  [5] = { Inquisitor=1, Hierophant=2, Guardian=3 },
  [6] = { Assassin=1, Trickster=2, Saboteur=3 },
}

-- Evaluate upstream PoB's native anoint simulation without altering the loaded build.
-- This follows NotableDBControl's MiscCalculator approach, while restoring the UI
-- selection even if a candidate calculation fails.
local function evaluate_anoint_candidates(params)
  if not build or not build.itemsTab or not build.spec or not build.spec.tree then return { ok = false, error = 'build not initialized' } end
  local slotName = params.slot
  if type(slotName) ~= 'string' or slotName == '' then return { ok = false, error = 'slot is required (for example, Amulet)' } end
  local control = build.itemsTab.slots and build.itemsTab.slots[slotName]
  local item = control and control.selItemId and build.itemsTab.items[control.selItemId] or nil
  if not item then return { ok = false, error = 'no equipped item in ' .. slotName } end
  if slotName ~= 'Amulet' and not item.canBeAnointed then return { ok = false, error = slotName .. ' is not an anointable item slot' } end

  local tab, previousItem, previousEnchantSlot = build.itemsTab, build.itemsTab.displayItem, build.itemsTab.anointEnchantSlot
  local ok, result = pcall(function()
    tab:SetDisplayItem(item)
    tab.anointEnchantSlot = 1
    local calc = build.calcsTab:GetMiscCalculator()
    local repSlotName = item.base and item.base.type or slotName
    local base = calc({ repSlotName = repSlotName, repItem = tab:anointItem(nil) })
    local baseDps = tonumber(base.CombinedDPS or base.TotalDPS or 0) or 0
    local baseEhp = tonumber(base.TotalEHP or 0) or 0
    local candidates, evaluated, skipped = {}, 0, 0
    for id, node in pairs(build.spec.tree.nodes or {}) do
      if node.recipe and node.dn and node.modKey ~= '' and not build.spec.allocNodes[id] then
        local candidateOk, output = pcall(calc, { repSlotName = repSlotName, repItem = tab:anointItem(node) })
        if candidateOk and output then
          local dps = (tonumber(output.CombinedDPS or output.TotalDPS or 0) or 0) - baseDps
          local ehp = (tonumber(output.TotalEHP or 0) or 0) - baseEhp
          local focus = params.focus or 'both'
          local score = focus == 'dps' and dps or (focus == 'defence' and ehp or (dps / math.max(baseDps, 1) + 0.5 * ehp / math.max(baseEhp, 1)))
          local recipe = {}; for _, oil in ipairs(node.recipe or {}) do table.insert(recipe, tostring(oil)) end
          table.insert(candidates, { nodeId = tonumber(id) or id, name = node.dn, dpsDelta = dps, ehpDelta = ehp, score = score, recipe = recipe })
          evaluated = evaluated + 1
        else skipped = skipped + 1 end
      end
    end
    table.sort(candidates, function(a, b) return a.score > b.score end)
    local limit = math.min(math.max(tonumber(params.limit) or 50, 1), 500)
    while #candidates > limit do table.remove(candidates) end
    return { ok = true, candidates = candidates, base = { CombinedDPS = baseDps, TotalEHP = baseEhp }, evaluated = evaluated, skipped = skipped, slot = slotName, baseType = item.baseName or repSlotName, focus = params.focus or 'both' }
  end)
  tab:SetDisplayItem(previousItem); tab.anointEnchantSlot = previousEnchantSlot
  if not ok then return { ok = false, error = 'anoint evaluation failed: ' .. tostring(result) } end
  return result
end

-- Drive upstream TradeQueryGenerator directly, avoiding its interactive dialog.
-- The generator is a normal PoB class; its coroutine is advanced synchronously
-- here and the generated JSON is returned to Node for the actual Trade API call.
local function generate_weighted_trade_query(params)
  if not build or not build.itemsTab or not build.itemsTab.tradeQuery then return { ok = false, error = 'build/items not initialized' } end
  local slotName = params.slot
  local slot = type(slotName) == 'string' and build.itemsTab.slots and build.itemsTab.slots[slotName] or nil
  if not slot then return { ok = false, error = 'unknown equipment slot: ' .. tostring(slotName) } end
  local options = params.options or {}
  options.includeMirrored = options.includeMirrored == true
  options.includeCorrupted = options.includeCorrupted ~= false
  options.includeScourge = options.includeScourge == true
  options.includeEldritch = options.includeEldritch == true
  options.influence1 = tonumber(options.influence1) or 1
  options.influence2 = tonumber(options.influence2) or 1
  options.jewelType = options.jewelType or 'Any'
  options.statWeights = options.statWeights or build.itemsTab.tradeQuery.statSortSelectionList
  if not options.statWeights or #options.statWeights == 0 then options.statWeights = { { label = 'Full DPS', stat = 'FullDPS', weightMult = 1.0 }, { label = 'Effective Hit Pool', stat = 'TotalEHP', weightMult = 0.5 } } end
  local ok, result = pcall(function()
    local generator = new('TradeQueryGenerator'):TradeQueryGenerator(build.itemsTab.tradeQuery)
    local query, warning
    generator.requesterCallback = function(_, generated, err) query, warning = generated, err end
    generator.requesterContext = {}
    generator.tradeTypeIndex = 2 -- available listings, matching the MCP default
    generator:StartQuery(slot, options)
    local frames = 0
    while generator.calcContext and generator.calcContext.co and frames < 100000 do generator:OnFrame(); frames = frames + 1 end
    if generator.calcContext and generator.calcContext.co then error('TradeQueryGenerator did not complete after 100000 frames') end
    if not query then error(warning or 'PoB generated no trade query') end
    return { ok = true, query = query, warning = warning, frames = frames }
  end)
  if not ok then return { ok = false, error = 'weighted trade query failed: ' .. tostring(result) } end
  return result
end

-- Wrap a BuildOps function that returns (result, err) into the JSON envelope.
-- resultKey names the field the TS bridge reads the payload from.
local function op(fn, resultKey)
  return function(params)
    local res, err = fn(params or {})
    if res == nil then return { ok = false, error = err or 'operation failed' } end
    local envelope = { ok = true }
    if resultKey then envelope[resultKey] = res end
    return envelope
  end
end

local handlers = {}

handlers.ping = function() return { ok = true, pong = true } end

handlers.version = function()
  return { ok = true, version = {
    number = _G.launch and launch.versionNumber or '?',
    branch = _G.launch and launch.versionBranch or '?',
    platform = _G.launch and launch.versionPlatform or '?',
    adapter = 'vanilla-stdio-v2',
  } }
end

handlers.new_build = function(params)
  if not _G.newBuild then return { ok = false, error = 'headless wrapper not initialized' } end
  if build and build.spec then build.spec.subGraphs = {} end
  _G.newBuild()
  restoreSkillCosts()
  lastLoadError = nil
  if params and (params.className or params.ascendancy) then
    local classId = params.className and (CLASS_IDS[params.className] or CLASS_IDS[params.className:lower()]) or 0
    local ascendId = params.ascendancy and ASCENDANCY_IDS[classId] and ASCENDANCY_IDS[classId][params.ascendancy] or 0
    if build and build.spec then
      BuildOps.import_from_node_list(build.spec, classId, ascendId, 0, {}, {}, {}, nil)
    end
  end
  return { ok = true }
end

handlers.load_build_xml = function(params)
  if not params or type(params.xml) ~= 'string' then return { ok = false, error = 'missing xml' } end
  if not _G.loadBuildFromXML then return { ok = false, error = 'headless wrapper not initialized' } end
  local ok, err = pcall(loadFresh, params.xml, (params.name and tostring(params.name)) or 'API Build')
  if not ok then
    lastLoadError = tostring(err)
    return { ok = false, error = lastLoadError }
  end
  lastLoadError = nil
  return { ok = true, build_id = 1 }
end

-- Flatten nested output tables into dotted keys. Only plain data is followed:
-- tables with a metatable are class instances (items, mod lists) that output
-- merely references, and table keys would stringify to memory addresses.
-- Same contract as pob-oracle's reference evaluator, so its `check` can score
-- this bridge directly.
local FLAT_MAX_DEPTH = 6
local function flatten(t, prefix, out, onPath, depth)
  onPath[t] = true
  for k, v in pairs(t) do
    local tk = type(k)
    if tk == 'string' or tk == 'number' then
      local key = prefix .. tostring(k)
      local tv = type(v)
      if tv == 'number' or tv == 'boolean' or tv == 'string' then
        out[key] = v
      elseif tv == 'table' and not onPath[v] and depth < FLAT_MAX_DEPTH and getmetatable(v) == nil then
        flatten(v, key .. '.', out, onPath, depth + 1)
      end
    end
  end
  onPath[t] = nil
  return out
end

-- dkjson prints numbers with %.14g; full precision needs %.17g.
local function encodeFlatValue(v)
  local tv = type(v)
  if tv == 'number' then
    if v ~= v then return '"NaN"' end
    if v == math.huge then return '"Infinity"' end
    if v == -math.huge then return '"-Infinity"' end
    return ('%.17g'):format(v)
  end
  if tv == 'boolean' then return v and 'true' or 'false' end
  return json.quotestring(tostring(v))
end

local function encodeFlat(map)
  local keys = {}
  for k in pairs(map) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for i, k in ipairs(keys) do parts[i] = json.quotestring(k) .. ':' .. encodeFlatValue(map[k]) end
  return '{' .. table.concat(parts, ',') .. '}'
end

-- The whole calculated output, flattened, as pre-encoded JSON (see reply loop).
handlers.get_output = function()
  local output = build and build.calcsTab and build.calcsTab.mainOutput
  if not output then return { ok = false, error = 'no build loaded' } end
  return { __raw = '{"ok":true,"output":' .. encodeFlat(flatten(output, '', {}, {}, 0)) .. '}' }
end

handlers.diagnostics = function()
  return { ok = true, diagnostics = {
    inflate = INFLATE_STATUS,
    devAutoSave = not (__mainObject__ and __mainObject__.main and __mainObject__.main.disableDevAutoSave),
    lastLoadError = lastLoadError,
  } }
end

handlers.get_stats = function(params)
  local stats, err = BuildOps.export_stats(params and params.fields or nil)
  if not stats then return { ok = false, error = err } end
  return { ok = true, stats = stats }
end

handlers.set_tree = function(params)
  local ok2, err = BuildOps.set_tree(params or {})
  if not ok2 then return { ok = false, error = err } end
  return { ok = true, tree = (BuildOps.get_tree()) }
end

handlers.update_tree_delta = function(params)
  local ok2, err = BuildOps.update_tree_delta(params or {})
  if not ok2 then return { ok = false, error = err } end
  return { ok = true, tree = (BuildOps.get_tree()) }
end

handlers.set_config = function(params)
  local ok2, err = BuildOps.set_config(params or {})
  if not ok2 then return { ok = false, error = err } end
  return { ok = true, config = (BuildOps.get_config()) }
end

handlers.set_main_selection = function(params)
  local ok2, err = BuildOps.set_main_selection(params or {})
  if not ok2 then return { ok = false, error = err } end
  return { ok = true, skills = (BuildOps.get_skills()) }
end

handlers.set_level = function(params)
  if not params or params.level == nil then return { ok = false, error = 'missing level' } end
  local ok2, err = BuildOps.set_level(params.level)
  if not ok2 then return { ok = false, error = err } end
  return { ok = true }
end

handlers.set_flask_active = op(BuildOps.set_flask_active)
handlers.set_gem_level = op(BuildOps.set_gem_level)
handlers.set_gem_quality = op(BuildOps.set_gem_quality)
handlers.set_gem_enabled = op(BuildOps.set_gem_enabled)
handlers.remove_skill = op(BuildOps.remove_skill)
handlers.remove_gem = op(BuildOps.remove_gem)

handlers.get_tree = op(BuildOps.get_tree, 'tree')
handlers.get_items = op(BuildOps.get_items, 'items')
handlers.get_skills = op(BuildOps.get_skills, 'skills')
handlers.get_build_info = op(BuildOps.get_build_info, 'info')
handlers.get_config = op(BuildOps.get_config, 'config')
handlers.calc_with = function(params)
  local out, err = BuildOps.calc_with(params or {})
  if out == nil then return { ok = false, error = err or 'operation failed' } end
  return { ok = true, output = plainCopy(out, {}, 0) }
end
handlers.export_build_xml = op(BuildOps.export_build_xml, 'xml')
handlers.add_item_text = op(BuildOps.add_item_text, 'item')
handlers.create_socket_group = op(BuildOps.create_socket_group, 'socketGroup')
handlers.add_gem = op(BuildOps.add_gem, 'gem')
handlers.search_nodes = op(BuildOps.search_nodes, 'results')
handlers.get_mastery_options = op(BuildOps.get_mastery_options, 'result')
handlers.save_build = op(BuildOps.save_build, 'result')
handlers.list_specs = op(BuildOps.list_specs, 'result')
handlers.select_spec = op(BuildOps.select_spec, 'result')
handlers.create_spec = op(BuildOps.create_spec, 'result')
handlers.delete_spec = op(BuildOps.delete_spec, 'result')
handlers.rename_spec = op(BuildOps.rename_spec, 'result')
handlers.list_item_sets = op(BuildOps.list_item_sets, 'result')
handlers.select_item_set = op(BuildOps.select_item_set, 'result')
handlers.set_socket_group_enabled = op(BuildOps.set_socket_group_enabled, 'result')

handlers.evaluate_anoint_candidates = evaluate_anoint_candidates
handlers.generate_weighted_trade_query = generate_weighted_trade_query

handlers.get_capabilities = function()
  local actions = { 'quit' }
  for name in pairs(handlers) do table.insert(actions, name) end
  table.sort(actions)
  return { ok = true, capabilities = { mode = 'vanilla', adapter = 'vanilla-stdio-v2', actions = actions } }
end

-- Actions that still answer after a failed load; everything else would read
-- whatever build happens to be in memory, so it refuses until the next load.
local LOAD_INDEPENDENT = {
  ping = true, version = true, get_capabilities = true, diagnostics = true,
  new_build = true, load_build_xml = true,
}

reply({ ok = true, ready = true, version = { adapter = 'vanilla-stdio-v2' } })
for line in io.lines() do
  local request = json.decode(line)
  local action, params = request and request.action, request and request.params or {}
  if action == 'quit' then
    reply({ ok = true, quit = true })
    break
  end
  local handler = handlers[action]
  if not handler then
    reply({ ok = false, error = 'unknown action: ' .. tostring(action) })
  elseif lastLoadError and not LOAD_INDEPENDENT[action] then
    reply({ ok = false, error = 'last build load failed: ' .. lastLoadError })
  else
    local ok, res = pcall(handler, params)
    if not ok then
      reply({ ok = false, error = tostring(res) })
    elseif type(res) ~= 'table' then
      reply({ ok = false, error = 'handler returned no response' })
    elseif res.__raw then
      io.write(res.__raw, '\n')
      io.flush()
    else
      reply(res)
    end
  end
end
