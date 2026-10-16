local SCRIPT_VERSION = "5.1"
local TRACE_PATH = "/sdcard/qiyian_168_channel.log"

local PROFILE = {
  packageName = "com.zmxyol.union.dn",
  versionCode = 1640,
  versionName = "16.8.0s",
  abi = "arm64-v8a",
  gameModule = "_64_game.so",
  gameBaseRangeIndex = 2,
  selfValueOffset = 0xBCA5F8,
  selfValue64Offset = 8,
  maxRelativeOffset = 0xCC2A98,
}

local MODULE_OFFSET = {
  A0 = 0xBED7F8,
  root80 = 0xBED0B0,
  person = 0xBF12C8,
  globalItems = 0xBEDFB8,
  map = 0xBEBB60,
  cooldown = 0xBEBF80,
  dynamicSearch = 0xCC2A98,
  petBook = 0xBEE530,
  passive = 0xBEE3D0,
  task = 0xBEE778,
}

local TAG = {
  ["A0基址"] = MODULE_OFFSET.A0,
  ["80基址"] = MODULE_OFFSET.root80,
  ["人物基址头"] = MODULE_OFFSET.person,
  ["全局基址头"] = MODULE_OFFSET.globalItems,
  ["改图基址头"] = MODULE_OFFSET.map,
  ["冷却基址头"] = MODULE_OFFSET.cooldown,
  ["动态搜值头"] = MODULE_OFFSET.dynamicSearch,
  ["奇闻录宠物基址头"] = MODULE_OFFSET.petBook,
}

TAG["全局物品"] = {TAG["全局基址头"], 8, 24, 0}
TAG["动态搜值"] = {TAG["动态搜值头"], 256, 24, 0}
TAG["人物基址"] = {TAG["人物基址头"], 128, 0}
TAG["本命指针"] = {TAG["人物基址头"], 128, 4896, 136, 0}
TAG["本命阶数"] = {TAG["人物基址头"], 128, 4896, 976}
TAG["灵物阶数"] = {TAG["人物基址头"], 128, 4896, 128, 108}
TAG["任务基址"] = {MODULE_OFFSET.task, 80, 24, 16, 0, 696}
TAG["全局任务数量"] = {MODULE_OFFSET.task, 56, 24, 0}
TAG["被动基址"] = {MODULE_OFFSET.passive, 368, 16, 0}
TAG["昆仑山层数"] = {TAG["改图基址头"], 1216}
TAG["掉落基址"] = {TAG["改图基址头"], 0xA58}
if MODULE_OFFSET.cooldown then
  TAG["幻境基址"] = {TAG["冷却基址头"], 320, 0}
end
TAG["动态背包"] = {TAG["A0基址"], 1480}
TAG["属性地址"] = {640, 0}
TAG["宠物数量上层"] = {TAG["80基址"], 0x298}
TAG["宠物数量"] = {TAG["80基址"], 0x298, 0}
TAG["奇闻录宠物"] = {TAG["奇闻录宠物基址头"], 32, 512, 464, 16, 24, 16, 0}

local FIELD = {
  ["人物当前经验"] = 4520,
  ["人物等级"] = 1040,
  ["人物秒杀"] = 1612,
  ["人物加速"] = 896,
  ["护盾基址"] = 1688,
  ["人物隐身"] = 1344,
  ["人物移速"] = 416,
  ["普攻基址"] = 5728,
  ["战功"] = 1056,
  ["灵魂"] = 56,
  ["仙气"] = 92,
  ["启灵珠"] = 1616,
  ["装备品质"] = 332,
  ["装备壳子"] = 592,
  ["装备壳子2"] = 512,
  ["宠物指针"] = 24,
  ["宠物状态"] = 4416,
  ["宠物等级"] = 3376,
  ["宠物涅槃"] = 680,
  ["宠物生命"] = 200,
  ["宠物根骨"] = 296,
  ["宠物阶数"] = 368,
  ["宠物技能"] = 656,
  ["宠物名称"] = 32,
  ["被动等级"] = 56,
  ["本命灵物"] = 112,
  ["本命等级"] = 124,
  ["本命等级副本"] = 136,
  ["任务状态"] = 376,
}

local PANEL_FIELDS = {
  {name="魔抗", offset=2116},
  {name="破魔", offset=2128},
  {name="闪避", offset=2140},
  {name="暴击", offset=2152},
  {name="命中", offset=2164},
  {name="抗暴", offset=2176},
  {name="破邪", offset=2188},
  {name="伤害率", offset=2200},
  {name="免伤率", offset=2212},
  {name="幸运", offset=4400},
}

local U32_MASK = 0xFFFFFFFF
local POINTER_MASK = 0x00FFFFFFFFFFFFFF
local MIN_VALID_ADDRESS = 0x100000000
local runtime = {
  gameBase = nil,
  targetInfo = nil,
  pointerCodecTagPrefix = 0,
  codecSelfValue64 = nil,
  inventoryHighCandidates = {},
  ranges = {},
  sortedRanges = {},
  rangesOverlap = false,
  rangesRefreshedAt = -1,
  lastMappedRange = nil,
  traceFile = nil,
  activeMenu = nil,
  menuDispatching = false,
  queuedMenu = nil,
  allowLowTestAddresses = false,
}

local function trace(message)
  if not runtime.traceFile then return end
  runtime.traceFile:write(tostring(message), "\n")
  runtime.traceFile:flush()
end

local function fatal(message)
  trace("FATAL: " .. tostring(message))
  gg.alert(message)
  os.exit()
end

local function untagPointer(value)
  local number = tonumber(value)
  if not number then return 0 end
  return number & POINTER_MASK
end

local function valueSize(flags)
  if flags == gg.TYPE_BYTE then return 1 end
  if flags == gg.TYPE_WORD then return 2 end
  if flags == gg.TYPE_QWORD or flags == gg.TYPE_DOUBLE then return 8 end
  return 4
end

local function indexRanges(ranges)
  local sorted, ordered = {}, true
  if type(ranges) ~= "table" then return sorted, false end
  for _, range in ipairs(ranges) do
    if type(range) == "table" and type(range.start) == "number" and
       type(range["end"]) == "number" then
      local previous = sorted[#sorted]
      if previous and range.start < previous.start then ordered = false end
      sorted[#sorted + 1] = range
    end
  end
  if not ordered then
    table.sort(sorted, function(left, right) return left.start < right.start end)
  end
  for index = 2, #sorted do
    local previous = sorted[index - 1]
    if sorted[index].start < previous["end"] or
       sorted[index].start == previous.start then
      return sorted, true
    end
  end
  return sorted, false
end

local function refreshRanges(force)
  local now = os.time()
  if force or #runtime.ranges == 0 or now ~= runtime.rangesRefreshedAt then
    runtime.ranges = gg.getRangesList()
    runtime.sortedRanges, runtime.rangesOverlap = indexRanges(runtime.ranges)
    runtime.rangesRefreshedAt = now
    runtime.lastMappedRange = nil
  end
  return runtime.ranges
end

local function findRange(ranges, sorted, overlapping, address, lastAddress)
  if overlapping then
    for _, range in ipairs(ranges) do
      if type(range) == "table" and type(range.start) == "number" and
         type(range["end"]) == "number" and
         address >= range.start and lastAddress <= range["end"] then
        return range
      end
    end
    return nil
  end
  local low, high, candidate = 1, #sorted, nil
  while low <= high do
    local middle = (low + high) // 2
    local range = sorted[middle]
    if range.start <= address then
      candidate = range
      low = middle + 1
    else
      high = middle - 1
    end
  end
  if candidate and lastAddress <= candidate["end"] then return candidate end
  return nil
end

local DIRECT_PROBE_PAGE_SIZE = 4096
local DIRECT_PROBE_MAX_PAGES = 4096

local function probeReadablePages(address, lastAddress)
  local pageSize = DIRECT_PROBE_PAGE_SIZE
  local pageStart = address - (address % pageSize)
  local pageEnd = lastAddress - (lastAddress % pageSize) + pageSize - 1
  if pageEnd < lastAddress then return nil end
  local pageCount = ((pageEnd - pageStart + 1) // pageSize)
  if pageCount < 1 or pageCount > DIRECT_PROBE_MAX_PAGES then return nil end

  local requests = {}
  for page = pageStart, pageEnd, pageSize do
    requests[#requests + 1] = {address=page, flags=gg.TYPE_BYTE}
  end
  if pageEnd ~= requests[#requests].address then
    requests[#requests + 1] = {address=pageEnd, flags=gg.TYPE_BYTE}
  end

  local ok, values = pcall(gg.getValues, requests)
  if not ok or type(values) ~= "table" or #values ~= #requests then
    return nil
  end
  for index, request in ipairs(requests) do
    local value = values[index]
    if type(value) ~= "table" or value.value == nil or
       tonumber(value.address) ~= request.address then
      return nil
    end
  end

  local range = {
    start=pageStart,
    ["end"]=pageEnd,
    state="direct-readable",
    name="[direct getValues probe]",
    directProbe=true,
  }
  trace(string.format(
    "mapped range fallback: start=0x%X end=0x%X pages=%d",
    pageStart, pageEnd, pageCount
  ))
  return range
end

local function mappedRange(address, size, forceRefresh)
  address = untagPointer(address)
  size = size or 1
  if address == 0 or size < 1 then return nil end
  if address < MIN_VALID_ADDRESS and runtime.allowLowTestAddresses ~= true then
    return nil
  end
  local lastAddress = address + size - 1
  if lastAddress < address then return nil end
  if forceRefresh == true then refreshRanges(true) end
  local lastRange = runtime.lastMappedRange
  if lastRange and address >= lastRange.start and
     lastAddress <= lastRange["end"] then
    return lastRange
  end
  if forceRefresh ~= true then refreshRanges(false) end
  local range = findRange(
    runtime.ranges, runtime.sortedRanges, runtime.rangesOverlap,
    address, lastAddress
  )
  if range then
    runtime.lastMappedRange = range
    return range
  end
  local probed = probeReadablePages(address, lastAddress)
  if probed then runtime.lastMappedRange = probed end
  return probed
end

local function requireMapped(address, size, label)
  local normalized = untagPointer(address)
  if not mappedRange(normalized, size) then
    error(string.format("%s地址无效: 0x%X", label or "内存", normalized), 0)
  end
  return normalized
end

local Memory = {}

function Memory.isMapped(address, size, forceRefresh)
  return mappedRange(address, size, forceRefresh) ~= nil
end

function Memory.refreshRanges()
  return refreshRanges(true)
end

function Memory.read(address, flags)
  flags = flags or gg.TYPE_QWORD
  address = requireMapped(address, valueSize(flags), "读取")
  local values = gg.getValues({{address=address, flags=flags}})
  if type(values) ~= "table" or type(values[1]) ~= "table" then
    error("读取结果不完整", 0)
  end
  return values[1].value
end

function Memory.readMany(requests)
  if type(requests) ~= "table" then error("批量读取参数无效", 0) end
  if #requests == 0 then return {} end
  local normalized = {}
  for index, request in ipairs(requests) do
    local flags = request.flags or gg.TYPE_QWORD
    normalized[index] = {
      address=requireMapped(request.address, valueSize(flags), "批量读取"),
      flags=flags,
    }
  end
  local values = gg.getValues(normalized)
  if type(values) ~= "table" or #values ~= #normalized then
    error("批量读取结果不完整", 0)
  end
  return values
end

function Memory.writeMany(writes)
  if type(writes) ~= "table" or #writes == 0 then return true end
  local normalized = {}
  for index, item in ipairs(writes) do
    local flags = item.flags or gg.TYPE_DWORD
    if item.value == nil then error("写入值不能为空", 0) end
    normalized[index] = {
      address=requireMapped(item.address, valueSize(flags), "批量写入"),
      flags=flags,
      value=item.value,
    }
  end
  gg.setValues(normalized)
  return true
end

function Memory.write(address, value, flags)
  return Memory.writeMany({{
    address=address,
    value=value,
    flags=flags or gg.TYPE_DWORD,
  }})
end

function Memory.pointer(address)
  return untagPointer(Memory.read(address, gg.TYPE_QWORD))
end

function Memory.resolve(base, offsets, finalSize)
  base = untagPointer(base)
  if type(offsets) == "number" then
    local slot = requireMapped(base + offsets, 8, "指针槽")
    local pointer = Memory.pointer(slot)
    return requireMapped(pointer, finalSize or 1, "指针对象")
  end
  if type(offsets) ~= "table" or #offsets == 0 then
    error("指针路径为空", 0)
  end
  for index = 1, #offsets - 1 do
    local slot = requireMapped(base + offsets[index], 8, "第" .. index .. "跳指针槽")
    base = Memory.pointer(slot)
    if base == 0 then error("第" .. index .. "跳指针为空", 0) end
  end
  local address = base + offsets[#offsets]
  return requireMapped(address, finalSize or 1, "指针路径终点")
end

local function rotateLeft32(value, shift)
  value = value & U32_MASK
  shift = shift % 32
  if shift == 0 then return value end
  return ((value << shift) | (value >> (32 - shift))) & U32_MASK
end

local function rotateRight32(value, shift)
  value = value & U32_MASK
  shift = shift % 32
  if shift == 0 then return value end
  return ((value >> shift) | (value << (32 - shift))) & U32_MASK
end

local function codec64Shift(metadata)
  local shift = metadata & 0xFFFF
  if shift > 64 then
    error("64 位 codec 旋转元数据无效，已拒绝读写", 0)
  end
  return shift & 63
end

local function rotateLeft64(value, shift)
  shift = shift % 64
  if shift == 0 then return value end
  return (value << shift) | (value >> (64 - shift))
end

local function rotateRight64(value, shift)
  shift = shift % 64
  if shift == 0 then return value end
  return (value >> shift) | (value << (64 - shift))
end

local function rotateCodecPrimaryDelta64(value)
  local low = rotateLeft32(value & U32_MASK, 7)
  local high = rotateLeft32((value >> 32) & U32_MASK, 7)
  return low | (high << 32)
end

local function signed32(value)
  value = value & U32_MASK
  if value >= 0x80000000 then return value - 0x100000000 end
  return value
end

local function sameU32(left, right)
  return (tonumber(left) & U32_MASK) == (tonumber(right) & U32_MASK)
end

local Codec = {}

function Codec.decodeMany(requests)
  local reads = {}
  for index, item in ipairs(requests) do
    reads[index * 2 - 1] = {address=item.address + 4, flags=gg.TYPE_DWORD}
    reads[index * 2] = {address=item.address + 8, flags=gg.TYPE_DWORD}
  end
  local values = Memory.readMany(reads)
  local selfValue = TAG["自拟值"]
  local decoded = {}
  for index = 1, #requests do
    decoded[index] = rotateLeft32(
      values[index * 2 - 1].value ~ selfValue, values[index * 2].value
    )
  end
  return decoded
end

function Codec.decode(address)
  return Codec.decodeMany({{address=address}})[1]
end

function Codec.decode5Many(requests)
  local reads = {}
  for index, item in ipairs(requests) do
    local base = index * 3
    reads[base - 2] = {address=item.address + 8, flags=gg.TYPE_DWORD}
    reads[base - 1] = {address=item.address + 12, flags=gg.TYPE_DWORD}
    reads[base] = {address=item.address + 16, flags=gg.TYPE_DWORD}
  end
  local values = Memory.readMany(reads)
  local decoded = {}
  for index = 1, #requests do
    local base = index * 3
    decoded[index] = signed32(rotateLeft32(
      values[base - 1].value ~ values[base - 2].value, values[base].value
    ))
  end
  return decoded
end

function Codec.decode5(address)
  return Codec.decode5Many({{address=address}})[1]
end

function Codec.decode64Many(requests)
  if #requests == 0 then return {} end
  local selfValue = runtime.codecSelfValue64
  if type(selfValue) ~= "number" then
    error("64 位 codec 密钥尚未初始化", 0)
  end
  local reads = {}
  for index, item in ipairs(requests) do
    reads[index * 2 - 1] = {address=item.address + 8, flags=gg.TYPE_QWORD}
    reads[index * 2] = {address=item.address + 16, flags=gg.TYPE_QWORD}
  end
  local values = Memory.readMany(reads)
  local decoded = {}
  for index = 1, #requests do
    decoded[index] = rotateLeft64(
      values[index * 2 - 1].value ~ selfValue,
      codec64Shift(values[index * 2].value)
    )
  end
  return decoded
end

function Codec.decode64(address)
  return Codec.decode64Many({{address=address}})[1]
end

function Codec.encodeKey(raw0, raw4, raw8, target, rekey)
  local selfValue = TAG["自拟值"]
  local current = rotateLeft32(raw4 ~ selfValue, raw8)
  local primary = (raw0 ~ rotateLeft32(current ~ target, 7)) & U32_MASK
  if rekey then
    return primary, (selfValue ~ target) & U32_MASK,
      (raw8 & 0xFFFF0000) | 32
  end
  return primary, (selfValue ~ rotateRight32(target, raw8 & 31)) & U32_MASK,
    raw8
end

local requireInteger

local Transaction = {}

local TRANSACTION_OFFSETS = {
  key={0, 4, 8},
  key5={0, 8, 12, 16},
  key64={0, 8, 16},
  raw={0},
}

local function transactionOffsets(kind)
  local offsets = TRANSACTION_OFFSETS[kind]
  if not offsets then
    error("不支持的事务字段类型：" .. tostring(kind), 0)
  end
  return offsets
end

local function transactionFlags(spec)
  if spec.kind == "raw" then return spec.flags or gg.TYPE_DWORD end
  if spec.kind == "key64" then return gg.TYPE_QWORD end
  return gg.TYPE_DWORD
end

local function sameRawValue(left, right, flags)
  if flags == gg.TYPE_DWORD then
    return (tonumber(left) & U32_MASK) == (tonumber(right) & U32_MASK)
  end
  if flags == gg.TYPE_FLOAT or flags == gg.TYPE_DOUBLE then
    left, right = tonumber(left), tonumber(right)
    if not left or not right then return false end
    return math.abs(left - right) <=
      math.max(0.000001, math.abs(right) * 0.00001)
  end
  return tonumber(left) == tonumber(right)
end

local function validateTransactionIdentity(validator, label)
  if type(validator) ~= "function" then return true end
  local result = validator()
  if result == false then
    error((label or "内存事务") .. "目标身份校验失败", 0)
  end
  return true
end

local function normalizeTransactionSpecs(specs)
  if type(specs) ~= "table" or #specs == 0 then
    error("内存事务没有可写字段", 0)
  end
  local normalized, occupied = {}, {}
  for index, input in ipairs(specs) do
    local kind = input.kind or "raw"
    local flags = transactionFlags({kind=kind, flags=input.flags})
    local target
    if kind == "key" then
      target = requireInteger(
        input.value, -0x80000000, 4294967295, "加密数值"
      )
    elseif kind == "key5" then
      target = requireInteger(
        input.value, -0x80000000, 0x7FFFFFFF, "Key5 数值"
      )
    elseif kind == "key64" then
      target = requireInteger(
        input.value, -0x80000000, 0x7FFFFFFF, "64 位 codec 数值"
      )
    else
      if input.value == nil then error("事务写入值不能为空", 0) end
      target = input.value
    end
    local spec = {
      kind=kind,
      address=requireMapped(
        input.address,
        kind == "key" and 12 or
          (kind == "key5" and 20 or
          (kind == "key64" and 24 or valueSize(flags))),
        input.label or "事务字段"
      ),
      flags=flags,
      value=target,
      rekey=input.rekey == true,
      label=input.label or ("第 " .. index .. " 个事务字段"),
    }
    for _, offset in ipairs(transactionOffsets(kind)) do
      local key = tostring(spec.address + offset) .. ":" .. tostring(flags)
      if occupied[key] then error("事务字段地址重复：" .. spec.label, 0) end
      occupied[key] = true
    end
    normalized[index] = spec
  end
  return normalized
end

local function readTransactionSnapshot(specs)
  local requests, layout = {}, {}
  for specIndex, spec in ipairs(specs) do
    for _, offset in ipairs(transactionOffsets(spec.kind)) do
      requests[#requests + 1] = {
        address=spec.address + offset,
        flags=transactionFlags(spec),
      }
      layout[#layout + 1] = {specIndex=specIndex, offset=offset}
    end
  end
  local values = Memory.readMany(requests)
  local snapshot = {}
  for index, position in ipairs(layout) do
    snapshot[position.specIndex] = snapshot[position.specIndex] or {}
    snapshot[position.specIndex][position.offset] = values[index].value
  end
  return snapshot
end

local function sameTransactionSnapshot(left, right, specs)
  for index, spec in ipairs(specs) do
    local flags = transactionFlags(spec)
    for _, offset in ipairs(transactionOffsets(spec.kind)) do
      if not sameRawValue(left[index][offset], right[index][offset], flags) then
        return false
      end
    end
  end
  return true
end

local function transactionWrites(snapshot, specs, original)
  local writes = {}
  for index, spec in ipairs(specs) do
    local raw = snapshot[index]
    if original then
      for _, offset in ipairs(transactionOffsets(spec.kind)) do
        writes[#writes + 1] = {
          address=spec.address + offset,
          flags=transactionFlags(spec),
          value=raw[offset],
        }
      end
    elseif spec.kind == "raw" then
      writes[#writes + 1] = {
        address=spec.address, flags=spec.flags, value=spec.value,
      }
    elseif spec.kind == "key" then
      local primary, secondary, shift = Codec.encodeKey(
        raw[0], raw[4], raw[8], spec.value, spec.rekey
      )
      writes[#writes + 1] = {
        address=spec.address, flags=gg.TYPE_DWORD, value=primary,
      }
      writes[#writes + 1] = {
        address=spec.address + 4, flags=gg.TYPE_DWORD, value=secondary,
      }
      writes[#writes + 1] = {
        address=spec.address + 8, flags=gg.TYPE_DWORD, value=shift,
      }
    elseif spec.kind == "key64" then
      if type(runtime.codecSelfValue64) ~= "number" then
        error("64 位 codec 密钥尚未初始化", 0)
      end
      local current = rotateLeft64(
        raw[8] ~ runtime.codecSelfValue64, codec64Shift(raw[16])
      )
      local delta = current ~ spec.value
      local shift = codec64Shift(raw[16])
      writes[#writes + 1] = {
        address=spec.address, flags=gg.TYPE_QWORD,
        value=raw[0] ~ rotateCodecPrimaryDelta64(delta),
      }
      writes[#writes + 1] = {
        address=spec.address + 8, flags=gg.TYPE_QWORD,
        value=runtime.codecSelfValue64 ~ rotateRight64(spec.value, shift),
      }
      writes[#writes + 1] = {
        address=spec.address + 16, flags=gg.TYPE_QWORD, value=raw[16],
      }
    else
      local current = signed32(rotateLeft32(raw[12] ~ raw[8], raw[16]))
      local shift = raw[16] & 31
      local encodedLeft, encodedRight, encodedShift
      if spec.rekey then
        encodedLeft = TAG["自拟值"] & U32_MASK
        encodedRight = (TAG["自拟值"] ~ spec.value) & U32_MASK
        encodedShift = (raw[16] & 0xFFFF0000) | 32
      else
        encodedLeft = raw[8]
        encodedRight = (raw[8] ~
          rotateRight32(spec.value, shift)) & U32_MASK
        encodedShift = raw[16]
      end
      writes[#writes + 1] = {
        address=spec.address, flags=gg.TYPE_DWORD,
        value=(raw[0] ~ rotateLeft32(current ~ spec.value, 7)) & U32_MASK,
      }
      writes[#writes + 1] = {
        address=spec.address + 8, flags=gg.TYPE_DWORD,
        value=encodedLeft,
      }
      writes[#writes + 1] = {
        address=spec.address + 12, flags=gg.TYPE_DWORD,
        value=encodedRight,
      }
      writes[#writes + 1] = {
        address=spec.address + 16, flags=gg.TYPE_DWORD,
        value=encodedShift,
      }
    end
  end
  return writes
end

local function snapshotFromWrites(writes, specs)
  local snapshot, cursor = {}, 1
  for index, spec in ipairs(specs) do
    snapshot[index] = {}
    for _, offset in ipairs(transactionOffsets(spec.kind)) do
      snapshot[index][offset] = writes[cursor].value
      cursor = cursor + 1
    end
  end
  return snapshot
end

local function codecPlainFromSecondary(raw, kind)
  if kind == "key" then
    return rotateLeft32(raw[4] ~ TAG["自拟值"], raw[8]) & U32_MASK
  end
  if kind == "key5" then
    return rotateLeft32(raw[12] ~ raw[8], raw[16]) & U32_MASK
  end
  if kind == "key64" then
    return rotateLeft64(
      raw[8] ~ runtime.codecSelfValue64, codec64Shift(raw[16])
    )
  end
  return nil
end

local function validateCodecPrimaryConsistency(actual, original, specs, label)
  for index, spec in ipairs(specs) do
    if spec.kind == "key" or spec.kind == "key5" or
       spec.kind == "key64" then
      local beforePlain = codecPlainFromSecondary(original[index], spec.kind)
      local afterPlain = codecPlainFromSecondary(actual[index], spec.kind)
      local actualDelta = actual[index][0] ~ original[index][0]
      local expectedDelta
      if spec.kind == "key64" then
        expectedDelta = rotateCodecPrimaryDelta64(beforePlain ~ afterPlain)
      else
        actualDelta = actualDelta & U32_MASK
        expectedDelta = rotateLeft32(beforePlain ~ afterPlain, 7)
      end
      if actualDelta ~= expectedDelta then
        error((spec.label or label) ..
          "主副本与解码副本不一致，已拒绝保留写入", 0)
      end
    end
  end
  return true
end

local function rollbackTransaction(specs, original, expected, validator, label)
  validateTransactionIdentity(validator, label .. "回滚")
  local first = readTransactionSnapshot(specs)
  for index, spec in ipairs(specs) do
    local flags = transactionFlags(spec)
    for _, offset in ipairs(transactionOffsets(spec.kind)) do
      local current = first[index][offset]
      if not sameRawValue(current, original[index][offset], flags) and
         not sameRawValue(current, expected[index][offset], flags) then
        error(label .. "回滚所有权校验失败，已拒绝写入旧地址", 0)
      end
    end
  end
  validateTransactionIdentity(validator, label .. "回滚")
  local second = readTransactionSnapshot(specs)
  if not sameTransactionSnapshot(first, second, specs) then
    error(label .. "回滚前字段仍在变化，已拒绝写入旧地址", 0)
  end
  validateTransactionIdentity(validator, label .. "回滚")
  Memory.writeMany(transactionWrites(original, specs, true))
  validateTransactionIdentity(validator, label .. "回滚")
  local restored = readTransactionSnapshot(specs)
  if not sameTransactionSnapshot(original, restored, specs) then
    error(label .. "回滚写后验证失败", 0)
  end
  return true
end

local function runWithTargetPaused(label, callback)
  if type(gg.processPause) ~= "function" or
     type(gg.processResume) ~= "function" then
    error(label .. "缺少目标进程暂停接口，已拒绝非原子 codec 写入", 0)
  end
  local paused, pauseProblem = pcall(gg.processPause)
  if not paused then
    error(label .. "无法暂停目标进程：" .. tostring(pauseProblem), 0)
  end
  local ok, result = pcall(callback)
  local resumed, resumeProblem = pcall(gg.processResume)
  if not resumed then
    if ok then
      error(label .. "写入完成但恢复目标进程失败：" ..
        tostring(resumeProblem), 0)
    end
    error(label .. "失败且恢复目标进程失败：" .. tostring(result) ..
      "；" .. tostring(resumeProblem), 0)
  end
  if not ok then error(result, 0) end
  return result
end

function Transaction.write(inputSpecs, options)
  options = options or {}
  local label = options.label or "内存事务"
  local validator = options.validateIdentity
  local appliedValidator = options.validateApplied
  if appliedValidator ~= nil and type(appliedValidator) ~= "function" then
    error(label .. "写后验证器无效", 0)
  end
  local specs = normalizeTransactionSpecs(inputSpecs)
  local singleSnapshot = options.singleSnapshot == true

  local function validateApplied(actual, expected, original)
    validateCodecPrimaryConsistency(actual, original, specs, label)
    if appliedValidator then
      local accepted = appliedValidator(actual, expected, original, specs)
      if accepted == false then error(label .. "写后语义验证失败", 0) end
      return true
    end
    if not sameTransactionSnapshot(actual, expected, specs) then
      error(label .. "写后原始字段验证失败", 0)
    end
    return true
  end

  local function validateOriginal(original)
    if type(options.validateOriginal) == "function" then
      local accepted = options.validateOriginal(original, specs)
      if accepted == false then error(label .. "写前值校验失败", 0) end
    end
  end

  local function executeWrite()
    local original
    if singleSnapshot then
      original = readTransactionSnapshot(specs)
      validateOriginal(original)
      validateTransactionIdentity(validator, label)
    else
      validateTransactionIdentity(validator, label)
      local first = readTransactionSnapshot(specs)
      validateTransactionIdentity(validator, label)
      original = readTransactionSnapshot(specs)
      if not sameTransactionSnapshot(first, original, specs) then
        error(label .. "写入前字段仍在变化，请稍后重试", 0)
      end
      validateOriginal(original)
      validateTransactionIdentity(validator, label)
    end

    local expectedWrites = transactionWrites(original, specs, false)
    local expected = snapshotFromWrites(expectedWrites, specs)
    local ok, problem = pcall(function()
      Memory.writeMany(expectedWrites)
      if not singleSnapshot then validateTransactionIdentity(validator, label) end
      local actual = readTransactionSnapshot(specs)
      validateApplied(actual, expected, original)
      validateTransactionIdentity(validator, label)
    end)
    if ok then return true end

    local restored, restoreProblem = pcall(
      rollbackTransaction, specs, original, expected, validator, label
    )
    if restored then
      error(label .. "失败，已安全恢复原值：" .. tostring(problem), 0)
    end
    error(label .. "失败；为避免污染新对象未强制回滚：" ..
      tostring(problem) .. "；" .. tostring(restoreProblem), 0)
  end

  if options.pauseTarget ~= false then
    for _, spec in ipairs(specs) do
      if spec.kind ~= "raw" then
        return runWithTargetPaused(label, executeWrite)
      end
    end
  end
  return executeWrite()
end

requireInteger = function(value, minimum, maximum, label)
  local number = tonumber(value)
  if not number or number ~= number or number == math.huge or
     number == -math.huge or number ~= math.floor(number) or
     number < minimum or number > maximum then
    error(string.format(
      "%s必须是 %d 到 %d 之间的整数",
      label or "输入值", minimum, maximum
    ), 0)
  end
  return number
end

local function requireNumber(value, minimum, maximum, label)
  local number = tonumber(value)
  if not number or number ~= number or number == math.huge or
     number == -math.huge or number < minimum or number > maximum then
    error(string.format(
      "%s必须是 %s 到 %s 之间的数字",
      label or "输入值", tostring(minimum), tostring(maximum)
    ), 0)
  end
  return number
end

local function floatToDword(value)
  value = requireNumber(value, -3.4e38, 3.4e38, "浮点数值")
  return string.unpack("<I4", string.pack("<f", value))
end

function Codec.writeMany(items, options)
  if type(items) ~= "table" or #items == 0 then return true end
  local specs = {}
  for index, item in ipairs(items) do
    specs[index] = {
      kind="key", address=item.address, value=item.value,
      label=item.label,
    }
  end
  return Transaction.write(specs, options or {label="批量加密数值"})
end

function Codec.transaction(specs, options)
  return Transaction.write(specs, options)
end

function Codec.verifyWrites(items, label)
  if #items == 0 then return true end
  local decoded = Codec.decodeMany(items)
  for index, item in ipairs(items) do
    if decoded[index] == nil or not sameU32(decoded[index], item.value) then
      error((label or "加密数值") .. "写后验证失败", 0)
    end
  end
  return true
end

function Codec.writeVerified(items, label, validateIdentity)
  if #items == 0 then error("没有可写入的" .. (label or "数值"), 0) end
  Codec.writeMany(items, {
    label=label or "加密数值",
    validateIdentity=validateIdentity,
  })
  return Codec.verifyWrites(items, label)
end

local RestoreJournal = {entries={}, order={}}

local function restoreSame(kind, left, right)
  if left == nil or right == nil then return false end
  if kind == "key" then return sameU32(left, right) end
  if kind == "float" then
    return math.abs(left - right) <=
      math.max(0.000001, math.abs(right) * 0.00001)
  end
  return left == right
end

local function restoreRead(kind, entries)
  if kind == "key" then return Codec.decodeMany(entries) end
  if kind == "key64" then return Codec.decode64Many(entries) end
  local requests = {}
  for index, entry in ipairs(entries) do
    requests[index] = {address=entry.address, flags=gg.TYPE_FLOAT}
  end
  local values = Memory.readMany(requests)
  local result = {}
  for index, value in ipairs(values) do result[index] = tonumber(value.value) end
  return result
end

function RestoreJournal.capture(label, kind, items, validate)
  local fresh = {}
  for _, item in ipairs(items) do
    local key = kind .. ":" .. tostring(item.address)
    local entry = RestoreJournal.entries[key]
    if entry then
      entry.applied, entry.validate, entry.label = item.value, validate, label
    else
      fresh[#fresh + 1] = {
        key=key, kind=kind, label=label, address=item.address,
        applied=item.value, validate=validate,
      }
    end
  end
  if #fresh == 0 then return end
  local originals = restoreRead(kind, fresh)
  for index, entry in ipairs(fresh) do
    entry.original = originals[index]
    RestoreJournal.entries[entry.key] = entry
    RestoreJournal.order[#RestoreJournal.order + 1] = entry.key
  end
end

function RestoreJournal.count()
  return #RestoreJournal.order
end

function RestoreJournal.restore()
  local valid, groups = {}, {key={}, key64={}, float={}}
  local result = {total=0, restored=0, skipped=0}
  for _, key in ipairs(RestoreJournal.order) do
    local entry = RestoreJournal.entries[key]
    if entry then
      result.total = result.total + 1
      local ok = true
      if type(entry.validate) == "function" then
        if valid[entry.validate] == nil then
          local called, accepted = pcall(entry.validate)
          valid[entry.validate] = called and accepted ~= false
        end
        ok = valid[entry.validate]
      end
      if ok then
        table.insert(groups[entry.kind], entry)
      else
        result.skipped = result.skipped + 1
      end
    end
  end
  local specs, used = {}, {}
  for kind, list in pairs(groups) do
    if #list > 0 then
      local current = restoreRead(kind, list)
      for index, entry in ipairs(list) do
        if restoreSame(kind, current[index], entry.applied) and
           not restoreSame(kind, current[index], entry.original) then
          specs[#specs + 1] = {
            kind=kind == "float" and "raw" or kind,
            flags=kind == "float" and gg.TYPE_FLOAT or nil,
            address=entry.address,
            value=entry.original,
            label=entry.label .. "恢复",
          }
          if type(entry.validate) == "function" then
            used[entry.validate] = true
          end
        elseif not restoreSame(kind, current[index], entry.original) then
          result.skipped = result.skipped + 1
        end
      end
    end
  end
  if #specs > 0 then
    Transaction.write(specs, {
      label="一键恢复",
      validateIdentity=function()
        for validate in pairs(used) do
          if validate() == false then error("恢复对象已经变化", 0) end
        end
        return true
      end,
      validateApplied=function() return true end,
    })
    result.restored = #specs
  end
  RestoreJournal.entries, RestoreJournal.order = {}, {}
  return result
end

local STRING_REQUEST_BUDGET = 8192

local function appendStringRequests(requests, address, length, rangeEnd)
  local words = math.max(0, math.min(length, rangeEnd - address)) // 8
  for index = 0, words - 1 do
    requests[#requests + 1] = {
      address=address + index * 8, flags=gg.TYPE_QWORD,
    }
  end
  for offset = words * 8, length - 1 do
    requests[#requests + 1] = {address=address + offset, flags=gg.TYPE_BYTE}
  end
  return words
end

local function decodeStringValues(values, first, length, words)
  local chars = {}
  local index = first
  for _ = 1, words do
    local value = values[index].value
    for shift = 0, 56, 8 do
      local byte = (value >> shift) & 0xFF
      if byte == 0 then return table.concat(chars) end
      chars[#chars + 1] = string.char(byte)
    end
    index = index + 1
  end
  for _ = words * 8 + 1, length do
    local byte = values[index].value & 0xFF
    if byte == 0 then break end
    chars[#chars + 1] = string.char(byte)
    index = index + 1
  end
  return table.concat(chars)
end

local function requireStringLength(maximumBytes)
  maximumBytes = tonumber(maximumBytes or 32)
  if not maximumBytes or maximumBytes ~= math.floor(maximumBytes) or
     maximumBytes < 1 or maximumBytes > 4096 then
    error("字符串最大长度无效", 0)
  end
  return math.floor(maximumBytes)
end

function Memory.readString(pointerField, maximumBytes)
  maximumBytes = maximumBytes or 32
  pointerField = requireMapped(pointerField, 8, "字符串指针字段")
  local stringAddress = Memory.pointer(pointerField)
  local range = mappedRange(stringAddress, 1)
  if not range then return "" end
  local length = math.min(maximumBytes, range["end"] - stringAddress + 1)
  local requests = {}
  local words = appendStringRequests(
    requests, stringAddress, length, range["end"]
  )
  return decodeStringValues(Memory.readMany(requests), 1, length, words)
end

function Memory.readStringsAt(pointers, maximumBytes)
  if type(pointers) ~= "table" then error("字符串指针列表无效", 0) end
  maximumBytes = requireStringLength(maximumBytes)

  local ranges = refreshRanges(false)
  local sorted, overlapping = runtime.sortedRanges, runtime.rangesOverlap
  local lastRange
  local function locate(raw)
    local address = untagPointer(raw)
    if address == 0 then return nil end
    if lastRange and address >= lastRange.start and
       address <= lastRange["end"] then
      return lastRange, address
    end
    local range = findRange(ranges, sorted, overlapping, address, address)
    if not range then range = mappedRange(address, 1) end
    if range then lastRange = range end
    return range, address
  end

  local perItem = maximumBytes // 8 + maximumBytes % 8
  local batchItems = math.max(1, STRING_REQUEST_BUDGET // perItem)
  local names = {}
  local validCount, batchCount = 0, 0
  for first = 1, #pointers, batchItems do
    local last = math.min(first + batchItems - 1, #pointers)
    local requests, spans = {}, {}
    for index = first, last do
      names[index] = ""
      local range, address = locate(pointers[index])
      if range then
        local length = math.min(maximumBytes, range["end"] - address + 1)
        local start = #requests + 1
        local words = appendStringRequests(
          requests, address, length, range["end"]
        )
        spans[#spans + 1] = {
          index=index, start=start, length=length, words=words,
        }
        validCount = validCount + 1
      end
    end
    if #requests > 0 then
      batchCount = batchCount + 1
      local values = gg.getValues(requests)
      if type(values) ~= "table" or #values ~= #requests then
        error("批量字符串读取结果不完整", 0)
      end
      for _, span in ipairs(spans) do
        names[span.index] = decodeStringValues(
          values, span.start, span.length, span.words
        )
      end
    end
  end
  if #pointers >= 64 then
    trace(string.format(
      "memory readStrings items=%d valid=%d batches=%d bytes=%d",
      #pointers, validCount, batchCount, maximumBytes
    ))
  end
  return names
end

function Memory.readStdStrings(addresses, maximumBytes)
  maximumBytes = maximumBytes or 64
  local requests = {}
  for index, address in ipairs(addresses) do
    for word = 0, 2 do
      requests[(index - 1) * 3 + word + 1] = {
        address=address + word * 8, flags=gg.TYPE_QWORD,
      }
    end
  end
  local values = #requests > 0 and Memory.readMany(requests) or {}
  local result, longIndexes, longPointers = {}, {}, {}
  for index = 1, #addresses do
    local words = {}
    for word = 0, 2 do
      words[word + 1] = tonumber(values[(index - 1) * 3 + word + 1].value) or 0
    end
    local first = words[1] & 0xFF
    if first & 1 == 0 then
      local length = math.min(first >> 1, 22)
      local bytes = {}
      for position = 1, length do
        local word = words[(position >> 3) + 1]
        bytes[position] = string.char((word >> ((position & 7) * 8)) & 0xFF)
      end
      result[index] = table.concat(bytes)
    else
      longIndexes[#longIndexes + 1] = index
      longPointers[#longPointers + 1] = words[3]
      result[index] = ""
    end
  end
  if #longPointers > 0 then
    local texts = Memory.readStringsAt(longPointers, maximumBytes)
    for position, index in ipairs(longIndexes) do
      result[index] = texts[position] or ""
    end
  end
  return result
end

function Memory.readStrings(requests, maximumBytes)
  if type(requests) ~= "table" then error("字符串请求无效", 0) end
  maximumBytes = requireStringLength(maximumBytes)

  local names, pointerRequests, pointerOwners = {}, {}, {}
  for index, request in ipairs(requests) do
    names[index] = ""
    if type(request) == "table" and type(request.address) == "number" and
       mappedRange(request.address, 8) then
      pointerRequests[#pointerRequests + 1] = {
        address=untagPointer(request.address),
        flags=gg.TYPE_QWORD,
      }
      pointerOwners[#pointerOwners + 1] = index
    end
  end
  if #pointerRequests == 0 then return names end

  local pointerValues = Memory.readMany(pointerRequests)
  local pointers = {}
  for index, value in ipairs(pointerValues) do
    pointers[index] = tonumber(value.value) or 0
  end
  local decoded = Memory.readStringsAt(pointers, maximumBytes)
  for index, owner in ipairs(pointerOwners) do
    names[owner] = decoded[index]
  end
  return names
end

local function codecAddress(encodedLow, high, trailingOffset)
  local xorToken = runtime.pointerCodecTagPrefix |
                   (high & 0x00FFFFFF)
  local low = (encodedLow ~ xorToken) & U32_MASK
  low = (low + (trailingOffset or 0)) & U32_MASK
  return untagPointer((high << 32) | low)
end

local function showMenu(owner, title, labels, actions, multiSelect)
  local menu = {
    owner=owner,
    title=title,
    labels=labels,
    actions=actions,
    multiSelect=multiSelect == true,
  }
  if runtime.menuDispatching then
    runtime.queuedMenu = menu
    return
  end

  runtime.menuDispatching = true
  runtime.queuedMenu = menu
  while runtime.queuedMenu do
    local current = runtime.queuedMenu
    runtime.queuedMenu = nil
    runtime.activeMenu = current.owner
    local ok, problem = pcall(function()
      local selected
      if current.multiSelect then
        selected = gg.multiChoice(
          current.labels, nil, current.title
        )
        if not selected then return end
        for index = 1, #current.labels do
          if selected[index] then
            local action = current.actions[index]
            if type(action) ~= "function" then
              error("菜单功能不存在", 0)
            end
            action()
            if runtime.queuedMenu then break end
          end
        end
      else
        selected = gg.choice(
          current.labels, nil, current.title
        )
        if not selected then return end
        local action = current.actions[selected]
        if type(action) ~= "function" then
          error("菜单功能不存在", 0)
        end
        action()
      end
    end)
    if not ok then
      trace("menu error: " .. tostring(problem))
      if runtime.targetUnavailable == true then
        runtime.running = false
        break
      end
      gg.alert("功能未执行：" .. tostring(problem))
      break
    end
  end
  runtime.menuDispatching = false
end

local function validateTarget()
  local packageName = gg.getTargetPackage()
  local info = gg.getTargetInfo()
  if packageName ~= PROFILE.packageName then
    fatal("本脚本仅支持 " .. PROFILE.versionName .. " 渠道服：" ..
      PROFILE.packageName)
  end
  if type(info) ~= "table" or info.x64 ~= true then
    fatal("目标进程不是受支持的 ARM64 游戏进程")
  end
  if tonumber(info.versionCode) ~= PROFILE.versionCode then
    fatal(string.format(
      "仅支持 versionCode %d，当前为 %s",
      PROFILE.versionCode, tostring(info.versionCode)
    ))
  end
  if tostring(info.versionName or "") ~= PROFILE.versionName then
    fatal(string.format(
      "仅支持 versionName %s，当前为 %s",
      PROFILE.versionName, tostring(info.versionName)
    ))
  end
  local reportedAbi = info.abi or info.cpuAbi or info.primaryCpuAbi
  if reportedAbi ~= nil and tostring(reportedAbi) ~= PROFILE.abi then
    fatal(string.format(
      "仅支持 ABI %s，当前为 %s",
      PROFILE.abi, tostring(reportedAbi)
    ))
  end
  runtime.targetInfo = info
end

local function selectGameBase()
  local ranges = gg.getRangesList(PROFILE.gameModule)
  local selected = ranges[PROFILE.gameBaseRangeIndex]
  if not selected or type(selected.start) ~= "number" then
    fatal(PROFILE.gameModule .. " 尚未完整加载")
  end
  runtime.gameBase = selected.start
  runtime.gameRange = {
    start=selected.start,
    ["end"]=selected["end"],
    state=selected.state,
    name=selected.name,
  }
  trace(string.format(
    "gameBase=0x%X range=%s state=%s",
    selected.start,
    tostring(selected.name or PROFILE.gameModule),
    tostring(selected.state or "?")
  ))
end

local function configureSearchRegions()
  gg.setRanges(
    gg.REGION_C_BSS |
    gg.REGION_ANONYMOUS |
    gg.REGION_C_ALLOC |
    gg.REGION_C_DATA |
    gg.REGION_OTHER
  )
end

local function validateProfileOffsets()
  local offsets = {PROFILE.selfValueOffset}
  for _, offset in pairs(MODULE_OFFSET) do offsets[#offsets + 1] = offset end
  for _, offset in ipairs(offsets) do
    if offset < 0 or offset > PROFILE.maxRelativeOffset then
      fatal("渠道服模块偏移超出配置上限：" .. tostring(offset))
    end
    requireMapped(runtime.gameBase + offset, 8, "渠道服模块槽")
  end
end

local function initializeRuntime()
  runtime.traceFile = io.open(TRACE_PATH, "w")
  validateTarget()
  configureSearchRegions()
  selectGameBase()
  refreshRanges(true)
  validateProfileOffsets()
  TAG["自拟值"] = Memory.read(
    runtime.gameBase + PROFILE.selfValueOffset,
    gg.TYPE_DWORD
  )
  runtime.codecSelfValue64 = Memory.read(
    runtime.gameBase + PROFILE.selfValueOffset + PROFILE.selfValue64Offset,
    gg.TYPE_QWORD
  )
  trace("codec profile=vc" .. PROFILE.versionCode ..
    " rol7-primary fairy64-qword-r1")
  local rawA0High = Memory.read(
    runtime.gameBase + TAG["A0基址"] + 4,
    gg.TYPE_DWORD
  )
  runtime.pointerCodecTagPrefix = rawA0High & 0xFF000000
  trace(string.format(
    "initialized package=%s version=%s self=0x%X tag=0x%X",
    PROFILE.packageName,
    tostring(runtime.targetInfo.versionCode),
    TAG["自拟值"] & U32_MASK,
    runtime.pointerCodecTagPrefix
  ))
  trace("startup protection removed after channel A/B stack-corruption test")
end

local function copyArray(values)
  local result = {}
  for index = 1, #values do result[index] = values[index] end
  return result
end

local function trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function traceback(problem)
  if debug and type(debug.traceback) == "function" then
    return debug.traceback(tostring(problem), 2)
  end
  return tostring(problem)
end

local function gameBase()
  local base = runtime.gameBase
  if type(base) ~= "number" or base == 0 then
    error("游戏基址尚未初始化", 0)
  end
  return base
end

local function requirePath(name)
  local path = TAG[name]
  if type(path) ~= "table" and type(path) ~= "number" then
    error("指针路径缺失：" .. tostring(name), 0)
  end
  return path
end

local function requireField(name)
  local offset = FIELD[name]
  if type(offset) ~= "number" then
    error("字段偏移缺失：" .. tostring(name), 0)
  end
  return offset
end

local function resolveTag(name, size)
  return Memory.resolve(gameBase(), requirePath(name), size or 1)
end

local function actionError(label, problem)
  trace(label .. " failed: " .. tostring(problem))
  gg.alert(label .. "失败：" .. tostring(problem))
  return false
end

local SETTINGS_PATH = "/sdcard/qiyian_168_settings.txt"
local settings = {cache=nil}

function settings.load()
  if settings.cache then return settings.cache end
  local values = {}
  local file = io.open(SETTINGS_PATH, "r")
  if file then
    for line in file:lines() do
      local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
      if key then values[key] = value end
    end
    file:close()
  end
  settings.cache = values
  return values
end

function settings.get(key)
  return settings.load()[key]
end

function settings.set(key, value)
  local values = settings.load()
  values[key] = tostring(value)
  local file = io.open(SETTINGS_PATH, "w")
  if not file then error("无法写入设置文件：" .. SETTINGS_PATH, 0) end
  local keys = {}
  for name in pairs(values) do keys[#keys + 1] = name end
  table.sort(keys)
  for _, name in ipairs(keys) do file:write(name, "=", values[name], "\n") end
  file:close()
end

local actions = {}
local app = {
  PROFILE=PROFILE,
  TAG=TAG,
  FIELD=FIELD,
  PANEL_FIELDS=PANEL_FIELDS,
  runtime=runtime,
  Memory=Memory,
  Codec=Codec,
  Transaction=Transaction,
  runWithTargetPaused=runWithTargetPaused,
  requireInteger=requireInteger,
  requireNumber=requireNumber,
  floatToDword=floatToDword,
  untagPointer=untagPointer,
  codecAddress=codecAddress,
  rotateLeft32=rotateLeft32,
  sameU32=sameU32,
  restoreJournal=RestoreJournal,
  settings=settings,
  startupHooks={},
  copyArray=copyArray,
  trim=trim,
  traceback=traceback,
  trace=trace,
  gameBase=gameBase,
  requirePath=requirePath,
  requireField=requireField,
  resolveTag=resolveTag,
  actionError=actionError,
  U32_MASK=U32_MASK,
  POINTER_MASK=POINTER_MASK,
  MIN_VALID_POINTER=MIN_VALID_ADDRESS,
  FAIRY_SLOT_SIZE=24,
  FAIRY_MAX_SLOTS=16,
  PET_PHYSICAL_MAXIMUM=64,
}

local function targetProcessAvailable()
  local packageOk, packageName = pcall(gg.getTargetPackage)
  if not packageOk or packageName ~= PROFILE.packageName then
    return false, "目标包名已经不可用"
  end
  local rangesOk, ranges = pcall(gg.getRangesList, PROFILE.gameModule)
  if not rangesOk then
    return false, "读取目标模块映射失败：" .. tostring(ranges)
  end
  if type(ranges) ~= "table" then
    return false, "目标模块映射结果无效"
  end
  for _, range in ipairs(ranges) do
    if type(range) == "table" and type(range.start) == "number" and
       type(range["end"]) == "number" and range["end"] > range.start then
      return true
    end
  end
  return false, PROFILE.gameModule .. " 映射已经消失"
end

app.targetAvailable = targetProcessAvailable
local menus = {
  Main = {
    title="造梦西游 " .. PROFILE.versionName .. " 渠道服 · 版本 " ..
      SCRIPT_VERSION,
    items={
      {"🔍 搜值", action="sz"},
      {"👑 人物", menu="player"},
      {"⚔️ 物理", menu="physics"},
      {"🗺️ 地图", menu="map"},
      {"🔮 无中", menu="creation"},
      {"⬆️ 叠加", menu="stacking"},
      {"⚙️ 属性", menu="attributes"},
      {"🦋 宠物", menu="pet"},
      {"🎮 娱乐", menu="entertainment"},
      {"❌ 退出", action="quit"},
    },
  },
  player = {
    title="人物",
    items={
      {"📋 被动多选", action="beidongduoxuan"},
      {"💰 货币多选", action="huobiduoxuan"},
      {"⭐ 本命灵物", action="lingbenziding"},
      {"🌱 经验多选", action="jingyanduoxuan"},
      {"↩️ 返回上页", menu="Main"},
    },
  },
  physics = {
    title="物理",
    multiple=true,
    items={
      {"🚀 自定加速", action="jiasu"},
      {"🔘 一键物理(监听)", action="yjwl"},
      {"🗿 一键荒古物理", action="hgwl"},
      {"🏷️ 称号秒杀", action="chenghao"},
      {"🛡️ 护盾无敌", action="hudun"},
      {"⚡ 倍率秒杀", action="beilv"},
      {"✨ 仙术普攻", action="xspg"},
      {"👻 人物隐身", action="yinshen"},
      {"⚙️ 面板属性", action="mbsx"},
      {"♻️ 一键恢复", action="wlhf"},
      {"↩️ 返回上页", menu="Main"},
    },
  },
  map = {
    title="地图",
    multiple=true,
    items={
      {"🚫 关闭指引（可设自动）", action="guanbizhiyin"},
      {"👹 地图无怪", action="dituwuguai"},
      {"🏔️ 昆仑跳层", action="kunlunshan"},
      {"🚫 无怪恢复", action="dituhuifu"},
      {"↩️ 返回上页", menu="Main"},
    },
  },
  creation = {
    title="无中",
    items={
      {"🔄 合成替换", menu="synthesis"},
      {"🥚 宠物无中", menu="pet_creation"},
      {"↩️ 返回上页", menu="Main"},
    },
  },
  synthesis = {
    title="合成替换",
    items={
      {"🔍 检索录入", action="jiansuo"},
      {"✏️ 自定录入", action="zdlr"},
      {"📂 装备分类", menu="materials"},
      {"✅ 开始替换", action="kaishitihuan"},
      {"↩️ 返回上页", menu="creation"},
    },
  },
  materials = {
    title="装备分类",
    multiple=true,
    items={
      {"💎 一键录入法宝材料", action="fbcl"},
      {"👗 一键录入时装", action="szcl"},
      {"⭐ 一键录入本命相关", action="bmcl"},
      {"🧰 一键录入材料", action="cailiaoluru"},
      {"↩️ 返回上页", menu="synthesis"},
    },
  },
  pet_creation = {
    title="宠物无中",
    items={
      {"🔍 检索宠物", action="huoquchong"},
      {"🥚 开始无中", action="wuzhongchong"},
      {"🐣 全融灵宠", action="quanrongling"},
      {"↩️ 返回上页", menu="creation"},
    },
  },
  stacking = {
    title="叠加",
    items={
      {"🔍 搜值叠加", action="diejia"},
      {"📌 记录辅助", action="jilufuzhu"},
      {"♻️ 乾坤叠加", action="xunhuandiejia"},
      {"↩️ 返回上页", menu="Main"},
    },
  },
  attributes = {
    title="属性",
    items={
      {"🔮 启灵四孔", action="qilingquankai"},
      {"⭐ 自定启灵", action="zidingqiling"},
      {"🔓 孔内阶级", action="qilingjieji"},
      {"🔧 自定属性", action="zdsx"},
      {"🏆 装备品质", action="zbpz"},
      {"👑 一键完美传说", action="wmcs"},
      {"🔥 一键完美业力", action="wmyl"},
      {"↩️ 返回上页", menu="Main"},
    },
  },
  pet = {
    title="宠物",
    items={
      {"⭐ 宠物等级", action="PetLevel"},
      {"🔥 涅槃全开", action="Nirvana"},
      {"📊 宠物资质", action="Aptitude"},
      {"💪 宠物根骨", action="Talent"},
      {"🔩 宠物阶数", action="tire"},
      {"✨ 宠物裂变（同种无中）", action="Division"},
      {"👻 宠物消失", action="vanish"},
      {"💫 全宠休息", action="qcxx"},
      {"↩️ 返回上页", menu="Main"},
    },
  },
  entertainment = {
    title="娱乐",
    items={
      {"🎉 欢乐任务", action="huanle"},
      {"💕 全局任务", action="qjrw"},
      {"🎲 自定掉落", action="Drop"},
      {"♻️ 恢复掉落", action="DropRestore"},
      {"↩️ 返回上页", menu="Main"},
    },
  },
}

local PENDING = {
  huanle="任务基址路径未核对",
}

local function registerActions(moduleActions)
  if type(moduleActions) ~= "table" then return end
  for name, action in pairs(moduleActions) do
    if type(action) == "function" then
      if actions[name] then error("重复注册功能：" .. name, 0) end
      local pending = PENDING[name]
      if pending then
        actions[name] = function()
          gg.alert("该功能尚未适配 " .. PROFILE.versionName .. "：" .. pending)
          return false
        end
      else
        actions[name] = action
      end
    end
  end
end

local function installModule(key, factory)
  local module = factory(app)
  app[key] = module
  registerActions(module.actions)
  return module
end

installModule("Listener", function(app)
  local runtime = app.runtime
  local trace = app.trace
  local traceback = app.traceback
  local Listener = {}

  local HARD_MIN_POLL_MS = 50
  local FAST_MIN_POLL_MS = 1
  local DEFAULT_POLL_MS = 100
  local SIGNAL_KEY = {}

  Listener.MIN_POLL_MS = HARD_MIN_POLL_MS
  Listener.FAST_MIN_POLL_MS = FAST_MIN_POLL_MS

  local function traceLine(message)
    pcall(trace, "listener: " .. tostring(message))
  end

  local function signal(kind, reason, value)
    return {
      [SIGNAL_KEY] = kind,
      reason = reason,
      value = value,
    }
  end

  function Listener.stop(reason, value)
    return signal("stop", reason or "stopped", value)
  end

  function Listener.retry(reason)
    return signal("retry", reason or "retry")
  end

  function Listener.requestRecover(problem)
    return signal("recover", problem or "recovery requested")
  end

  local function signalKind(value)
    return type(value) == "table" and value[SIGNAL_KEY] or nil
  end

  local function finiteNumber(value)
    local number = tonumber(value)
    if not number or number ~= number or
       number == math.huge or number == -math.huge then
      return nil
    end
    return number
  end

  local function minimumPollMs()
    local configured = finiteNumber(runtime.listenerMinPollMs)
    if configured then
      configured = math.floor(configured)
    end
    return math.max(HARD_MIN_POLL_MS, configured or HARD_MIN_POLL_MS)
  end

  local function pollMs(value, allowFastPoll)
    local interval = finiteNumber(value) or DEFAULT_POLL_MS
    interval = math.floor(interval)
    local minimum = allowFastPoll == true and
      FAST_MIN_POLL_MS or minimumPollMs()
    return math.max(minimum, interval)
  end

  local function timeoutMs(value)
    if value == nil or value == false then return nil end
    local timeout = finiteNumber(value)
    if not timeout or timeout < 0 then
      error("timeoutMs 必须是非负数", 0)
    end
    return math.floor(timeout)
  end

  local function ggApi()
    local api = rawget(_G, "gg")
    if type(api) ~= "table" then
      error("GG API 不可用", 0)
    end
    return api
  end

  local function isGgVisible()
    local api = ggApi()
    if type(api.isVisible) ~= "function" then
      error("gg.isVisible 不可用", 0)
    end
    return api.isVisible() == true
  end

  local function hideGg()
    local api = ggApi()
    if type(api.setVisible) ~= "function" then
      error("gg.setVisible 不可用", 0)
    end
    api.setVisible(false)
  end

  local function sleep(milliseconds)
    local api = ggApi()
    if type(api.sleep) ~= "function" then
      error("gg.sleep 不可用", 0)
    end
    local ok, problem = pcall(api.sleep, milliseconds)
    if ok then return true end
    local message = tostring(problem)
    if message:find("InterruptedException", 1, true) or
       message:lower():find("interrupted", 1, true) then
      traceLine("sleep interrupted; resume polling: " .. message)
      return false, message
    end
    error(problem, 0)
  end

  local function makeClock(spec)
    local custom = spec.nowMs
    if type(custom) ~= "function" then custom = app.nowMs end
    if type(custom) ~= "function" then custom = runtime.nowMs end

    return function()
      if type(custom) == "function" then
        local okCustom, customValue = pcall(custom)
        local value = okCustom and finiteNumber(customValue) or nil
        if value then return math.floor(value) end
      end
      return os.time() * 1000
    end
  end

  local function callback(fn, ...)
    return xpcall(fn, traceback, ...)
  end

  local function applyStop(outcome, control, fallbackReason)
    outcome.reason = control.reason or fallbackReason or "stopped"
    outcome.value = control.value
  end

  local function runEarlyCleanup(spec, outcome, context)
    if type(spec) ~= "table" or type(spec.cleanup) ~= "function" then
      return outcome
    end
    context = context or {
      name=tostring(spec.name or "invalid_listener"),
      runtime=runtime,
      phase="cleanup",
      iterations=0,
      elapsedMs=0,
    }
    local ok, problem = callback(
      spec.cleanup, spec.initialState, outcome, context
    )
    if not ok then outcome.cleanupError = tostring(problem) end
    return outcome
  end

  local function invalidRun(problem, spec)
    local outcome = {
      ok = false,
      reason = "invalid_options",
      error = tostring(problem),
      iterations = 0,
      elapsedMs = 0,
    }
    return runEarlyCleanup(spec, outcome)
  end

  function Listener.run(spec)
    if type(spec) ~= "table" then
      return invalidRun("监听配置必须是 table", spec)
    end
    if type(spec.tick) ~= "function" then
      return invalidRun("监听器缺少 tick", spec)
    end
    if spec.acquire ~= nil and type(spec.acquire) ~= "function" then
      return invalidRun("acquire 必须是 function", spec)
    end
    if spec.recover ~= nil and type(spec.recover) ~= "function" then
      return invalidRun("recover 必须是 function", spec)
    end
    if spec.cleanup ~= nil and type(spec.cleanup) ~= "function" then
      return invalidRun("cleanup 必须是 function", spec)
    end

    local okOptions, intervalOrProblem, timeoutOrProblem = pcall(function()
      return pollMs(spec.intervalMs, spec.allowFastPoll == true),
        timeoutMs(spec.timeoutMs)
    end)
    if not okOptions then return invalidRun(intervalOrProblem, spec) end

    local interval = intervalOrProblem
    local timeout = timeoutOrProblem
    local targetProbeInterval = math.max(
      HARD_MIN_POLL_MS,
      math.floor(finiteNumber(spec.targetProbeIntervalMs) or 1000)
    )
    local targetMissLimit = math.max(
      1, math.floor(finiteNumber(spec.targetMissLimit) or 2)
    )
    local now = makeClock(spec)
    local startedAt = now()
    local sleptMs = 0
    local state = spec.initialState
    local needsAcquire = type(spec.acquire) == "function"
    local outcome = {
      ok = false,
      reason = nil,
      iterations = 0,
      intervalMs = interval,
      startedAt = startedAt,
      elapsedMs = 0,
    }
    local targetMisses = 0
    local nextTargetProbeAt = 0

    runtime.listenerSequence = (tonumber(runtime.listenerSequence) or 0) + 1
    local name = tostring(spec.name or ("listener_" .. runtime.listenerSequence))
    runtime.listeners = type(runtime.listeners) == "table" and
                        runtime.listeners or {}
    runtime.listenerLastExit = type(runtime.listenerLastExit) == "table" and
                               runtime.listenerLastExit or {}

    if runtime.listeners[name] ~= nil then
      outcome.reason = "already_running"
      outcome.error = "同名监听器已在运行: " .. name
      return runEarlyCleanup(spec, outcome, {
        name=name,
        runtime=runtime,
        intervalMs=interval,
        timeoutMs=timeout,
        startedAt=startedAt,
        phase="cleanup",
        iterations=0,
        elapsedMs=0,
      })
    end

    local record = {
      name = name,
      phase = "starting",
      startedAt = startedAt,
      intervalMs = interval,
    }
    runtime.listeners[name] = record

    local context = {
      name = name,
      runtime = runtime,
      intervalMs = interval,
      timeoutMs = timeout,
      startedAt = startedAt,
    }

    local function elapsedMs()
      local wallElapsed = now() - startedAt
      if wallElapsed < 0 then wallElapsed = 0 end
      return math.max(math.floor(wallElapsed), sleptMs)
    end

    local function updatePhase(phase)
      context.phase = phase
      context.iterations = outcome.iterations
      context.elapsedMs = elapsedMs()
      record.phase = phase
      record.iterations = outcome.iterations
      record.elapsedMs = context.elapsedMs
    end

    local function fail(reason, problem, phase)
      outcome.reason = reason
      outcome.error = tostring(problem)
      outcome.phase = phase
      traceLine(string.format(
        "%s %s failed: %s", name, tostring(phase), tostring(problem)
      ))
    end

    local function recover(problem, failedPhase)
      if type(spec.recover) ~= "function" then
        fail("error", problem, failedPhase)
        return false
      end

      updatePhase("recover")
      local okRecover, recovered = callback(
        spec.recover, problem, state, context, failedPhase
      )
      if not okRecover then
        outcome.reason = "recover_error"
        outcome.error = tostring(problem)
        outcome.recoveryError = tostring(recovered)
        outcome.phase = failedPhase
        traceLine(string.format(
          "%s recovery failed after %s: %s",
          name, tostring(failedPhase), tostring(recovered)
        ))
        return false
      end

      local kind = signalKind(recovered)
      if kind == "stop" then
        applyStop(outcome, recovered, "recover_stopped")
        return false
      end
      if kind == "retry" then
        needsAcquire = type(spec.acquire) == "function"
        return true
      end
      if kind == "recover" then
        fail("recover_error", "recover 返回了递归恢复请求", failedPhase)
        return false
      end

      if recovered ~= nil then state = recovered end
      needsAcquire = false
      return true
    end

    local function handleControl(control, phase)
      local kind = signalKind(control)
      if kind == "stop" then
        applyStop(outcome, control, "stopped")
        return false
      end
      if kind == "retry" then
        needsAcquire = type(spec.acquire) == "function"
        if not needsAcquire then
          fail("error", "收到 retry，但监听器没有 acquire", phase)
          return false
        end
        return true
      end
      if kind == "recover" then
        return recover(control.reason, phase)
      end
      return nil
    end

    local function checkExit()
      updatePhase("poll")
      if type(app.cleanupOwnedFreezes) == "function" then
        app.cleanupOwnedFreezes(false)
      end
      if spec.watchTarget ~= false and
         type(app.targetAvailable) == "function" and
         elapsedMs() >= nextTargetProbeAt then
        nextTargetProbeAt = elapsedMs() + targetProbeInterval
        local okTarget, available, targetProblem = callback(
          app.targetAvailable, context
        )
        if okTarget and available == true then
          targetMisses = 0
        else
          targetMisses = targetMisses + 1
          local problem = okTarget and targetProblem or available
          traceLine(string.format(
            "%s target missing count=%d/%d problem=%s",
            name, targetMisses, targetMissLimit, tostring(problem)
          ))
          if targetMisses >= targetMissLimit then
            runtime.targetUnavailable = true
            outcome.reason = "target_unavailable"
            outcome.value = tostring(problem or "目标进程不可用")
            return true
          end
        end
      end
      if spec.cancelOnVisible ~= false and isGgVisible() then
        if spec.hideOnCancel == true then hideGg() end
        outcome.reason = "cancelled"
        outcome.cancelled = true
        return true
      end
      if timeout ~= nil and elapsedMs() >= timeout then
        outcome.reason = "timeout"
        outcome.timedOut = true
        return true
      end
      return false
    end

    local function execute()
      traceLine(string.format("%s started interval=%dms", name, interval))
      while outcome.reason == nil do
        if checkExit() then break end

        if needsAcquire then
          updatePhase("acquire")
          local okAcquire, acquired = callback(spec.acquire, context)
          if not okAcquire then
            if not recover(acquired, "acquire") then break end
          else
            local handled = handleControl(acquired, "acquire")
            if handled == false then break end
            if handled == nil then
              state = acquired
              needsAcquire = false
            end
          end
        else
          updatePhase("tick")
          local okTick, tickResult = callback(spec.tick, state, context)
          outcome.iterations = outcome.iterations + 1
          if not okTick then
            if not recover(tickResult, "tick") then break end
          else
            local handled = handleControl(tickResult, "tick")
            if handled == false then break end
            if handled == nil and tickResult == true then
              outcome.reason = "completed"
              outcome.ok = true
              break
            end
          end
        end

        if outcome.reason == nil then
          updatePhase("sleep")
          local slept = sleep(interval)
          if slept then sleptMs = sleptMs + interval end
        end
      end
    end

    local okRun, runProblem = xpcall(execute, traceback)
    if not okRun and outcome.reason == nil then
      fail("error", runProblem, context.phase or "run")
    end

    updatePhase("cleanup")
    if type(spec.cleanup) == "function" then
      local okCleanup, cleanupProblem = callback(
        spec.cleanup, state, outcome, context
      )
      if not okCleanup then
        outcome.cleanupError = tostring(cleanupProblem)
        if outcome.reason == nil or outcome.ok == true then
          outcome.reason = "cleanup_error"
          outcome.error = outcome.cleanupError
          outcome.ok = false
        end
        traceLine(string.format(
          "%s cleanup failed: %s", name, tostring(cleanupProblem)
        ))
      end
    end

    if outcome.reason == nil then outcome.reason = "stopped" end
    if outcome.reason == "completed" then outcome.ok = true end
    outcome.finishedAt = now()
    outcome.elapsedMs = elapsedMs()
    outcome.state = state

    record.phase = "finished"
    record.reason = outcome.reason
    record.finishedAt = outcome.finishedAt
    record.elapsedMs = outcome.elapsedMs
    runtime.listenerLastExit[name] = outcome
    if runtime.listeners[name] == record then
      runtime.listeners[name] = nil
    end

    traceLine(string.format(
      "%s exited reason=%s iterations=%d elapsed=%dms",
      name, tostring(outcome.reason), outcome.iterations, outcome.elapsedMs
    ))
    return outcome
  end

  function Listener.pollMenuVisibility(spec)
    if type(spec) == "function" then spec = {onVisible = spec} end
    if type(spec) ~= "table" or type(spec.onVisible) ~= "function" then
      return invalidRun("主菜单轮询缺少 onVisible")
    end

    local stats = {
      visibleCount = 0,
      errorCount = 0,
      lastError = nil,
      visibleArmed = spec.suppressInitialVisible ~= true,
    }
    local function stopFromHandler(result, fallbackReason)
      if signalKind(result) == "stop" then return result end
      if result == false then return Listener.stop(fallbackReason) end
      return nil
    end

    local report = Listener.run({
      name = spec.name or "main_menu_visibility",
      intervalMs = spec.intervalMs,
      timeoutMs = spec.timeoutMs,
      nowMs = spec.nowMs,
      watchTarget = spec.watchTarget,
      targetProbeIntervalMs = spec.targetProbeIntervalMs,
      targetMissLimit = spec.targetMissLimit,
      cancelOnVisible = false,
      initialState = stats,
      tick = function(_, context)
        if type(spec.onPoll) == "function" then
          spec.onPoll(context, stats)
        end
        local visible = isGgVisible()
        if not stats.visibleArmed then
          if visible and spec.hideOnVisible ~= false then hideGg() end
          stats.visibleArmed = true
          return nil
        end
        if not visible then return nil end
        if spec.hideOnVisible ~= false then hideGg() end
        stats.visibleCount = stats.visibleCount + 1

        local okVisible, result = callback(spec.onVisible, context, stats)
        if okVisible then
          return stopFromHandler(result, "menu_stopped")
        end

        stats.errorCount = stats.errorCount + 1
        stats.lastError = tostring(result)
        traceLine(string.format(
          "%s onVisible failed: %s", context.name, tostring(result)
        ))

        if type(spec.onError) == "function" then
          local okError, decision = callback(
            spec.onError, result, context, stats
          )
          if not okError then
            stats.errorCount = stats.errorCount + 1
            stats.lastError = tostring(decision)
            traceLine(string.format(
              "%s onError failed: %s", context.name, tostring(decision)
            ))
          else
            local stop = stopFromHandler(decision, "menu_error")
            if stop then return stop end
          end
        end

        if spec.stopOnError == true then
          return Listener.stop("menu_error", result)
        end
        return nil
      end,
      cleanup = spec.cleanup and function(_, outcome, context)
        return spec.cleanup(stats, outcome, context)
      end or nil,
    })

    report.visibleCount = stats.visibleCount
    report.errorCount = stats.errorCount
    report.lastError = stats.lastError
    return report
  end

  return Listener
end)

installModule("items", function(app)
  local Memory = app.Memory
  local Codec = app.Codec
  local Transaction = app.Transaction
  local TAG = app.TAG
  local FIELD = app.FIELD
  local runtime = app.runtime
  local Listener = app.Listener
  local requireInteger = app.requireInteger
  local copyArray = app.copyArray
  local trace = app.trace

  local TYPE_DWORD = gg.TYPE_DWORD
  local TYPE_QWORD = gg.TYPE_QWORD
  local POINTER_MASK = app.POINTER_MASK

  local LIMIT = {
    nodes = 100000,
    groupItems = 100000,
    recordedIds = 100000,
  }

  local OFFSET = {
    nodeItemPath = {0x108, 0x18, 0},
    nextNode = 0x120,
    groupArray = 0x10,
    groupNamePathPrefix = {0, 0, 0x18},
    defaultGroupName = 0x30,
    slotObject = 0x18,
    catalogId = 0x08,
    catalogName = 0x30,
    catalogEnabled = 0x38,
    replacementCost = 0x88,
    replacementLinks = 0x1C8,
    replacementLinkValue = 0x0C,
    replacementId = 0x258,
  }

  local CATALOG_GROUP_NAMES = {
    "玄铁",
    "行者棍",
    "枯叶灵",
    "1级生命石",
    "尾火棍制作书",
    "涅槃丹∙攻(优秀)",
    "启灵珠∙血（优秀）",
    "乾（优秀）",
  }

  local PRESET_IDS = {
    fbcl = {3301, 4501, 500200, 1302, 2502, 500203},
    szcl = {
      503194, 503195, 503196,
      503512, 503513, 503514,
    },
    bmcl = {
      503148, 503149, 503154, 503382,
      509200, 509201, 509202, 509203,
    },
    cailiaoluru = {
      503012, 502135, 502284, 503119, 503120,
      503388, 503389, 503115, 904060, 904070,
      904080, 904090, 904100, 904110,
      9315, 9512, 500221,
    },
  }

  local state = {
    catalogLoaded = false,
    catalogGeneration = 0,
    catalogNames = {},
    catalogIds = {},
    catalogEntries = {},
    recordedIds = {},
  }

  local function clearArray(items)
    for key in pairs(items) do items[key] = nil end
  end

  local function requireDenseArray(items, label)
    if type(items) ~= "table" then
      error((label or "数组") .. "无效", 0)
    end
    local length = #items
    local keys = 0
    for key in pairs(items) do
      if type(key) ~= "number" or key ~= math.floor(key) or
         key < 1 or key > length then
        error((label or "数组") .. "不是连续数组", 0)
      end
      keys = keys + 1
    end
    if keys ~= length then error((label or "数组") .. "不是连续数组", 0) end
    return length
  end

  local function copyEntries(entries)
    local result = {}
    for index = 1, #entries do
      local source = entries[index]
      result[index] = {
        name=source.name,
        id=source.id,
        address=source.address,
        groupName=source.groupName,
      }
    end
    return result
  end

  local function normalizePointer(value, label)
    local number = tonumber(value)
    if not number or number ~= math.floor(number) then
      error((label or "指针") .. "不是有效整数", 0)
    end
    local address = number & POINTER_MASK
    if address == 0 then error((label or "指针") .. "为空", 0) end
    return address
  end

  local function requireRange(address, size, label)
    address = normalizePointer(address, label)
    size = requireInteger(size, 1, 0x7FFFFFFF, (label or "对象") .. "长度")
    local lastAddress = address + size - 1
    if lastAddress < address then error((label or "对象") .. "范围溢出", 0) end
    if not Memory.isMapped(address, size) then
      error(string.format("%s范围无效: 0x%X + 0x%X",
        label or "对象", address, size), 0)
    end
    return address
  end

  local function requireObject(value, size, label)
    return requireRange(normalizePointer(value, label), size or 1, label)
  end

  local function operation(label, callback)
    local ok, result = pcall(callback)
    if ok then return result end
    local message = label .. "失败：" .. tostring(result)
    trace(message)
    return nil, message
  end

  local function getGlobalRoot()
    if type(runtime.gameBase) ~= "number" then
      error("游戏基址尚未初始化", 0)
    end
    if type(TAG["全局物品"]) ~= "table" then
      error("渠道服全局物品路径缺失", 0)
    end
    return requireObject(
      Memory.resolve(runtime.gameBase, TAG["全局物品"], 1),
      1,
      "全局物品根节点"
    )
  end

  local function walkGlobalItems(root)
    return operation("全局物品遍历", function()
      local current = root == nil and getGlobalRoot() or
                      requireObject(root, 1, "全局物品根节点")
      local seen = {}
      local nodes = {}

      while true do
        if seen[current] then error("全局物品链表出现循环", 0) end
        if #nodes >= LIMIT.nodes then error("全局物品节点数量异常", 0) end
        seen[current] = true

        requireRange(current + 0x108, 8, "全局物品节点对象槽")
        requireRange(current + OFFSET.nextNode, 8, "全局物品下一节点槽")
        local countAddress = Memory.resolve(
          current, OFFSET.nodeItemPath, 4
        )
        countAddress = requireObject(countAddress, 4, "全局物品组头")
        nodes[#nodes + 1] = {
          address=countAddress,
          flags=TYPE_DWORD,
          nodeAddress=current,
        }

        local nextRaw = Memory.read(current + OFFSET.nextNode, TYPE_QWORD)
        if (nextRaw & 0xFFFFFFFF) == 0 then return nodes end
        current = requireObject(normalizePointer(nextRaw, "全局物品下一节点"), 1,
                                "全局物品下一节点")
      end
    end)
  end

  local function cases(root, output)
    if type(output) ~= "table" then
      return false, "全局物品输出表无效"
    end
    clearArray(output)
    local nodes, reason = walkGlobalItems(root)
    if not nodes then return false, reason end
    for index = 1, #nodes do output[index] = nodes[index] end
    return true
  end

  local function readGroupRecords()
    local nodes, reason = walkGlobalItems()
    if not nodes then return nil, reason end
    return operation("全局物品组读取", function()
      local values = Memory.readMany(nodes)
      local groups = {}
      for index = 1, #nodes do
        local count = tonumber(values[index].value)
        if not count or count ~= math.floor(count) then
          error("全局物品组数量不是整数", 0)
        end
        groups[index] = {
          address=nodes[index].address,
          countAddress=nodes[index].address,
          count=count,
          nodeAddress=nodes[index].nodeAddress,
        }
      end
      return groups
    end)
  end

  local function groupNameField(group, nameOffset)
    if type(group) ~= "table" or type(group.countAddress) ~= "number" then
      error("物品组记录无效", 0)
    end
    nameOffset = requireInteger(
      nameOffset or OFFSET.defaultGroupName,
      0,
      0x1000,
      "物品组名称偏移"
    )
    local path = {
      OFFSET.groupNamePathPrefix[1],
      OFFSET.groupNamePathPrefix[2],
      OFFSET.groupNamePathPrefix[3],
      nameOffset,
    }
    return Memory.resolve(
      group.countAddress + OFFSET.groupArray,
      path,
      8
    )
  end

  local function readGroupNameUnsafe(group, nameOffset)
    local field = requireRange(
      groupNameField(group, nameOffset), 8, "物品组名称字段"
    )
    local name = Memory.readString(field, 128)
    if name == "" then error("物品组名称为空或尚未加载", 0) end
    return name
  end

  local function readGroupName(group, nameOffset)
    return operation("物品组名称读取", function()
      return readGroupNameUnsafe(group, nameOffset)
    end)
  end

  local function readGroupNames(groups, nameOffset)
    return operation("物品组名称批量读取", function()
      requireDenseArray(groups, "物品组数组")
      local names = {}
      for index = 1, #groups do
        if type(groups[index]) ~= "table" then error("物品组记录无效", 0) end
        names[index] = readGroupNameUnsafe(groups[index], nameOffset)
      end
      return names
    end)
  end

  local function readCandidateGroupNames(groups, nameOffset)
    return operation("候选物品组名称读取", function()
      requireDenseArray(groups, "候选物品组数组")
      nameOffset = requireInteger(
        nameOffset or OFFSET.defaultGroupName,
        0,
        0x1000,
        "物品组名称偏移"
      )

      local groupSlots = {}
      for index = 1, #groups do
        if type(groups[index]) ~= "table" or
           type(groups[index].countAddress) ~= "number" then
          error("物品组记录无效", 0)
        end
        groupSlots[index] = {
          address=requireRange(
            groups[index].countAddress + OFFSET.groupArray,
            8,
            "候选物品组数组指针"
          ),
          flags=TYPE_QWORD,
        }
      end

      local function nextLevel(values, offset, pointerLabel, rangeLabel)
        local requests = {}
        for index, value in ipairs(values) do
          requests[index] = {
            address=requireRange(
              normalizePointer(value.value, pointerLabel) + offset,
              8,
              rangeLabel or pointerLabel
            ),
            flags=TYPE_QWORD,
          }
        end
        return Memory.readMany(requests)
      end

      local firstValues = nextLevel(
        Memory.readMany(groupSlots), 0, "物品组一级指针"
      )
      local secondValues = nextLevel(firstValues, 0x18, "物品组二级指针")
      local stringPointers = nextLevel(
        secondValues, nameOffset, "物品组名称对象", "物品组名称字段"
      )
      local rawPointers = {}
      for index = 1, #groups do
        local raw = tonumber(stringPointers[index].value)
        if not raw or raw ~= math.floor(raw) then
          error("物品组名称指针不是有效整数", 0)
        end
        rawPointers[index] = raw
      end

      local decodedNames = Memory.readStringsAt(rawPointers, 32)
      local names, skipped = {}, 0
      for index = 1, #groups do
        local name = decodedNames[index] or ""
        if name == "" then
          names[index] = false
          skipped = skipped + 1
        else
          names[index] = name
        end
      end
      if skipped > 0 then
        trace("items skipped unloaded candidate group names=" .. skipped)
      end
      return names
    end)
  end

  local function findGroup(criteria)
    criteria = criteria or {}
    return operation("全局物品组定位", function()
      if type(criteria) ~= "table" then error("物品组检索条件无效", 0) end
      local expectedCount = criteria.count
      local expectedName = criteria.name
      local nameOffset = criteria.nameOffset or OFFSET.defaultGroupName

      if expectedCount == nil and expectedName == nil then
        error("未提供全局物品检索条件", 0)
      end
      if expectedCount ~= nil then
        expectedCount = requireInteger(
          expectedCount, 1, LIMIT.groupItems, "全局物品组数量"
        )
      end
      if expectedName ~= nil and
         (type(expectedName) ~= "string" or expectedName == "") then
        error("物品组名称不能为空", 0)
      end
      nameOffset = requireInteger(nameOffset, 0, 0x1000, "物品组名称偏移")

      local groups, reason = readGroupRecords()
      if not groups then error(reason, 0) end
      local candidates = {}
      for index = 1, #groups do
        local group = groups[index]
        local matchesCount
        if expectedCount ~= nil then
          matchesCount = group.count == expectedCount
        else
          matchesCount = group.count > 44 and group.count < 7000
        end
        if matchesCount then candidates[#candidates + 1] = group end
      end

      if expectedName ~= nil and #candidates > 0 then
        local names, nameReason = readCandidateGroupNames(candidates, nameOffset)
        if not names then error(nameReason, 0) end
        local named = {}
        for index = 1, #candidates do
          if names[index] == expectedName then
            candidates[index].name = names[index]
            named[#named + 1] = candidates[index]
          end
        end
        candidates = named
      end

      if #candidates == 0 then error("未找到符合条件的物品组", 0) end
      if #candidates > 1 then
        error(string.format(
          "找到 %d 个符合条件的物品组，无法唯一定位", #candidates
        ), 0)
      end
      return candidates[1]
    end)
  end

  local function readItemsFromGroup(group)
    return operation("物品组对象读取", function()
      if type(group) ~= "table" or type(group.countAddress) ~= "number" then
        error("物品组记录无效", 0)
      end
      local count = requireInteger(
        group.count, 1, LIMIT.groupItems, "全局物品组数量"
      )
      local arrayAddress = requireObject(
        Memory.pointer(group.countAddress + OFFSET.groupArray),
        count * 8,
        "物品组数组"
      )

      local slots = {}
      for index = 1, count do
        slots[index] = {
          address=arrayAddress + (index - 1) * 8,
          flags=TYPE_QWORD,
        }
      end
      local slotValues = Memory.readMany(slots)

      local objectFields = {}
      for index = 1, count do
        local slotObject = requireObject(
          slotValues[index].value, OFFSET.slotObject + 8, "物品槽对象"
        )
        objectFields[index] = {
          address=slotObject + OFFSET.slotObject,
          flags=TYPE_QWORD,
        }
      end
      local objectValues = Memory.readMany(objectFields)

      local items = {}
      for index = 1, count do
        local itemAddress = requireObject(
          objectValues[index].value, 4, "物品对象"
        )
        items[index] = {
          address=itemAddress,
          flags=TYPE_DWORD,
          index=index,
          group=group,
          groupArrayAddress=arrayAddress,
          slotAddress=arrayAddress + (index - 1) * 8,
          slotObjectAddress=objectFields[index].address - OFFSET.slotObject,
          objectFieldAddress=objectFields[index].address,
        }
      end
      return items
    end)
  end

  local function readItemsFromGroups(groups)
    return operation("多物品组对象批量读取", function()
      requireDenseArray(groups, "物品组数组")
      if #groups == 0 then return {} end

      local arrayRequests, counts = {}, {}
      for groupIndex, group in ipairs(groups) do
        if type(group) ~= "table" or type(group.countAddress) ~= "number" then
          error("第 " .. groupIndex .. " 个物品组记录无效", 0)
        end
        counts[groupIndex] = requireInteger(
          group.count, 1, LIMIT.groupItems,
          "第 " .. groupIndex .. " 个全局物品组数量"
        )
        arrayRequests[groupIndex] = {
          address=group.countAddress + OFFSET.groupArray,
          flags=TYPE_QWORD,
        }
      end
      local arrayValues = Memory.readMany(arrayRequests)

      local slots, owners = {}, {}
      for groupIndex, group in ipairs(groups) do
        local count = counts[groupIndex]
        local arrayAddress = requireObject(
          arrayValues[groupIndex].value,
          count * 8,
          "第 " .. groupIndex .. " 个物品组数组"
        )
        for itemIndex = 1, count do
          slots[#slots + 1] = {
            address=arrayAddress + (itemIndex - 1) * 8,
            flags=TYPE_QWORD,
          }
          owners[#owners + 1] = {
            group=group,
            groupArrayAddress=arrayAddress,
            index=itemIndex,
          }
        end
      end
      local slotValues = Memory.readMany(slots)

      local objectFields = {}
      for index, value in ipairs(slotValues) do
        local slotObject = requireObject(
          value.value, OFFSET.slotObject + 8, "物品槽对象"
        )
        objectFields[index] = {
          address=slotObject + OFFSET.slotObject,
          flags=TYPE_QWORD,
        }
        owners[index].slotAddress = slots[index].address
        owners[index].slotObjectAddress = slotObject
      end
      local objectValues = Memory.readMany(objectFields)

      local items = {}
      for index, value in ipairs(objectValues) do
        local owner = owners[index]
        items[index] = {
          address=requireObject(value.value, 4, "物品对象"),
          flags=TYPE_DWORD,
          index=owner.index,
          group=owner.group,
          groupArrayAddress=owner.groupArrayAddress,
          slotAddress=owner.slotAddress,
          slotObjectAddress=owner.slotObjectAddress,
          objectFieldAddress=objectFields[index].address,
        }
      end
      return items
    end)
  end

  local function readItemsFromKnownGroup(group)
    return operation("已定位物品组复读", function()
      if type(group) ~= "table" or
         type(group.countAddress) ~= "number" then
        error("物品组记录无效", 0)
      end
      local expectedCount = requireInteger(
        group.count, 1, LIMIT.groupItems, "全局物品组数量"
      )
      local currentCount = requireInteger(
        Memory.read(group.countAddress, TYPE_DWORD),
        1,
        LIMIT.groupItems,
        "当前全局物品组数量"
      )
      if currentCount ~= expectedCount then
        error("已定位物品组数量已经变化", 0)
      end
      local currentGroup = {
        address=group.address,
        countAddress=group.countAddress,
        count=currentCount,
        nodeAddress=group.nodeAddress,
        name=group.name,
      }
      local items, reason = readItemsFromGroup(currentGroup)
      if not items then error(reason, 0) end
      return items
    end)
  end

  local function findItems(criteria)
    local group, reason = findGroup(criteria)
    if not group then return nil, reason end
    return readItemsFromGroup(group)
  end

  local function findItemsByGroupName(name, options)
    options = options or {}
    return findItems({
      count=options.count,
      name=name,
      nameOffset=options.nameOffset,
    })
  end

  local function findItemsByCount(count, options)
    options = options or {}
    return findItems({
      count=count,
      name=options.name,
      nameOffset=options.nameOffset,
    })
  end

  local function qjpz(count, name, nameOffset)
    return findItems({count=count, name=name, nameOffset=nameOffset})
  end

  local function catalogSnapshot()
    return {
      loaded=state.catalogLoaded,
      generation=state.catalogGeneration,
      names=copyArray(state.catalogNames),
      ids=copyArray(state.catalogIds),
      entries=copyEntries(state.catalogEntries),
      recordedIds=copyArray(state.recordedIds),
    }
  end

  local function buildCatalog()
    return operation("物品检索目录构建", function()
      local groups, reason = readGroupRecords()
      if not groups then error(reason, 0) end

      local candidates = {}
      for index = 1, #groups do
        local count = groups[index].count
        if count >= 10 and count <= LIMIT.groupItems then
          candidates[#candidates + 1] = groups[index]
        end
      end

      local candidateNames, nameReason = readCandidateGroupNames(
        candidates, OFFSET.defaultGroupName
      )
      if not candidateNames then error(nameReason, 0) end

      local selectedGroups = {}
      for wantedIndex = 1, #CATALOG_GROUP_NAMES do
        local wantedName = CATALOG_GROUP_NAMES[wantedIndex]
        for groupIndex = 1, #candidates do
          if candidateNames[groupIndex] == wantedName then
            candidates[groupIndex].name = wantedName
            selectedGroups[#selectedGroups + 1] = candidates[groupIndex]
          end
        end
      end

      local allItems, itemReason = readItemsFromGroups(selectedGroups)
      if not allItems then error(itemReason, 0) end
      local allGroupNames = {}
      for index, item in ipairs(allItems) do
        allGroupNames[index] = item.group.name
      end

      local enabledRequests = {}
      for index = 1, #allItems do
        requireRange(
          allItems[index].address,
          OFFSET.catalogEnabled + 4,
          "目录物品对象"
        )
        enabledRequests[index] = {
          address=allItems[index].address + OFFSET.catalogEnabled,
          flags=TYPE_DWORD,
        }
      end
      local enabledValues = Memory.readMany(enabledRequests)

      local eligibleItems = {}
      local eligibleGroups = {}
      for index = 1, #allItems do
        if enabledValues[index].value ~= 0 then
          eligibleItems[#eligibleItems + 1] = allItems[index]
          eligibleGroups[#eligibleGroups + 1] = allGroupNames[index]
        end
      end

      local idRequests = {}
      local nameRequests = {}
      for index = 1, #eligibleItems do
        local address = eligibleItems[index].address
        requireRange(address + OFFSET.catalogId, 12, "目录物品 ID")
        requireRange(address + OFFSET.catalogName, 8, "目录物品名称")
        idRequests[index] = {address=address + OFFSET.catalogId}
        nameRequests[index] = {
          address=address + OFFSET.catalogName,
          flags=TYPE_QWORD,
        }
      end
      local names = Memory.readStrings(nameRequests, 32)
      for index = 1, #eligibleItems do
        if names[index] == "" then
          error("目录物品名称为空或尚未加载", 0)
        end
      end
      local ids = Codec.decodeMany(idRequests)

      local entries = {}
      for index = 1, #eligibleItems do
        entries[index] = {
          name=names[index],
          id=ids[index],
          address=eligibleItems[index].address,
          groupName=eligibleGroups[index],
        }
      end
      return {names=names, ids=ids, entries=entries}
    end)
  end

  local catalog = {}

  function catalog.refresh()
    local fresh, reason = buildCatalog()
    if not fresh then return nil, reason end

    state.catalogNames = fresh.names
    state.catalogIds = fresh.ids
    state.catalogEntries = fresh.entries
    state.catalogLoaded = true
    state.catalogGeneration = state.catalogGeneration + 1
    trace(string.format(
      "items catalog committed: generation=%d entries=%d",
      state.catalogGeneration, #state.catalogEntries
    ))
    return catalogSnapshot()
  end

  function catalog.ensure()
    if state.catalogLoaded then return catalogSnapshot() end
    return catalog.refresh()
  end

  function catalog.get()
    return catalogSnapshot()
  end

  function catalog.invalidate()
    state.catalogLoaded = false
    state.catalogNames = {}
    state.catalogIds = {}
    state.catalogEntries = {}
  end

  function catalog.record(ids)
    local validated = {}
    local ok, problem = pcall(function()
      requireDenseArray(ids, "录入 ID 数组")
      for index = 1, #ids do
        validated[index] = requireInteger(
          ids[index], 1, 0x7FFFFFFF, "物品 ID"
        )
      end
      if #state.recordedIds + #validated > LIMIT.recordedIds then
        error("已录入物品数量超过安全上限", 0)
      end
    end)
    if not ok then return nil, "物品 ID 录入失败：" .. tostring(problem) end
    for index = 1, #validated do
      state.recordedIds[#state.recordedIds + 1] = validated[index]
    end
    return #validated
  end

  function catalog.recordOne(id)
    return catalog.record({id})
  end

  function catalog.getRecordedIds()
    return copyArray(state.recordedIds)
  end

  function catalog.clearRecordedIds()
    clearArray(state.recordedIds)
    return true
  end

  local function recordPreset(name)
    local ids = PRESET_IDS[name]
    if not ids then error("未知物品预设：" .. tostring(name), 0) end
    local count, reason = catalog.record(ids)
    if not count then error(reason, 0) end
    trace(string.format(
      "items preset recorded: name=%s appended=%d total=%d",
      tostring(name), count, #state.recordedIds
    ))
    gg.toast("记录完成")
    return count
  end

  local actions = {}

  function actions.jiansuo()
    local snapshot, reason = catalog.ensure()
    if not snapshot then error(reason, 0) end
    if #snapshot.names == 0 then error("物品检索目录为空", 0) end

    local selected
    if type(gg.changeChoice) == "function" then
      selected = gg.changeChoice(snapshot.names, "选择")
    else
      selected = gg.multiChoice(snapshot.names, nil, "选择")
    end
    if not selected then return false end

    local ids = {}
    for index = 1, #snapshot.ids do
      if selected[index] then ids[#ids + 1] = snapshot.ids[index] end
    end
    if #ids == 0 then return false end
    local count, recordReason = catalog.record(ids)
    if not count then error(recordReason, 0) end
    gg.toast("记录完成")
    return true
  end

  function actions.zdlr()
    local answer = gg.prompt({"录入id"}, {""}, {"number"})
    if not answer then return false end
    local id = requireInteger(answer[1], 1, 0x7FFFFFFF, "物品 ID")
    local count, reason = catalog.recordOne(id)
    if not count then error(reason, 0) end
    gg.toast("录入成功")
    return true
  end

  function actions.fbcl()
    return recordPreset("fbcl")
  end

  function actions.szcl()
    return recordPreset("szcl")
  end

  function actions.bmcl()
    return recordPreset("bmcl")
  end

  function actions.cailiaoluru()
    return recordPreset("cailiaoluru")
  end

  local getSoulAddress

  local function findReplacementItem()
    local items, reason = findItemsByGroupName("枯叶灵", {count=173})
    if not items then error(reason, 0) end
    local requests = {}
    for index = 1, #items do
      requireRange(
        items[index].address + OFFSET.replacementId,
        12,
        "替换目标物品 ID"
      )
      requests[index] = {address=items[index].address + OFFSET.replacementId}
    end
    local ids = Codec.decodeMany(requests)
    local matches = {}
    for index = 1, #ids do
      if ids[index] == 502123 then
        local item = items[index]
        local group = item.group
        local arrayAddress = requireObject(
          Memory.pointer(group.countAddress + OFFSET.groupArray),
          #items * 8,
          "替换媒介物品组数组"
        )
        local slotAddress = arrayAddress + (index - 1) * 8
        local slotObject = requireObject(
          Memory.pointer(slotAddress), OFFSET.slotObject + 8,
          "替换媒介槽对象"
        )
        local objectFieldAddress = slotObject + OFFSET.slotObject
        local verifiedAddress = requireObject(
          Memory.pointer(objectFieldAddress), 4, "替换媒介对象"
        )
        if verifiedAddress ~= item.address then
          error("替换媒介目录快照不一致", 0)
        end
        matches[#matches + 1] = {
          address=item.address,
          index=index,
          itemCount=#items,
          groupCountAddress=group.countAddress,
          groupNodeAddress=group.nodeAddress,
          arrayAddress=arrayAddress,
          slotAddress=slotAddress,
          slotObject=slotObject,
          objectFieldAddress=objectFieldAddress,
        }
      end
    end
    if #matches == 0 then error("未找到替换媒介物品 502123", 0) end
    if #matches > 1 then error("替换媒介物品 502123 不唯一", 0) end
    return matches[1]
  end

  local function resolveReplacementSlot(identity, validateSoul)
    if type(identity) ~= "table" then error("替换媒介身份无效", 0) end
    local currentCount = requireInteger(
      Memory.read(identity.groupCountAddress, TYPE_DWORD),
      1, LIMIT.groupItems, "替换媒介所在物品组数量"
    )
    if currentCount ~= identity.itemCount then
      error("替换媒介所在物品组数量已经变化", 0)
    end
    local currentCountAddress = Memory.resolve(
      identity.groupNodeAddress, OFFSET.nodeItemPath, 4
    )
    if currentCountAddress ~= identity.groupCountAddress then
      error("替换媒介所在物品组身份已经变化", 0)
    end
    local arrayAddress = requireObject(
      Memory.pointer(identity.groupCountAddress + OFFSET.groupArray),
      identity.itemCount * 8,
      "替换媒介物品组数组"
    )
    local slotAddress = arrayAddress + (identity.index - 1) * 8
    local slotObject = requireObject(
      Memory.pointer(slotAddress), OFFSET.slotObject + 8,
      "替换媒介槽对象"
    )
    local objectFieldAddress = slotObject + OFFSET.slotObject
    local currentAddress = requireObject(
      Memory.pointer(objectFieldAddress), 4, "替换媒介对象"
    )
    if arrayAddress ~= identity.arrayAddress or
       slotAddress ~= identity.slotAddress or
       slotObject ~= identity.slotObject or
       objectFieldAddress ~= identity.objectFieldAddress or
       currentAddress ~= identity.address then
      error("替换媒介槽或对象身份已经变化", 0)
    end
    local idAddress = requireRange(
      identity.address + OFFSET.replacementId, 12, "替换媒介 ID"
    )
    identity.idAddress = idAddress
    local soulAddress, a0Address = getSoulAddress()
    if validateSoul ~= false and identity.soulAddress and
       identity.soulAddress ~= soulAddress then
      error("人物灵魂监听字段已经变化，已停止本轮替换", 0)
    end
    if validateSoul ~= false and identity.a0Address and
       identity.a0Address ~= a0Address then
      error("人物 A0 对象已经变化，已停止本轮替换", 0)
    end
    if not identity.soulAddress then identity.soulAddress = soulAddress end
    if not identity.a0Address then identity.a0Address = a0Address end
    return identity
  end

  local function verifyDecodedKeySpecs(specs, label)
    local requests = {}
    for index, spec in ipairs(specs) do
      requests[index] = {address=spec.address}
    end
    local values = Codec.decodeMany(requests)
    for index, spec in ipairs(specs) do
      if values[index] ~= spec.value then
        error((label or spec.label or "加密字段") .. "写后解码值不一致", 0)
      end
    end
    return true
  end

  local function resolveReplacementIdentity(identity, expectedId)
    resolveReplacementSlot(identity)
    local actualId = Codec.decode(identity.idAddress)
    if actualId ~= expectedId then
      error(string.format(
        "替换媒介身份已变化（期望 ID %d，当前 ID %s）",
        expectedId, tostring(actualId)
      ), 0)
    end
    return identity
  end

  local function prepareReplacementItem(identity)
    resolveReplacementIdentity(identity, 502123)
    local address = identity.address
    local specs, links = {}, {}
    for index = 0, 2 do
      local linkAddress = address + OFFSET.replacementLinks + index * 8
      local linkedObject = requireObject(
        Memory.pointer(linkAddress),
        OFFSET.replacementLinkValue + 12,
        "替换媒介关联对象"
      )
      links[#links + 1] = {
        slot=linkAddress,
        object=linkedObject,
      }
      specs[#specs + 1] = {
        kind="key",
        address=linkedObject + OFFSET.replacementLinkValue,
        value=502000,
        label="替换媒介关联对象",
      }
    end
    specs[#specs + 1] = {
      kind="key",
      address=requireRange(address + OFFSET.replacementCost, 12, "替换媒介消耗"),
      value=1,
      label="替换媒介消耗",
    }
    local currentValues = Codec.decodeMany(specs)
    local prepared = true
    for index, spec in ipairs(specs) do
      if currentValues[index] ~= spec.value then prepared = false end
    end
    if prepared then return end
    Transaction.write(specs, {
      label="替换媒介准备",
      validateIdentity=function()
        resolveReplacementIdentity(identity, 502123)
        for _, link in ipairs(links) do
          if Memory.pointer(link.slot) ~= link.object then
            error("替换媒介关联对象已经变化", 0)
          end
        end
        return true
      end,
      validateApplied=function(_, _, _, appliedSpecs)
        return verifyDecodedKeySpecs(appliedSpecs, "替换媒介准备")
      end,
    })
    verifyDecodedKeySpecs(specs, "替换媒介准备")
  end

  local function writeReplacementId(identity, targetId, label, validateSoul)
    targetId = requireInteger(targetId, 0, 0x7FFFFFFF, "替换物品 ID")
    local specs = {{
      kind="key",
      address=identity.idAddress,
      value=targetId,
      label=label,
    }}
    Transaction.write(specs, {
      label=label,
      singleSnapshot=true,
      validateIdentity=function()
        resolveReplacementSlot(identity, validateSoul)
        return true
      end,
      validateApplied=function(_, _, _, appliedSpecs)
        return verifyDecodedKeySpecs(appliedSpecs, label)
      end,
    })
    verifyDecodedKeySpecs(specs, label)
    return true
  end

  local function writeReplacementStep(identity, targetId, label, validateSoul)
    writeReplacementId(identity, targetId, label, validateSoul)
    return Memory.read(identity.soulAddress, TYPE_DWORD)
  end

  getSoulAddress = function()
    if type(TAG["A0基址"]) ~= "number" then
      error("渠道服 A0 基址偏移缺失", 0)
    end
    if type(FIELD["灵魂"]) ~= "number" then
      error("渠道服灵魂字段偏移缺失", 0)
    end
    local a0 = Memory.resolve(runtime.gameBase, TAG["A0基址"], 1)
    local address = requireRange(a0 + FIELD["灵魂"], 4, "灵魂监听字段")
    return address, a0
  end

  function actions.kaishitihuan()
    local recorded = catalog.getRecordedIds()
    if #recorded == 0 then error("您还未记录物品", 0) end
    for index = 1, #recorded do
      recorded[index] = requireInteger(
        recorded[index], 1, 0x7FFFFFFF, "物品 ID"
      )
    end
    local sequence = copyArray(recorded)
    sequence[#sequence + 1] = 0
    trace(string.format(
      "item replacement requested: recorded=%d sequence=%d",
      #recorded, #sequence
    ))

    local identity = findReplacementItem()
    local itemAddress = identity.address
    local idAddress = itemAddress + OFFSET.replacementId
    local originalId = Codec.decode(idAddress)
    if originalId ~= 502123 then
      error("替换媒介物品已经变化，请重新进入界面后再试", 0)
    end
    prepareReplacementItem(identity)

    identity.expectedId = originalId
    identity.currentIndex = 1
    identity.started = false
    gg.toast("点击修改器终止修改")

    local result = Listener.run({
      name="item_replacement",
      intervalMs=50,
      initialState=identity,
      hideOnCancel=true,
      acquire=function()
        resolveReplacementIdentity(identity, originalId)
        identity.expectedId = sequence[1]
        identity.started = true
        identity.lastSoulRaw = writeReplacementStep(
          identity, sequence[1], "替换媒介首次写入", true
        )
        trace(string.format(
          "item replacement armed: index=1/%d id=%d",
          #recorded, sequence[1]
        ))
        return identity
      end,
      tick=function(listenerState)
        resolveReplacementIdentity(listenerState, listenerState.expectedId)
        local soulRaw = Memory.read(listenerState.soulAddress, TYPE_DWORD)
        if soulRaw == listenerState.lastSoulRaw then return nil end

        local nextIndex = listenerState.currentIndex + 1
        if nextIndex > #sequence then return true end
        listenerState.lastSoulRaw = writeReplacementStep(
          listenerState, sequence[nextIndex], "替换媒介推进", true
        )
        listenerState.currentIndex = nextIndex
        listenerState.expectedId = sequence[nextIndex]
        trace(string.format(
          "item replacement advanced: index=%d/%d id=%d",
          math.min(nextIndex, #recorded), #recorded, sequence[nextIndex]
        ))
        if nextIndex == #sequence then return true end
        return nil
      end,
      recover=function(_, listenerState)
        resolveReplacementIdentity(listenerState, listenerState.expectedId)
        listenerState.lastSoulRaw = Memory.read(
          listenerState.soulAddress, TYPE_DWORD
        )
        return listenerState
      end,
      cleanup=function(listenerState)
        if not listenerState or not listenerState.started then return end
        local lastKnownAddress = listenerState.address
        local identityOk = pcall(
          resolveReplacementIdentity, listenerState, listenerState.expectedId
        )
        if not identityOk then
          resolveReplacementSlot(listenerState, false)
          if listenerState.address ~= lastKnownAddress then
            error("替换媒介身份已变化，拒绝向新对象恢复旧 ID", 0)
          end
        end
        writeReplacementId(
          listenerState, originalId, "替换媒介恢复", false
        )
        listenerState.started = false
      end,
    })

    if result.cleanupError then
      error("替换结束，但媒介物品恢复失败：" .. result.cleanupError, 0)
    end
    if result.reason == "cancelled" then
      catalog.clearRecordedIds()
      gg.toast("已终止修改并恢复媒介物品")
      return false
    end
    if result.ok and result.reason == "completed" then
      catalog.clearRecordedIds()
      gg.toast("修改完毕")
      return true
    end
    error("物品替换中断：" .. tostring(result.error or result.reason), 0)
  end

  local api = {
    walkGlobalItems=walkGlobalItems,
    cases=cases,
    readGroupName=readGroupName,
    readGroupNames=readGroupNames,
    findGroup=findGroup,
    findItems=findItems,
    findItemsByGroupName=findItemsByGroupName,
    findItemsByCount=findItemsByCount,
    readItemsFromKnownGroup=readItemsFromKnownGroup,
    readItemsFromGroups=readItemsFromGroups,
    resolveReplacementSlot=resolveReplacementSlot,
    prepareReplacementItem=prepareReplacementItem,
    writeReplacementId=writeReplacementId,
    writeReplacementStep=writeReplacementStep,
    qjpz=qjpz,
    catalog=catalog,
    offset=OFFSET,
    actions=actions,
  }

  return api
end)

installModule("pet", function(app)
  local Memory = app.Memory
  local Codec = app.Codec
  local Transaction = app.Transaction
  local TAG = app.TAG
  local FIELD = app.FIELD
  local runtime = app.runtime
  local requireInteger = app.requireInteger
  local pointer = app.untagPointer
  local sameU32 = app.sameU32
  local floatBits = app.floatToDword
  local trace = app.trace
  local requirePath = app.requirePath
  local requireField = app.requireField

  local LOGICAL_CAPACITY_OFFSET = 0x50
  local PET_ARRAY_OWNER_OFFSET = 0x298
  local PHYSICAL_MAXIMUM = app.PET_PHYSICAL_MAXIMUM

  local function readLogicalCapacity()
    local base = runtime.gameBase
    local rootOffset = TAG["80基址"]
    if type(base) ~= "number" or base == 0 then
      error("游戏基址尚未初始化", 0)
    end
    if type(rootOffset) ~= "number" then
      error("宠物管理器根偏移缺失", 0)
    end
    local rootSlot = base + rootOffset
    local managerAddress = Memory.pointer(rootSlot)
    if managerAddress == 0 or
       not Memory.isMapped(managerAddress + LOGICAL_CAPACITY_OFFSET, 12) then
      error("宠物管理器尚未加载", 0)
    end
    local logicalCapacity = tonumber(Codec.decode(
      managerAddress + LOGICAL_CAPACITY_OFFSET
    ))
    if not logicalCapacity or logicalCapacity ~= math.floor(logicalCapacity) or
       logicalCapacity < 1 or logicalCapacity > PHYSICAL_MAXIMUM then
      error("宠物背包解锁格数异常：" .. tostring(logicalCapacity), 0)
    end
    if Memory.pointer(rootSlot) ~= managerAddress then
      error("宠物管理器在读取格数期间发生变化", 0)
    end
    return logicalCapacity, managerAddress
  end

  local function readCountAndCapacity(countAddress)
    local values = Memory.readMany({
      {address=countAddress, flags=gg.TYPE_DWORD},
      {address=countAddress + 4, flags=gg.TYPE_DWORD},
    })
    return tonumber(values[1].value), tonumber(values[2].value)
  end

  local function resolveStructureAddresses()
    local base = runtime.gameBase
    if type(base) ~= "number" or base == 0 then
      error("游戏基址尚未初始化", 0)
    end

    local upperAddress = Memory.resolve(
      base, requirePath("宠物数量上层"), 24
    )
    local countAddress = Memory.resolve(
      base, requirePath("宠物数量"), 24
    )

    if Memory.pointer(upperAddress) ~= countAddress then
      error("宠物数量结构在读取期间发生变化", 0)
    end

    local arrayAddress = Memory.pointer(countAddress + 16)
    return upperAddress, countAddress, arrayAddress
  end

  local function readSnapshotOnce(allowLogicalOverflow)
    local logicalCapacity, managerAddress = readLogicalCapacity()
    local upperAddress, countAddress, arrayAddress = resolveStructureAddresses()
    if upperAddress ~= managerAddress + PET_ARRAY_OWNER_OFFSET then
      error("宠物列表不属于当前宠物管理器", 0)
    end
    local count, capacity = readCountAndCapacity(countAddress)
    local countMaximum = allowLogicalOverflow and
      PHYSICAL_MAXIMUM or logicalCapacity
    if not count or count ~= math.floor(count) or
       count < 0 or count > countMaximum then
      error("当前宠物数量异常：" .. tostring(count), 0)
    end
    if not capacity or capacity ~= math.floor(capacity) or
       capacity < count or capacity > PHYSICAL_MAXIMUM then
      error(string.format(
        "当前宠物数组容量异常：数量 %s，容量 %s",
        tostring(count), tostring(capacity)
      ), 0)
    end

    local snapshot = {
      upperAddress=upperAddress,
      countAddress=countAddress,
      arrayAddress=arrayAddress,
      count=count,
      capacity=capacity,
      logicalCapacity=logicalCapacity,
      managerAddress=managerAddress,
      pets={},
    }
    if count == 0 then return snapshot end
    if arrayAddress == 0 or not Memory.isMapped(arrayAddress, count * 8) then
      error("宠物数组地址无效", 0)
    end

    local slotRequests = {}
    for index = 1, count do
      slotRequests[index] = {
        address=arrayAddress + (index - 1) * 8,
        flags=gg.TYPE_QWORD,
      }
    end
    local slots = Memory.readMany(slotRequests)

    local stateOffset = requireField("宠物状态")
    local stateRequests = {}
    for index, slot in ipairs(slots) do
      local petRaw = tonumber(slot.value)
      local petAddress = pointer(petRaw)
      if petAddress == 0 or
         not Memory.isMapped(petAddress + stateOffset, 4) then
        error("第 " .. index .. " 个宠物对象无效", 0)
      end
      snapshot.pets[index] = {
        slotIndex=index,
        slotAddress=slotRequests[index].address,
        petRaw=petRaw,
        petAddress=petAddress,
        stateAddress=petAddress + stateOffset,
      }
      stateRequests[index] = {
        address=petAddress + stateOffset,
        flags=gg.TYPE_DWORD,
      }
    end

    local states = Memory.readMany(stateRequests)
    for index, value in ipairs(states) do
      snapshot.pets[index].state=tonumber(value.value)
    end
    return snapshot
  end

  local function snapshotsEqual(left, right)
    if left.upperAddress ~= right.upperAddress or
       left.countAddress ~= right.countAddress or
       left.arrayAddress ~= right.arrayAddress or
       left.count ~= right.count or
       left.capacity ~= right.capacity or
       left.logicalCapacity ~= right.logicalCapacity or
       left.managerAddress ~= right.managerAddress or
       #left.pets ~= #right.pets then
      return false
    end
    for index, pet in ipairs(left.pets) do
      local other = right.pets[index]
      if not other or pet.slotAddress ~= other.slotAddress or
         tonumber(pet.petRaw) ~= tonumber(other.petRaw) or
         pet.petAddress ~= other.petAddress or
         pet.stateAddress ~= other.stateAddress or
         pet.state ~= other.state then
        return false
      end
    end
    return true
  end

  local function readStableSnapshot(allowLogicalOverflow)
    Memory.refreshRanges()
    local previous = readSnapshotOnce(allowLogicalOverflow)
    for _ = 1, 3 do
      local current = readSnapshotOnce(allowLogicalOverflow)
      if snapshotsEqual(previous, current) then
        return current
      end
      previous = current
    end
    error("宠物数据正在变化，请等待场景稳定后重试", 0)
  end

  local function readPetName(pet)
    local ownerField = pet.petAddress + requireField("宠物指针")
    if not Memory.isMapped(ownerField, 8) then return "" end
    local owner = Memory.pointer(ownerField)
    local nameField = owner + requireField("宠物名称")
    if owner == 0 or not Memory.isMapped(nameField, 8) then return "" end
    local ok, name = pcall(Memory.readString, nameField, 32)
    if not ok or name == "" then return "" end
    return name
  end

  local function listPetsByState(snapshot, state, includeNames)
    if type(snapshot) == "number" then
      includeNames = state
      state = snapshot
      snapshot = nil
    end
    snapshot = snapshot or readStableSnapshot()
    state = requireInteger(state, 1, 2, "宠物状态")

    local pets = {}
    for _, source in ipairs(snapshot.pets) do
      if source.state == state then
        local pet = {
          slotIndex=source.slotIndex,
          slotAddress=source.slotAddress,
          petRaw=source.petRaw,
          petAddress=source.petAddress,
          stateAddress=source.stateAddress,
          state=source.state,
        }
        if includeNames then
          pet.name = readPetName(pet)
          if pet.name == "" then
            pet.name = "宠物槽位 " .. pet.slotIndex
          end
        end
        pets[#pets + 1] = pet
      end
    end
    return pets, snapshot
  end

  local function validateSnapshot(
    first, selectedPets, requiredState, allowLogicalOverflow
  )
    local current = readStableSnapshot(allowLogicalOverflow)
    if not snapshotsEqual(first, current) then
      return nil, "宠物数据在操作期间发生变化，请重新选择"
    end

    if selectedPets then
      for _, selected in ipairs(selectedPets) do
        local currentPet = current.pets[selected.slotIndex]
        if not currentPet or
           currentPet.slotAddress ~= selected.slotAddress or
           tonumber(currentPet.petRaw) ~= tonumber(selected.petRaw) or
           currentPet.petAddress ~= selected.petAddress or
           currentPet.stateAddress ~= selected.stateAddress then
          return nil, "所选宠物槽位已经变化，请重新选择"
        end
        if requiredState and currentPet.state ~= requiredState then
          return nil, "所选宠物状态已经变化，请重新选择"
        end
      end
    end
    return current
  end

  local function requireValidatedSnapshot(snapshot, pets, state)
    local current, problem = validateSnapshot(snapshot, pets, state)
    if not current then error(problem, 0) end
    return current
  end

  local CCARRAY_DATA = 0x18
  local CCARRAY_REFERENCE = 0x10
  local DONOR_SEARCH_LIMIT = 50000

  local function readArrayHeaders(dataAddresses)
    local requests = {}
    for index, address in ipairs(dataAddresses) do
      local base = (index - 1) * 3
      requests[base + 1] = {address=address, flags=gg.TYPE_QWORD}
      requests[base + 2] = {address=address + 8, flags=gg.TYPE_QWORD}
      requests[base + 3] = {address=address + 16, flags=gg.TYPE_QWORD}
    end
    local values = #requests > 0 and Memory.readMany(requests) or {}
    local headers = {}
    for index, address in ipairs(dataAddresses) do
      local base = (index - 1) * 3
      local first = tonumber(values[base + 1].value) or 0
      local second = tonumber(values[base + 2].value) or 0
      local arrayRaw = tonumber(values[base + 3].value) or 0
      local header = {
        address=address,
        num=first & 0xFFFFFFFF, max=(first >> 32) & 0xFFFFFFFF,
        check1=second & 0xFFFFFFFF, check2=(second >> 32) & 0xFFFFFFFF,
        arrayRaw=arrayRaw, array=pointer(arrayRaw),
      }
      header.valid = ((header.check2 - header.check1) & 0xFFFFFFFF ~
        header.check1) == header.num
      headers[index] = header
    end
    return headers
  end

  local function sameHeader(left, right)
    return left.num == right.num and left.max == right.max and
      left.check1 == right.check1 and left.check2 == right.check2 and
      left.arrayRaw == right.arrayRaw
  end

  local function findCapacityDonor(snapshot, targetCount)
    local owner = snapshot.upperAddress - CCARRAY_DATA
    local vtable = tonumber(Memory.read(owner, gg.TYPE_QWORD))
    if not vtable or vtable == 0 then error("宠物数组对象虚表无效", 0) end
    local oldRanges = gg.getRanges()
    local results = {}
    local ok, problem = pcall(function()
      gg.clearResults()
      gg.setRanges(gg.REGION_C_ALLOC)
      gg.searchNumber(tostring(vtable), gg.TYPE_QWORD)
      local total = gg.getResultsCount()
      results = gg.getResults(math.min(total, DONOR_SEARCH_LIMIT))
    end)
    pcall(gg.clearResults)
    pcall(gg.setRanges, oldRanges)
    if not ok then error("搜索可交换的游戏数组失败：" .. tostring(problem), 0) end

    local objects, dataRequests = {}, {}
    for _, result in ipairs(results) do
      local object = result.address
      if object ~= owner and Memory.isMapped(object, CCARRAY_DATA + 8) then
        objects[#objects + 1] = object
        dataRequests[#dataRequests + 1] = {
          address=object + CCARRAY_DATA, flags=gg.TYPE_QWORD,
        }
        dataRequests[#dataRequests + 1] = {
          address=object + CCARRAY_REFERENCE, flags=gg.TYPE_DWORD,
        }
      end
    end
    local dataValues = #dataRequests > 0 and Memory.readMany(dataRequests) or {}
    local candidates, addresses = {}, {}
    for index, object in ipairs(objects) do
      local data = pointer(dataValues[index * 2 - 1].value)
      local reference = tonumber(dataValues[index * 2].value) or 0
      if data ~= 0 and data ~= snapshot.countAddress and reference >= 1 and
         Memory.isMapped(data, 24) then
        candidates[#candidates + 1] = {object=object, data=data}
        addresses[#addresses + 1] = data
      end
    end
    local headers = readArrayHeaders(addresses)
    local eligible, eligibleAddresses = {}, {}
    for index, header in ipairs(headers) do
      if header.num == 0 and header.valid and header.max >= targetCount and
         header.max <= PHYSICAL_MAXIMUM and header.array ~= 0 and
         header.array ~= snapshot.arrayAddress and
         Memory.isMapped(header.array, header.max * 8) then
        eligible[#eligible + 1] = {object=candidates[index].object, header=header}
        eligibleAddresses[#eligibleAddresses + 1] = header.address
      end
    end
    for _ = 1, 2 do
      if #eligible == 0 then break end
      gg.sleep(300)
      local again = readArrayHeaders(eligibleAddresses)
      local kept, keptAddresses = {}, {}
      for index, donor in ipairs(eligible) do
        if sameHeader(again[index], donor.header) then
          kept[#kept + 1] = donor
          keptAddresses[#keptAddresses + 1] = donor.header.address
        end
      end
      eligible, eligibleAddresses = kept, keptAddresses
    end
    table.sort(eligible, function(left, right)
      if left.header.max ~= right.header.max then
        return left.header.max < right.header.max
      end
      return left.object < right.object
    end)
    trace(string.format("pet capacity donors scanned=%d candidates=%d stable=%d",
      #results, #headers, #eligible))
    return eligible
  end

  local swapArrayBuffers

  local function borrowArrayCapacity(snapshot, targetCount)
    local donors = findCapacityDonor(snapshot, targetCount)
    if #donors == 0 then
      return nil, string.format(
        "没有找到可安全交换的空闲数组（需要至少 %d 格）", targetCount
      )
    end
    local lastProblem
    for attempt = 1, math.min(#donors, 8) do
      local ok, problem = pcall(swapArrayBuffers, snapshot, donors[attempt])
      if ok then return true end
      lastProblem = tostring(problem)
      trace("pet capacity swap retry " .. attempt .. ": " .. lastProblem)
      if not lastProblem:find("交换数组已经变化", 1, true) then break end
    end
    return nil, lastProblem or "宠物数组安全扩容失败"
  end

  swapArrayBuffers = function(snapshot, donor)
    local petHeader = readArrayHeaders({snapshot.countAddress})[1]
    if not petHeader.valid or petHeader.num ~= snapshot.count or
       petHeader.max ~= snapshot.capacity or
       petHeader.array ~= snapshot.arrayAddress then
      error("宠物数组在扩容前已经变化", 0)
    end
    local slotRequests = {}
    for index = 1, petHeader.num do
      slotRequests[index] = {
        address=petHeader.array + (index - 1) * 8, flags=gg.TYPE_QWORD,
      }
    end
    local slotValues = #slotRequests > 0 and Memory.readMany(slotRequests) or {}
    local donorHeader = donor.header
    local donorSlotRequests = {}
    for index = 1, petHeader.num do
      donorSlotRequests[index] = {
        address=donorHeader.array + (index - 1) * 8, flags=gg.TYPE_QWORD,
      }
    end
    local donorSlotOriginals = #donorSlotRequests > 0 and
      Memory.readMany(donorSlotRequests) or {}

    local writes = {}
    for index, value in ipairs(slotValues) do
      writes[#writes + 1] = {
        address=donorHeader.array + (index - 1) * 8,
        flags=gg.TYPE_QWORD, value=value.value,
      }
    end
    writes[#writes + 1] = {address=petHeader.address + 4, flags=gg.TYPE_DWORD,
      value=donorHeader.max}
    writes[#writes + 1] = {address=petHeader.address + 16, flags=gg.TYPE_QWORD,
      value=donorHeader.arrayRaw}
    writes[#writes + 1] = {address=donorHeader.address + 4, flags=gg.TYPE_DWORD,
      value=petHeader.max}
    writes[#writes + 1] = {address=donorHeader.address + 16, flags=gg.TYPE_QWORD,
      value=petHeader.arrayRaw}
    local rollback = {
      {address=petHeader.address + 4, flags=gg.TYPE_DWORD, value=petHeader.max},
      {address=petHeader.address + 16, flags=gg.TYPE_QWORD,
        value=petHeader.arrayRaw},
      {address=donorHeader.address + 4, flags=gg.TYPE_DWORD,
        value=donorHeader.max},
      {address=donorHeader.address + 16, flags=gg.TYPE_QWORD,
        value=donorHeader.arrayRaw},
    }
    for index, value in ipairs(donorSlotOriginals) do
      rollback[#rollback + 1] = {
        address=donorHeader.array + (index - 1) * 8,
        flags=gg.TYPE_QWORD, value=value.value,
      }
    end

    app.runWithTargetPaused("宠物数组安全扩容", function()
      local current = readArrayHeaders({petHeader.address, donorHeader.address})
      if not sameHeader(current[1], petHeader) then
        error("暂停后宠物数组已经变化，已放弃扩容", 0)
      end
      if not sameHeader(current[2], donorHeader) then
        error("暂停后交换数组已经变化", 0)
      end
      local liveSlots = #slotRequests > 0 and Memory.readMany(slotRequests) or {}
      for index, value in ipairs(liveSlots) do
        if tonumber(value.value) ~= tonumber(slotValues[index].value) then
          error("暂停后宠物槽位已经变化，已放弃扩容", 0)
        end
      end
      Memory.writeMany(writes)
      local after = readArrayHeaders({petHeader.address, donorHeader.address})
      local okPet = after[1].num == petHeader.num and
        after[1].max == donorHeader.max and
        after[1].arrayRaw == donorHeader.arrayRaw and after[1].valid
      local okDonor = after[2].num == 0 and after[2].max == petHeader.max and
        after[2].arrayRaw == petHeader.arrayRaw and after[2].valid
      local copied = #slotRequests > 0 and Memory.readMany(donorSlotRequests) or {}
      for index, value in ipairs(copied) do
        if tonumber(value.value) ~= tonumber(slotValues[index].value) then
          okPet = false
        end
      end
      if not (okPet and okDonor) then
        Memory.writeMany(rollback)
        error("宠物数组交换写后验证失败，已恢复原状", 0)
      end
    end)
    trace(string.format(
      "pet capacity borrowed donor=0x%X max %d -> %d",
      donor.object, petHeader.max, donorHeader.max
    ))
    return true
  end

  local function ensureAppendCapacity(
    snapshot, selectedPets, targetCount, requiredState
  )
    targetCount = requireInteger(
      targetCount, snapshot.count + 1, snapshot.logicalCapacity,
      "宠物目标数量"
    )
    local current, problem = validateSnapshot(
      snapshot, selectedPets, requiredState
    )
    if not current then return nil, problem end
    snapshot = current

    if snapshot.capacity < targetCount then
      local borrowed, borrowProblem = borrowArrayCapacity(snapshot, targetCount)
      if not borrowed then return nil, borrowProblem end
    end

    local fresh = readStableSnapshot()
    if fresh.upperAddress ~= snapshot.upperAddress or
       fresh.countAddress ~= snapshot.countAddress or
       fresh.count ~= snapshot.count or fresh.capacity < targetCount or
       fresh.capacity > PHYSICAL_MAXIMUM or
       fresh.logicalCapacity ~= snapshot.logicalCapacity or
       fresh.managerAddress ~= snapshot.managerAddress or
       #fresh.pets ~= #snapshot.pets then
      return nil, "宠物数组扩容后的列表身份不一致"
    end
    for index, old in ipairs(snapshot.pets) do
      local pet = fresh.pets[index]
      if not pet or tonumber(pet.petRaw) ~= tonumber(old.petRaw) or
         pet.petAddress ~= old.petAddress or
         pet.stateAddress ~= old.stateAddress or pet.state ~= old.state then
        return nil, "宠物数组扩容后原宠物身份发生变化"
      end
    end

    local remapped = {}
    for index, selected in ipairs(selectedPets or {}) do
      local pet = fresh.pets[selected.slotIndex]
      if not pet or tonumber(pet.petRaw) ~= tonumber(selected.petRaw) or
         pet.petAddress ~= selected.petAddress or
         (requiredState and pet.state ~= requiredState) then
        return nil, "宠物数组扩容后所选宠物身份发生变化"
      end
      remapped[index] = pet
    end
    return fresh, remapped
  end

  local function validateStructureIdentity(snapshot, selectedPets, requiredState)
    local logicalCapacity, managerAddress = readLogicalCapacity()
    if logicalCapacity ~= snapshot.logicalCapacity or
       managerAddress ~= snapshot.managerAddress then
      error("宠物背包格数或管理器已经变化", 0)
    end
    local upperAddress, countAddress, arrayAddress = resolveStructureAddresses()
    if upperAddress ~= snapshot.upperAddress or
       countAddress ~= snapshot.countAddress or
       arrayAddress ~= snapshot.arrayAddress then
      error("宠物数量结构或数组对象已经变化", 0)
    end
    local selectedList = selectedPets or {}
    local arrayValid = snapshot.count == 0 or (arrayAddress ~= 0 and
      Memory.isMapped(arrayAddress, snapshot.count * 8))
    local requests = {
      {address=countAddress, flags=gg.TYPE_DWORD},
      {address=countAddress + 4, flags=gg.TYPE_DWORD},
    }
    if arrayValid then
      for index = 1, snapshot.count do
        requests[#requests + 1] = {
          address=arrayAddress + (index - 1) * 8, flags=gg.TYPE_QWORD,
        }
      end
      for _, selected in ipairs(selectedList) do
        requests[#requests + 1] = {
          address=selected.slotAddress, flags=gg.TYPE_QWORD,
        }
        if requiredState then
          requests[#requests + 1] = {
            address=selected.stateAddress, flags=gg.TYPE_DWORD,
          }
        end
      end
    end
    local values = Memory.readMany(requests)
    if tonumber(values[1].value) ~= snapshot.count or
       tonumber(values[2].value) ~= snapshot.capacity then
      error("宠物数量或实际容量已经变化", 0)
    end
    if not arrayValid then error("宠物数组已经失效", 0) end
    for index, pet in ipairs(snapshot.pets) do
      local raw = values[2 + index].value
      if tonumber(raw) ~= tonumber(pet.petRaw) or
         pointer(raw) ~= pet.petAddress then
        error("原宠物槽位对象已经变化", 0)
      end
    end
    local cursor = 3 + snapshot.count
    for _, selected in ipairs(selectedList) do
      local raw = values[cursor].value
      cursor = cursor + 1
      if tonumber(raw) ~= tonumber(selected.petRaw) or
         pointer(raw) ~= selected.petAddress then
        error("所选宠物槽位对象已经变化", 0)
      end
      if requiredState then
        local state = values[cursor].value
        cursor = cursor + 1
        if state ~= requiredState then error("所选宠物状态已经变化", 0) end
      end
    end
    return true
  end

  local function verifyDwordWrites(writes, label)
    local requests = {}
    for index, item in ipairs(writes) do
      requests[index] = {address=item.address, flags=gg.TYPE_DWORD}
    end
    local values = Memory.readMany(requests)
    for index, actual in ipairs(values) do
      if not sameU32(actual.value, writes[index].value) then
        error((label or "宠物数值") .. "写后验证失败", 0)
      end
    end
  end

  local function writeAndVerifyDwords(writes, label, validateIdentity)
    if #writes == 0 then return false end
    local specs = {}
    for index, write in ipairs(writes) do
      specs[index] = {
        kind="raw", address=write.address,
        flags=write.flags or gg.TYPE_DWORD, value=write.value,
        label=(label or "宠物数值") .. "第 " .. index .. " 项",
      }
    end
    Transaction.write(specs, {
      label=label or "宠物数值", validateIdentity=validateIdentity,
    })
    verifyDwordWrites(writes, label)
    return true
  end

  local writeAndVerifyCodec = Codec.writeVerified

  local function selectedState()
    if runtime.petState ~= 1 and runtime.petState ~= 2 then
      runtime.petState = 1
    end
    return runtime.petState
  end

  local function currentStatePets(includeNames)
    local snapshot = readStableSnapshot()
    local pets = listPetsByState(snapshot, selectedState(), includeNames)
    if #pets == 0 then
      gg.toast(
        selectedState() == 1 and
        "未获取到出战宠物" or "未获取到休息宠物"
      )
      return nil
    end
    return snapshot, pets
  end

  local actions = {}

  local function promptIntField(config)
    local snapshot, pets = currentStatePets(false)
    if not snapshot then return false end
    local answer = gg.prompt({config.prompt}, {config.default}, {"number"})
    if not answer then return false end
    local value = requireInteger(
      answer[1], config.minimum, config.maximum, config.title
    )

    requireValidatedSnapshot(snapshot, pets, selectedState())
    local writes = {}
    for _, pet in ipairs(pets) do
      writes[#writes + 1] = {
        address=config.offset(pet), flags=gg.TYPE_DWORD, value=value,
      }
    end
    writeAndVerifyCodec(writes, config.title)
    trace(string.format("pet %s state=%d count=%d value=%d",
      config.traceName, selectedState(), #pets, value))
    gg.toast("修改完成")
    return true
  end

  function actions.PetLevel()
    local levelBackOffset = requireField("宠物等级")
    return promptIntField({
      title="宠物等级", traceName="level",
      prompt="目标等级（1-75）", default=75, minimum=1, maximum=75,
      offset=function(pet) return pet.stateAddress - levelBackOffset end,
    })
  end

  function actions.Nirvana()
    local snapshot, pets = currentStatePets(false)
    if not snapshot then return false end
    local preset = {1, 1, 1, 1, 1, 1, 1}

    requireValidatedSnapshot(snapshot, pets, selectedState())
    local ownerOffset = requireField("宠物涅槃")
    local writes, owners = {}, {}
    for _, pet in ipairs(pets) do
      local ownerField = pet.stateAddress + ownerOffset
      local owner = Memory.pointer(ownerField)
      if owner == 0 or not Memory.isMapped(owner, #preset * 12) then
        error("宠物涅槃数据尚未加载", 0)
      end
      owners[#owners + 1] = {field=ownerField, address=owner}
      for index, value in ipairs(preset) do
        writes[#writes + 1] = {
          address=owner + (index - 1) * 12,
          flags=gg.TYPE_DWORD,
          value=value,
        }
      end
    end
    writeAndVerifyCodec(writes, "宠物涅槃", function()
      validateStructureIdentity(snapshot, pets, selectedState())
      for _, owner in ipairs(owners) do
        if Memory.pointer(owner.field) ~= owner.address then
          error("宠物涅槃子对象已经变化", 0)
        end
      end
      return true
    end)
    trace(string.format("pet nirvana state=%d count=%d mode=all_open",
      selectedState(), #pets))
    gg.toast("修改完成")
    return true
  end

  local function promptFloatFields(config)
    local snapshot, pets = currentStatePets(false)
    if not snapshot then return false end
    local answer = gg.prompt(config.labels, config.defaults, config.types)
    if not answer then return false end

    local values = {}
    for index, raw in ipairs(answer) do
      if raw ~= "" and raw ~= nil then
        values[index] = requireInteger(
          raw, config.minimum, config.maximum, config.names[index]
        )
      end
    end
    if not next(values) then return false end

    requireValidatedSnapshot(snapshot, pets, selectedState())
    local baseOffset = requireField(config.field)
    local writes = {}
    for _, pet in ipairs(pets) do
      local baseAddress = pet.stateAddress + baseOffset
      for index, value in pairs(values) do
        writes[#writes + 1] = {
          address=baseAddress + (index - 1) * 12,
          flags=gg.TYPE_DWORD,
          value=floatBits(value),
        }
      end
    end
    writeAndVerifyCodec(writes, config.title)
    trace(string.format("pet %s state=%d count=%d",
      config.traceName, selectedState(), #pets))
    gg.toast("修改完成")
    return true
  end

  function actions.Aptitude()
    return promptFloatFields({
      title="宠物资质",
      traceName="aptitude",
      field="宠物生命",
      labels={
        "目标生命资质（1-100000）",
        "目标魔法资质（1-100000）",
        "目标攻击资质（1-100000）",
        "目标防御资质（1-100000）",
      },
      names={"生命资质", "魔法资质", "攻击资质", "防御资质"},
      defaults={2000, 2000, 2000, 2000},
      types={"number", "number", "number", "number"},
      minimum=1,
      maximum=100000,
    })
  end

  function actions.Talent()
    return promptFloatFields({
      title="宠物根骨",
      traceName="talent",
      field="宠物根骨",
      labels={
        "目标根骨（1-100）",
        "目标悟性（1-100）",
        "目标灵力（1-100）",
      },
      names={"根骨", "悟性", "灵力"},
      defaults={20, 20, 20},
      types={"number", "number", "number"},
      minimum=1,
      maximum=100,
    })
  end

  function actions.tire()
    local tierOffset = requireField("宠物阶数")
    return promptIntField({
      title="宠物阶数", traceName="tier",
      prompt="目标阶数（0-20）", default=1, minimum=0, maximum=20,
      offset=function(pet) return pet.stateAddress + tierOffset end,
    })
  end

  function actions.vanish()
    local snapshot = readStableSnapshot(true)
    if snapshot.count == 0 then
      gg.toast("当前没有宠物")
      return false
    end
    local confirmed = gg.alert(
      "此操作会让当前宠物列表全部消失，是否继续？",
      "确认消失", "取消"
    )
    if confirmed ~= 1 then return false end

    local current, validationProblem = validateSnapshot(
      snapshot, snapshot.pets, nil, true
    )
    if not current then error(validationProblem, 0) end
    snapshot = current
    local upper, count = snapshot.upperAddress, snapshot.countAddress
    local fields = {
      {upper + 8, gg.TYPE_DWORD},
      {upper + 12, gg.TYPE_DWORD},
      {upper + 16, gg.TYPE_QWORD},
      {count + 8, gg.TYPE_DWORD},
      {count + 12, gg.TYPE_DWORD},
      {count, gg.TYPE_DWORD},
    }
    local specs = {}
    for index, field in ipairs(fields) do
      specs[index] = {
        kind="raw", address=field[1], flags=field[2],
        value=0, label="宠物消失字段 " .. index,
      }
    end
    local function validateVanishIdentity()
      local logicalCapacity, managerAddress = readLogicalCapacity()
      if logicalCapacity ~= snapshot.logicalCapacity or
         managerAddress ~= snapshot.managerAddress then
        error("宠物消失期间管理器或真实格数发生变化", 0)
      end
      local upperAddress, countAddress, arrayAddress =
        resolveStructureAddresses()
      if upperAddress ~= snapshot.upperAddress or
         countAddress ~= snapshot.countAddress or
         arrayAddress ~= snapshot.arrayAddress then
        error("宠物消失期间列表结构发生变化", 0)
      end
      local requests = {
        {address=countAddress, flags=gg.TYPE_DWORD},
        {address=countAddress + 4, flags=gg.TYPE_DWORD},
      }
      for index = 1, snapshot.count do
        requests[#requests + 1] = {
          address=snapshot.arrayAddress + (index - 1) * 8,
          flags=gg.TYPE_QWORD,
        }
      end
      local values = Memory.readMany(requests)
      local liveCount = tonumber(values[1].value)
      if (liveCount ~= snapshot.count and liveCount ~= 0) or
         tonumber(values[2].value) ~= snapshot.capacity then
        error("宠物消失期间数量或物理容量发生变化", 0)
      end
      for index, pet in ipairs(snapshot.pets) do
        if tonumber(values[2 + index].value) ~= tonumber(pet.petRaw) then
          error("宠物消失期间原宠物槽位发生变化", 0)
        end
      end
      return true
    end
    Transaction.write(specs, {
      label="宠物消失",
      validateIdentity=validateVanishIdentity,
    })
    local vanished = readStableSnapshot(true)
    if vanished.managerAddress ~= snapshot.managerAddress or
       vanished.countAddress ~= snapshot.countAddress or
       vanished.count ~= 0 or vanished.capacity ~= snapshot.capacity or
       tonumber(Memory.read(
         snapshot.upperAddress + 16, gg.TYPE_QWORD
       )) ~= 0 then
      error("宠物消失写后快照验证失败", 0)
    end
    trace(string.format("pet vanish old_count=%d", snapshot.count))
    gg.toast("宠物已消失")
    return true
  end

  function actions.qcxx()
    local snapshot = readStableSnapshot()
    if snapshot.count == 0 then
      gg.toast("当前没有宠物")
      return false
    end

    local writes = {}
    local changed = {}
    for _, pet in ipairs(snapshot.pets) do
      if pet.state ~= 2 then
        writes[#writes + 1] = {
          address=pet.stateAddress,
          flags=gg.TYPE_DWORD,
          value=2,
        }
        changed[#changed + 1] = pet
      end
    end
    if #writes == 0 then
      gg.toast("所有宠物已处于休息状态")
      return false
    end

    requireValidatedSnapshot(snapshot, changed, nil)
    writeAndVerifyDwords(writes, "全宠休息")
    trace(string.format("pet rest_all changed=%d", #writes))
    gg.toast("修改完成")
    return true
  end

  return {
    actions=actions,
    readStableSnapshot=readStableSnapshot,
    listPetsByState=listPetsByState,
    validateSnapshot=validateSnapshot,
    readLogicalCapacity=readLogicalCapacity,
    ensureAppendCapacity=ensureAppendCapacity,
    physicalMaximum=PHYSICAL_MAXIMUM,
  }
end)

installModule("player", function(app)
  local Memory = app.Memory
  local Codec = app.Codec
  local Transaction = app.Transaction
  local TAG = app.TAG
  local FIELD = app.FIELD
  local PANEL_FIELDS = app.PANEL_FIELDS
  local runtime = app.runtime
  local requireInteger = app.requireInteger
  local requireNumber = app.requireNumber
  local floatToDword = app.floatToDword
  local untagPointer = app.untagPointer
  local sameU32 = app.sameU32
  local trace = app.trace
  local gameBase = app.gameBase
  local requirePath = app.requirePath
  local requireField = app.requireField
  local resolveTag = app.resolveTag
  local MIN_VALID_POINTER = app.MIN_VALID_POINTER
  local MAX_TASK_COUNT = 2048
  local PASSIVE_COUNT = 6
  local FAIRY_SLOT_SIZE = app.FAIRY_SLOT_SIZE
  local FAIRY_MAX_SLOTS = app.FAIRY_MAX_SLOTS

  local CURRENCY = {
    {name="灵魂", field="灵魂", maximum=5000000, preset=4000000},
    {name="仙气", field="仙气", maximum=8000000, preset=8000000},
    {name="战功", field="战功", maximum=80000, preset=80000},
  }

  local BENMING = {
    {name="阿修罗", id=509200},
    {name="齐天大圣", id=509201},
    {name="东皇太一", id=509202},
    {name="真武大帝", id=509203},
    {name="杨戬", id=509204},
  }

  local FAIRY_ARTS = {
    {name="升龙破", id=1101},
    {name="重棍", id=1112},
    {name="崩老头", id=1142},
    {name="龙卷风摧毁停车场", id=1221},
    {name="群主弟弟", id=1232},
    {name="如来神掌", id=2142},
    {name="三千雷动", id=13245},
    {name="如意金箍", id=12353},
    {name="吸怪球", id=92203},
  }

  local function resolvePerson(size)
    return resolveTag("人物基址", size or 1)
  end

  local function nonBlank(value)
    return value ~= nil and tostring(value):match("^%s*$") == nil
  end

  local function compareLists(left, right)
    if #left ~= #right then return false end
    for index = 1, #left do
      if left[index] ~= right[index] then return false end
    end
    return true
  end

  local function requireSame(label, before, after)
    if before ~= after then
      error(label .. "在选择期间发生变化，请重新操作", 0)
    end
    return after
  end

  local writeCodecItems = Codec.writeVerified

  local ownedFreezes = {}

  local function removeOwnedFreeze(label)
    local record = ownedFreezes[label]
    if not record then return false end
    if type(gg.removeListItems) ~= "function" then
      error("当前 GG 不支持安全移除脚本冻结项", 0)
    end
    gg.removeListItems(record.entries)
    ownedFreezes[label] = nil
    return true
  end

  local function cleanupOwnedFreezes(force)
    local labels = {}
    local problems = {}
    for label in pairs(ownedFreezes) do labels[#labels + 1] = label end
    for _, label in ipairs(labels) do
      local record = ownedFreezes[label]
      local valid = false
      if not force and record and not record.pendingRemoval and
         type(record.validator) == "function" then
        local ok, result = pcall(record.validator)
        valid = ok and result == true
      end
      if force or not valid then
        local ok, problem = pcall(removeOwnedFreeze, label)
        if not ok then
          problems[#problems + 1] = label .. "：" .. tostring(problem)
        end
      end
    end
    if #problems > 0 then
      error("部分脚本冻结项清理失败：" .. table.concat(problems, "；"), 0)
    end
    return true
  end

  local function installOwnedFreeze(label, entries, validator)
    if type(gg.addListItems) ~= "function" or
       type(gg.removeListItems) ~= "function" then
      error("当前 GG 不支持可清理的冻结数值", 0)
    end
    if type(validator) ~= "function" then
      error("脚本冻结项缺少动态身份校验器", 0)
    end
    local function identityValid()
      local ok, result = pcall(validator)
      return ok and result == true
    end
    removeOwnedFreeze(label)
    if not identityValid() then
      error(label .. "冻结目标在安装前已经变化", 0)
    end
    local record = {
      entries=entries,
      validator=validator,
      pendingRemoval=false,
    }
    ownedFreezes[label] = record
    local ok, problem = pcall(gg.addListItems, entries)
    if not ok then
      local removed, removeProblem = pcall(gg.removeListItems, entries)
      if removed then ownedFreezes[label] = nil end
      if not removed then record.pendingRemoval = true end
      error(
        "添加脚本冻结项失败：" .. tostring(problem) ..
        (removed and "；补偿清理完成" or
          "；补偿清理失败并已保留所有权记录：" .. tostring(removeProblem)),
        0
      )
    end
    if not identityValid() then
      local removed, removeProblem = pcall(gg.removeListItems, entries)
      if removed then ownedFreezes[label] = nil end
      if not removed then record.pendingRemoval = true end
      error(
        label .. "冻结目标在安装后发生变化" ..
        (removed and "，冻结项已移除" or
          "，移除失败并已保留所有权记录：" .. tostring(removeProblem)),
        0
      )
    end
    return true
  end

  local function freezeCodec(address, label, validator)
    local requests = {
      {address=address, flags=gg.TYPE_DWORD},
      {address=address + 4, flags=gg.TYPE_DWORD},
      {address=address + 8, flags=gg.TYPE_DWORD},
    }
    if validator() == false then error(label .. "冻结目标已经变化", 0) end
    local first = Memory.readMany(requests)
    if validator() == false then error(label .. "冻结目标已经变化", 0) end
    local values = Memory.readMany(requests)
    for index = 1, #values do
      if not sameU32(first[index].value, values[index].value) then
        error(label .. "冻结字段仍在变化，请稍后重试", 0)
      end
    end
    if validator() == false then error(label .. "冻结目标已经变化", 0) end
    local entries = {}
    for index, value in ipairs(values) do
      entries[index] = {
        address=value.address,
        flags=gg.TYPE_DWORD,
        value=value.value,
        freeze=true,
        name=label,
      }
    end
    installOwnedFreeze(label, entries, validator)
  end

  local function writeAndFreezeCodec(address, value, label, validator)
    local valid, matches = pcall(validator)
    if not valid or matches ~= true then
      error(label .. "目标在写入前已经变化", 0)
    end
    local original = Memory.readMany({
      {address=address, flags=gg.TYPE_DWORD},
      {address=address + 4, flags=gg.TYPE_DWORD},
      {address=address + 8, flags=gg.TYPE_DWORD},
    })
    Codec.writeMany({{address=address, value=value}}, {
      label=label,
      validateIdentity=validator,
    })
    local installed, installProblem = pcall(
      freezeCodec, address, label, validator
    )
    if installed then return true end
    local restored, restoreProblem = pcall(Transaction.write, {
      {kind="raw", address=address, flags=gg.TYPE_DWORD,
       value=original[1].value},
      {kind="raw", address=address + 4, flags=gg.TYPE_DWORD,
       value=original[2].value},
      {kind="raw", address=address + 8, flags=gg.TYPE_DWORD,
       value=original[3].value},
    }, {label=label .. "冻结安装补偿", validateIdentity=validator})
    if restored then
      error("添加" .. label .. "冻结失败，已恢复原值：" ..
        tostring(installProblem), 0)
    end
    error("添加" .. label .. "冻结失败且恢复失败：" ..
      tostring(installProblem) .. "；" .. tostring(restoreProblem), 0)
  end

  local function writeRawFloat(address, value, label, validateIdentity)
    Transaction.write({{
      kind="raw", address=address, value=value,
      flags=gg.TYPE_FLOAT, label=label,
    }}, {label=label, validateIdentity=validateIdentity})
    local actual = tonumber(Memory.read(address, gg.TYPE_FLOAT))
    local tolerance = math.max(0.0001, math.abs(value) * 0.00001)
    if not actual or math.abs(actual - value) > tolerance then
      error(label .. "写后验证失败", 0)
    end
  end

  local function personFieldAddress(fieldName, size)
    local person = resolvePerson(1)
    local address = person + requireField(fieldName)
    if not Memory.isMapped(address, size or 12) then
      error(fieldName .. "字段尚未加载", 0)
    end
    return person, address
  end

  local function readPlayerLevel()
    local person, address = personFieldAddress("人物等级", 12)
    local level = tonumber(Codec.decode(address))
    if not level or level < 1 or level > 1000 then
      error("当前人物等级异常：" .. tostring(level), 0)
    end
    return level, person
  end

  local function currencySnapshot()
    local root = resolveTag("A0基址", 1)
    local addresses = {}
    for index, config in ipairs(CURRENCY) do
      local address = root + requireField(config.field)
      if not Memory.isMapped(address, 12) then
        error(config.name .. "地址尚未加载", 0)
      end
      addresses[index] = address
    end
    return {root=root, addresses=addresses}
  end

  local function validateCurrencySnapshot(snapshot)
    local current = currencySnapshot()
    requireSame("货币数据", snapshot.root, current.root)
    if not compareLists(snapshot.addresses, current.addresses) then
      error("货币字段在选择期间发生变化", 0)
    end
    return current
  end

  local function passiveSnapshot()
    local root = resolveTag("被动基址", PASSIVE_COUNT * 8)
    local slots, targets = {}, {}
    for index = 1, PASSIVE_COUNT do
      local slot = root + (index - 1) * 8
      local object = Memory.pointer(slot)
      local target = object + requireField("被动等级")
      if object == 0 or not Memory.isMapped(target, 12) then
        error("第 " .. index .. " 个被动对象尚未加载", 0)
      end
      slots[index] = object
      targets[index] = target
    end
    return {root=root, slots=slots, targets=targets}
  end

  local function validatePassiveSnapshot(snapshot)
    local current = passiveSnapshot()
    requireSame("被动根对象", snapshot.root, current.root)
    if not compareLists(snapshot.slots, current.slots) then
      error("被动对象在选择期间发生变化", 0)
    end
    return current
  end

  local function benmingSnapshot()
    local base = resolveTag("本命指针", 148)
    local tier = resolveTag("本命阶数", 12)
    local spiritTier = resolveTag("灵物阶数", 12)
    local addresses = {
      levelA=base + requireField("本命等级"),
      levelB=base + requireField("本命等级副本"),
      tier=tier,
      spiritTier=spiritTier,
      item=base + requireField("本命灵物"),
    }
    for name, address in pairs(addresses) do
      if not Memory.isMapped(address, 12) then
        error("本命字段尚未加载：" .. name, 0)
      end
    end
    return {base=base, tier=tier, spiritTier=spiritTier, addresses=addresses}
  end

  local function validateBenmingSnapshot(snapshot)
    local current = benmingSnapshot()
    requireSame("本命对象", snapshot.base, current.base)
    requireSame("本命阶数对象", snapshot.tier, current.tier)
    requireSame("灵物阶数对象", snapshot.spiritTier, current.spiritTier)
    return current
  end

  local function chooseBenming()
    local labels = {}
    for index, item in ipairs(BENMING) do labels[index] = item.name end
    local choice = gg.choice(labels, nil, "选择本命")
    if not choice then return nil end
    if not BENMING[choice] then error("本命选项无效", 0) end
    return BENMING[choice]
  end

  local function speedSnapshot(fieldName, trailingOffset)
    local person = resolvePerson(1)
    local pointerField = person + requireField(fieldName)
    local owner = Memory.pointer(pointerField)
    local address = owner + trailingOffset
    if owner == 0 or not Memory.isMapped(address, 4) then
      error(fieldName .. "对象尚未加载", 0)
    end
    return {person=person, owner=owner, address=address}
  end

  local function validateSpeedSnapshot(snapshot, fieldName, trailingOffset)
    local current = speedSnapshot(fieldName, trailingOffset)
    requireSame("人物对象", snapshot.person, current.person)
    requireSame(fieldName .. "对象", snapshot.owner, current.owner)
    return current
  end

  local function readFairyVector(person)
    local field = person + requireField("普攻基址")
    local values = Memory.readMany({
      {address=field, flags=gg.TYPE_QWORD},
      {address=field + 8, flags=gg.TYPE_QWORD},
      {address=field + 16, flags=gg.TYPE_QWORD},
    })
    local owner = untagPointer(values[1].value)
    local finish = untagPointer(values[2].value)
    local capacity = untagPointer(values[3].value)
    if owner < MIN_VALID_POINTER or finish < owner or capacity < finish or
       (finish - owner) % FAIRY_SLOT_SIZE ~= 0 or
       (capacity - owner) % FAIRY_SLOT_SIZE ~= 0 then
      error("普攻技能对象尚未加载", 0)
    end
    local count = (finish - owner) // FAIRY_SLOT_SIZE
    local capacityCount = (capacity - owner) // FAIRY_SLOT_SIZE
    if count < 1 or count > FAIRY_MAX_SLOTS or
       capacityCount < count or capacityCount > FAIRY_MAX_SLOTS or
       not Memory.isMapped(owner, count * FAIRY_SLOT_SIZE) then
      error("普攻技能容器数量异常", 0)
    end
    return {
      owner=owner, finish=finish, capacity=capacity,
      count=count, capacityCount=capacityCount,
    }
  end

  local function fairySnapshot()
    local person = resolvePerson(1)
    local vector = readFairyVector(person)
    local requests = {}
    for index = 1, vector.count do
      requests[index] = {
        address=vector.owner + (index - 1) * FAIRY_SLOT_SIZE,
      }
    end
    return {
      person=person,
      owner=vector.owner,
      finish=vector.finish,
      capacity=vector.capacity,
      count=vector.count,
      requests=requests,
      values=Codec.decode64Many(requests),
    }
  end

  local function validateFairySnapshot(snapshot)
    local current = fairySnapshot()
    requireSame("人物对象", snapshot.person, current.person)
    requireSame("普攻技能对象", snapshot.owner, current.owner)
    requireSame("普攻技能末端", snapshot.finish, current.finish)
    requireSame("普攻技能容量", snapshot.capacity, current.capacity)
    requireSame("普攻技能数量", snapshot.count, current.count)
    if not compareLists(snapshot.values, current.values) then
      error("普攻技能槽在选择期间发生变化", 0)
    end
    return current
  end

  local function validateFairyIdentity(snapshot)
    local person = resolvePerson(1)
    requireSame("人物对象", snapshot.person, person)
    local current = readFairyVector(person)
    requireSame("普攻技能对象", snapshot.owner, current.owner)
    requireSame("普攻技能末端", snapshot.finish, current.finish)
    requireSame("普攻技能容量", snapshot.capacity, current.capacity)
    requireSame("普攻技能数量", snapshot.count, current.count)
    return true
  end

  local function mapSnapshot(pathName)
    local address = resolveTag(pathName, 12)
    return {address=address, value=Codec.decode(address)}
  end

  local function validateMapSnapshot(snapshot, pathName, label)
    local current = mapSnapshot(pathName)
    requireSame(label .. "对象", snapshot.address, current.address)
    if not sameU32(snapshot.value, current.value) then
      error(label .. "数值在输入期间发生变化", 0)
    end
    return current
  end

  local function globalTaskSnapshot()
    local countAddress = resolveTag("全局任务数量", 24)
    local count = tonumber(Memory.read(countAddress, gg.TYPE_DWORD))
    if not count or count ~= math.floor(count) or count < 0 or
       count > MAX_TASK_COUNT then
      error("全局任务数量异常：" .. tostring(count), 0)
    end
    local array = Memory.pointer(countAddress + 16)
    if count > 0 and (array == 0 or not Memory.isMapped(array, count * 8)) then
      error("全局任务数组尚未加载", 0)
    end

    local slots, targets = {}, {}
    if count > 0 then
      local requests = {}
      for index = 1, count do
        requests[index] = {
          address=array + (index - 1) * 8,
          flags=gg.TYPE_QWORD,
        }
      end
      local values = Memory.readMany(requests)
      for index, value in ipairs(values) do
        local object = untagPointer(value.value)
        local target = object + requireField("任务状态")
        if object == 0 or not Memory.isMapped(target, 12) then
          error("第 " .. index .. " 个全局任务对象无效", 0)
        end
        slots[index] = object
        targets[index] = target
      end
    end
    return {
      countAddress=countAddress,
      count=count,
      array=array,
      slots=slots,
      targets=targets,
    }
  end

  local function stableGlobalTaskSnapshot()
    local first = globalTaskSnapshot()
    local second = globalTaskSnapshot()
    if first.countAddress ~= second.countAddress or
       first.count ~= second.count or first.array ~= second.array or
       not compareLists(first.slots, second.slots) then
      error("全局任务数据正在刷新，请稍后重试", 0)
    end
    return second
  end

  local function validateGlobalTaskIdentity(snapshot)
    local current = stableGlobalTaskSnapshot()
    requireSame("全局任务数量字段", snapshot.countAddress, current.countAddress)
    requireSame("全局任务数量", snapshot.count, current.count)
    requireSame("全局任务数组", snapshot.array, current.array)
    if not compareLists(snapshot.slots, current.slots) then
      error("全局任务对象已经变化", 0)
    end
    return true
  end

  local actions = {}

  function actions.huobiduoxuan()
    local choice = gg.alert(
      "选择货币修改方式：\n灵魂最多 500 万，仙气最多 800 万，战功最多 8 万。",
      "自定货币", "一键货币"
    )
    if choice == 1 then return actions.zidinghuobi() end
    if choice == 2 then return actions.yijianhuobi() end
    return false
  end

  function actions.zidinghuobi()
    local snapshot = currencySnapshot()
    local labels, defaults, types = {}, {}, {}
    for index, config in ipairs(CURRENCY) do
      labels[index] = string.format("%s（0-%d）", config.name, config.maximum)
      defaults[index] = ""
      types[index] = "number"
    end
    local answer = gg.prompt(labels, defaults, types)
    if not answer then return false end

    local values = {}
    for index, config in ipairs(CURRENCY) do
      if nonBlank(answer[index]) then
        values[index] = requireInteger(
          answer[index], 0, config.maximum, config.name
        )
      end
    end
    if not next(values) then
      gg.toast("未输入需要修改的货币")
      return false
    end

    snapshot = validateCurrencySnapshot(snapshot)
    local writes = {}
    for index, value in pairs(values) do
      writes[#writes + 1] = {address=snapshot.addresses[index], value=value}
    end
    writeCodecItems(writes, "货币", function()
      validateCurrencySnapshot(snapshot)
    end)
    trace("player currency custom count=" .. #writes)
    gg.toast("修改完毕")
    return true
  end

  function actions.yijianhuobi()
    local snapshot = currencySnapshot()
    local writes = {}
    for index, config in ipairs(CURRENCY) do
      writes[index] = {
        address=snapshot.addresses[index], value=config.preset,
      }
    end
    writeCodecItems(writes, "货币", function()
      validateCurrencySnapshot(snapshot)
    end)
    trace("player currency preset")
    gg.toast("修改完毕")
    return true
  end

  function actions.beidongduoxuan()
    local choice = gg.alert(
      "选择被动修改方式：\n被动最高 80 级，一键满级要求角色至少 80 级。",
      "自定被动", "一键满级"
    )
    if choice == 1 then return actions.zidingbeidong() end
    if choice == 2 then return actions.yijianmanbei() end
    return false
  end

  function actions.zidingbeidong()
    local snapshot = passiveSnapshot()
    local labels, defaults, types = {}, {}, {}
    for index = 1, PASSIVE_COUNT do
      labels[index] = string.format("第 %d 个被动（0-80）", index)
      defaults[index] = ""
      types[index] = "number"
    end
    local answer = gg.prompt(labels, defaults, types)
    if not answer then return false end

    local values, requestsFull = {}, false
    for index = 1, PASSIVE_COUNT do
      if nonBlank(answer[index]) then
        values[index] = requireInteger(answer[index], 0, 80, "被动等级")
        if values[index] == 80 then requestsFull = true end
      end
    end
    if not next(values) then
      gg.toast("未输入需要修改的被动")
      return false
    end

    snapshot = validatePassiveSnapshot(snapshot)
    local levelPerson
    if requestsFull then
      local level
      level, levelPerson = readPlayerLevel()
      if level < 80 then error("角色未满 80 级，不能写入满级被动", 0) end
    end
    local writes = {}
    for index, value in pairs(values) do
      writes[#writes + 1] = {address=snapshot.targets[index], value=value}
    end
    writeCodecItems(writes, "被动", function()
      validatePassiveSnapshot(snapshot)
      if levelPerson then
        local liveLevel, livePerson = readPlayerLevel()
        requireSame("人物对象", levelPerson, livePerson)
        if liveLevel < 80 then error("角色等级已变化，拒绝写入满级被动", 0) end
      end
    end)
    trace("player passive custom count=" .. #writes)
    gg.toast("修改完成")
    return true
  end

  function actions.yijianmanbei()
    local level, levelPerson = readPlayerLevel()
    if level < 80 then error("角色未满 80 级，不能一键满被动", 0) end
    local snapshot = passiveSnapshot()
    local writes = {}
    for index, address in ipairs(snapshot.targets) do
      writes[index] = {address=address, value=80}
    end
    writeCodecItems(writes, "被动", function()
      validatePassiveSnapshot(snapshot)
      local liveLevel, livePerson = readPlayerLevel()
      requireSame("人物对象", levelPerson, livePerson)
      if liveLevel < 80 then error("角色等级已变化，拒绝写入满级被动", 0) end
    end)
    trace("player passive full")
    gg.toast("修改完毕")
    return true
  end

  function actions.lingbenziding()
    local snapshot = benmingSnapshot()
    local answer = gg.prompt({
      "本命等级（1-1000）",
      "本命阶数（0-1000）",
      "灵物阶数（0-1000）",
      "同时选择无中本命",
    }, {"", "", "", false}, {
      "number", "number", "number", "checkbox",
    })
    if not answer then return false end

    local level = nonBlank(answer[1]) and
      requireInteger(answer[1], 1, 1000, "本命等级") or nil
    local tier = nonBlank(answer[2]) and
      requireInteger(answer[2], 0, 1000, "本命阶数") or nil
    local spiritTier = nonBlank(answer[3]) and
      requireInteger(answer[3], 0, 1000, "灵物阶数") or nil
    local chosen = answer[4] == true and chooseBenming() or nil
    if level == nil and tier == nil and spiritTier == nil and chosen == nil then
      gg.toast("未选择需要修改的本命数值")
      return false
    end

    snapshot = validateBenmingSnapshot(snapshot)
    local writes = {}
    if level then
      local encodedLevel = level * level - 1
      writes[#writes + 1] = {
        address=snapshot.addresses.levelA, value=encodedLevel,
      }
      writes[#writes + 1] = {
        address=snapshot.addresses.levelB, value=encodedLevel,
      }
    end
    if tier then
      writes[#writes + 1] = {address=snapshot.addresses.tier, value=tier}
    end
    if spiritTier then
      writes[#writes + 1] = {
        address=snapshot.addresses.spiritTier, value=spiritTier,
      }
    end
    if chosen then
      writes[#writes + 1] = {
        address=snapshot.addresses.item, value=chosen.id,
      }
    end
    writeCodecItems(writes, "本命", function()
      validateBenmingSnapshot(snapshot)
    end)
    trace("player benming custom count=" .. #writes)
    gg.toast("修改完成")
    return true
  end

  function actions.jingyanduoxuan()
    local choice = gg.alert(
      "选择经验修改方式：",
      "自定当前经验", "自定打怪经验倍率"
    )
    if choice == 1 then return actions.zidingjingyan() end
    if choice == 2 then return actions.jingyanbeilv() end
    return false
  end

  local function experienceAction(isMultiplier)
    local person, address = personFieldAddress("人物当前经验", 24)
    if isMultiplier then address = address + 12 end
    local originalValue = tonumber(Codec.decode(address))
    local minimum = isMultiplier and 1 or 0
    local maximum = isMultiplier and 100000 or 2000000000
    if not originalValue or originalValue ~= math.floor(originalValue) or
       originalValue < minimum or originalValue > maximum then
      error("当前" .. (isMultiplier and "经验倍率" or "经验量") ..
        "异常：" .. tostring(originalValue), 0)
    end
    local label = string.format(
      "%s（当前 %d，范围 %d-%d）",
      isMultiplier and "目标经验倍率" or "目标经验量",
      originalValue, minimum, maximum
    )
    local defaults = {originalValue}
    local answer = gg.prompt({label}, defaults, {"number"})
    if not answer then return false end
    local value
    if isMultiplier then
      value = requireInteger(answer[1], 1, 100000, "经验倍率")
    else
      value = requireInteger(answer[1], 0, 2000000000, "当前经验")
    end
    local currentPerson, currentAddress =
      personFieldAddress("人物当前经验", 24)
    requireSame("人物对象", person, currentPerson)
    if isMultiplier then currentAddress = currentAddress + 12 end
    requireSame("经验字段", address, currentAddress)
    if Codec.decode(currentAddress) ~= originalValue then
      error("经验字段在输入期间发生变化，请重新操作", 0)
    end
    writeCodecItems({{address=currentAddress, value=value}}, "经验", function()
      local livePerson, liveAddress = personFieldAddress("人物当前经验", 24)
      if isMultiplier then liveAddress = liveAddress + 12 end
      return livePerson == currentPerson and liveAddress == currentAddress
    end)
    trace(string.format("player experience multiplier=%s value=%d",
      tostring(isMultiplier), value))
    gg.toast("修改完毕")
    return true
  end

  function actions.zidingjingyan()
    return experienceAction(false)
  end

  function actions.jingyanbeilv()
    return experienceAction(true)
  end

  function actions.jiasu()
    local snapshot = speedSnapshot("人物加速", 32)
    local answer = gg.prompt({
      "目标倍速（0.1-20）", "三倍加速",
    }, {1, false}, {"number", "checkbox"})
    if not answer then return false end
    local speed = requireNumber(answer[1], 0.1, 20, "人物倍速")
    if answer[2] == true then speed = 3 end
    snapshot = validateSpeedSnapshot(snapshot, "人物加速", 32)
    app.restoreJournal.capture("人物加速", "float",
      {{address=snapshot.address, value=speed}}, function()
        validateSpeedSnapshot(snapshot, "人物加速", 32)
        return true
      end)
    writeRawFloat(snapshot.address, speed, "人物加速", function()
      validateSpeedSnapshot(snapshot, "人物加速", 32)
      return true
    end)
    trace("player speed=" .. tostring(speed))
    gg.toast("修改完成")
    return true
  end

  function actions.hudun()
    local person, address = personFieldAddress("护盾基址", 24)
    app.restoreJournal.capture("护盾", "key", {
      {address=address, value=1}, {address=address + 12, value=1},
    }, function()
      local livePerson, liveAddress = personFieldAddress("护盾基址", 24)
      return livePerson == person and liveAddress == address
    end)
    writeCodecItems({
      {address=address, value=1},
      {address=address + 12, value=1},
    }, "护盾", function()
      local livePerson, liveAddress = personFieldAddress("护盾基址", 24)
      return livePerson == person and liveAddress == address
    end)
    trace("player shield enabled")
    gg.toast("开启成功")
    return true
  end

  local function multiplierAction(fieldName, defaultValue, maximum, label)
    local person, address = personFieldAddress(fieldName, 12)
    local answer = gg.prompt({
      label .. "（0.01-" .. tostring(maximum) .. "）",
      "冻结当前数值（易闪退）",
    }, {defaultValue, false}, {"number", "checkbox"})
    if not answer then return false end
    local input = tostring(answer[1] or "")
    local freezeRequested = answer[2] == true
    local freezeWasRequested = freezeRequested
    if input == "" and not freezeRequested then return false end
    local value
    if input ~= "" then
      value = requireNumber(answer[1], 0.01, maximum, label)
    end
    local currentPerson, currentAddress = personFieldAddress(fieldName, 12)
    requireSame("人物对象", person, currentPerson)
    requireSame(label .. "字段", address, currentAddress)
    removeOwnedFreeze(label)
    if value ~= nil then
      local bits = floatToDword(value)
      local validator = function()
        local livePerson, liveAddress = personFieldAddress(fieldName, 12)
        return livePerson == currentPerson and liveAddress == currentAddress
      end
      app.restoreJournal.capture(label, "key",
        {{address=currentAddress, value=bits}}, validator)
      if freezeRequested then
        writeAndFreezeCodec(currentAddress, bits, label, validator)
        freezeRequested = false
      else
        writeCodecItems({{address=currentAddress, value=bits}}, label, validator)
      end
    end
    if freezeRequested then
      freezeCodec(currentAddress, label, function()
        local livePerson, liveAddress = personFieldAddress(fieldName, 12)
        return livePerson == currentPerson and liveAddress == currentAddress
      end)
    end
    trace(string.format("player %s=%s freeze=%s",
      fieldName, tostring(value or "current"), tostring(freezeWasRequested)))
    gg.toast("开启成功")
    return true
  end

  function actions.beilv()
    return multiplierAction("人物秒杀", 500, 100000, "目标倍率")
  end

  function actions.xspg()
    local snapshot = fairySnapshot()
    local labels = {}
    for index, item in ipairs(FAIRY_ARTS) do labels[index] = item.name end
    local choice = gg.choice(labels, nil, "选择普攻仙术")
    if not choice then return false end
    local selected = FAIRY_ARTS[choice]
    if not selected then error("仙术选项无效", 0) end
    snapshot = validateFairySnapshot(snapshot)

    local targets = {}
    for index, value in ipairs(snapshot.values) do
      if value >= 0 and value <= 999999 then
        targets[#targets + 1] = snapshot.requests[index].address
      end
    end
    if #targets == 0 then error("未找到可替换的普攻技能槽", 0) end
    local specs = {}
    for index, address in ipairs(targets) do
      specs[index] = {
        kind="key64", address=address, value=selected.id,
        label="第 " .. index .. " 个普攻仙术槽",
      }
    end
    local restoreItems = {}
    for index, address in ipairs(targets) do
      restoreItems[index] = {address=address, value=selected.id}
    end
    app.restoreJournal.capture("普攻仙术", "key64", restoreItems, function()
      return validateFairyIdentity(snapshot)
    end)
    Codec.transaction(specs, {
      label="普攻仙术",
      validateIdentity=function() return validateFairyIdentity(snapshot) end,
      validateApplied=function()
        for _, address in ipairs(targets) do
          if Codec.decode64(address) ~= selected.id then
            error("普攻仙术写后验证失败", 0)
          end
        end
        return true
      end,
    })
    trace(string.format("player fairy attack id=%d slots=%d",
      selected.id, #targets))
    gg.toast("修改完成")
    return true
  end

  function actions.yinshen()
    local person, address = personFieldAddress("人物隐身", 12)
    app.restoreJournal.capture("人物隐身", "key",
      {{address=address, value=1}}, function()
        local livePerson, liveAddress = personFieldAddress("人物隐身", 12)
        return livePerson == person and liveAddress == address
      end)
    writeCodecItems({{address=address, value=1}}, "人物隐身", function()
      local livePerson, liveAddress = personFieldAddress("人物隐身", 12)
      return livePerson == person and liveAddress == address
    end)
    trace("player invisible enabled")
    gg.toast("修改完成")
    return true
  end

  function actions.wlhf()
    local freezeOk, freezeProblem = pcall(cleanupOwnedFreezes, true)
    if app.restoreJournal.count() == 0 then
      if not freezeOk then error(freezeProblem, 0) end
      gg.toast("没有需要恢复的物理修改")
      return false
    end
    local result = app.restoreJournal.restore()
    trace(string.format("physics restore total=%d restored=%d skipped=%d",
      result.total, result.restored, result.skipped))
    local message = string.format("一键恢复完成：恢复 %d 项", result.restored)
    if result.skipped > 0 then
      message = message .. string.format(
        "，跳过 %d 项（已被游戏改动或人物/对象已变化）", result.skipped
      )
    end
    if not freezeOk then
      message = message .. "\n倍率冻结解除失败：" .. tostring(freezeProblem)
    end
    gg.alert(message)
    return true
  end

  function actions.mbsx()
    local person = resolvePerson(1)
    local labels, defaults, types = {}, {}, {}
    for index, field in ipairs(PANEL_FIELDS) do
      labels[index] = field.name .. "（0-100000000，可留空）"
      defaults[index] = ""
      types[index] = "number"
      if not Memory.isMapped(person + field.offset, 12) then
        error(field.name .. "字段尚未加载", 0)
      end
    end
    local answer = gg.prompt(labels, defaults, types)
    if not answer then return false end

    local values = {}
    for index, field in ipairs(PANEL_FIELDS) do
      if nonBlank(answer[index]) then
        values[index] = requireNumber(
          answer[index], 0, 100000000, field.name
        )
      end
    end
    if not next(values) then
      gg.toast("未输入需要修改的面板属性")
      return false
    end
    requireSame("人物对象", person, resolvePerson(1))
    local writes = {}
    for index, value in pairs(values) do
      writes[#writes + 1] = {
        address=person + PANEL_FIELDS[index].offset,
        value=floatToDword(value),
      }
    end
    app.restoreJournal.capture("面板属性", "key", writes, function()
      return resolvePerson(1) == person
    end)
    writeCodecItems(writes, "面板属性", function()
      return resolvePerson(1) == person
    end)
    trace("player panel stats count=" .. #writes)
    gg.toast("修改完成")
    return true
  end

  function actions.kunlunshan()
    local snapshot = mapSnapshot("昆仑山层数")
    local answer = gg.prompt({"目标层数（1-10000）"}, {1}, {"number"})
    if not answer then return false end
    local floor = requireInteger(answer[1], 1, 10000, "昆仑山层数")
    snapshot = validateMapSnapshot(snapshot, "昆仑山层数", "昆仑山")
    writeCodecItems({{address=snapshot.address, value=floor}}, "昆仑山层数", function()
      return resolveTag("昆仑山层数", 12) == snapshot.address
    end)
    trace("map kunlun floor=" .. floor)
    gg.toast("修改完成")
    return true
  end

  function actions.huanle()
    local address = resolveTag("任务基址", 12)
    writeAndFreezeCodec(address, 0, "欢乐任务", function()
      return resolveTag("任务基址", 12) == address
    end)
    trace(string.format("entertainment happy task address=0x%X", address))
    gg.toast("修改完成，切换页面或重进任务即可")
    return true
  end

  function actions.qjrw()
    local snapshot = stableGlobalTaskSnapshot()
    if snapshot.count == 0 then
      gg.toast("当前没有已加载的全局任务")
      return false
    end
    local writes, seen = {}, {}
    for _, address in ipairs(snapshot.targets) do
      if not seen[address] then
        seen[address] = true
        writes[#writes + 1] = {address=address, value=0}
      end
    end
    writeCodecItems(writes, "全局任务", function()
      return validateGlobalTaskIdentity(snapshot)
    end)
    trace(string.format("entertainment global tasks count=%d unique=%d",
      snapshot.count, #writes))
    gg.toast("退出任务界面重进即可")
    return true
  end

  app.cleanupOwnedFreezes = cleanupOwnedFreezes
  return {actions=actions}
end)

installModule("map", function(app)
  local Memory = app.Memory
  local Transaction = app.Transaction
  local PROFILE = app.PROFILE
  local TAG = app.TAG
  local runtime = app.runtime
  local FIELD = app.FIELD
  local untagPointer = app.untagPointer
  local rotateLeft32 = app.rotateLeft32
  local Items = app.items
  local requireBase = app.gameBase
  local trace = app.trace

  local TYPE_DWORD = gg.TYPE_DWORD
  local TYPE_QWORD = gg.TYPE_QWORD
  local state = {noMonster=nil, nineHeavens=nil}
  local actions = {}

  local OFFSET = {
    guideDictionary = 0x08,
    guideFirstNode = 0x18,
    guideNodeKey = 0x100,
    guideNodeArray = 0x108,
    guideNodeNext = 0x120,
    guideNodeRowCount = 0x140,
    guideArray = 0x18,
    guideArraySlots = 0x10,
    guideCacheMaps = {0xA8, 0x90},
    guideCacheKey = 0x20,
    guideCacheLeft = 0x00,
    guideCacheRight = 0x08,
    guideRecord = 0x18,
    guideRecordSteps = 0x20,
    guideRecordStepCount = 0x28,
    guideRecordId = 0x08,
    guideRecordPredecessor = 0x2C,
    mapName = 0x30,
    mapMonsters = 0xE8,
    mapObjectSize = 0xF0,
    monsterParam = 0x20,
    monsterSwitch = 0x50,
  }
  local UNDERWORLD_SLOTS = 12

  local function requireMappedPointer(value, size, label)
    local address = untagPointer(value)
    if address == 0 or not Memory.isMapped(address, size or 1) then
      error(string.format("%s无效: 0x%X", label, address), 0)
    end
    return address
  end

  local function sameValue(actual, expected, flags)
    return actual == expected
  end

  local GUIDE_PREDECESSORS = {
    [900000]=900021, [900002]=900001, [900003]=900000, [900004]=900000,
    [900006]=900005, [900007]=900006, [900008]=900007, [900009]=900008,
    [900011]=900010, [900013]=900012, [900015]=900014, [900016]=900026,
    [900017]=900016, [900018]=900017, [900020]=900019, [900022]=900018,
    [900023]=900022, [900024]=900020, [900025]=900024, [900026]=900015,
    [900027]=900023, [900028]=900027, [900030]=900029, [900037]=900023,
    [900039]=900000, [900041]=900040, [900046]=900044, [900047]=900000,
    [900048]=900044, [900074]=900019, [900075]=900074, [900076]=900075,
  }
  local GUIDE_IDS = {}
  for id = 900000, 900100 do
    if id < 900057 or id > 900059 then GUIDE_IDS[#GUIDE_IDS + 1] = id end
  end
  for id = 901000, 901002 do GUIDE_IDS[#GUIDE_IDS + 1] = id end
  for id = 8269000, 8269019 do GUIDE_IDS[#GUIDE_IDS + 1] = id end

  local GUIDE_DATA_SEGMENT_DELTA = 0x712E000
  local GUIDE_VTABLE_OFFSET = 0x73227B8
  local GUIDE_ELF_SPAN = 0x8000000
  local GUIDE_CODE = {
    {0x36EDA68, 0x52888BE8}, {0x36EDA70, 0x72BFFE48},
    {0x36EDA8C, 0x5283FE69}, {0x36EDA98, 0xA952E675},
    {0x36EDB44, 0x2A1F03E0}, {0x36EDB7C, 0xB9402C19},
    {0x36EDB80, 0x340005B9}, {0x36EDB84, 0xA952DE74},
    {0x36EDC2C, 0x1A9F07E0}, {0x36EDC34, 0x320003E0},
  }

  local function guideTarget(expected)
    local info = gg.getTargetInfo()
    if gg.getTargetPackage() ~= PROFILE.packageName or
       type(info) ~= "table" or info.x64 ~= true or
       tonumber(info.versionCode) ~= PROFILE.versionCode or
       info.versionName ~= PROFILE.versionName or
       not tonumber(info.pid) or tonumber(info.pid) <= 0 then
      error("关闭指引：游戏版本或进程身份不符", 0)
    end
    local abi = info.abi or info.cpuAbi or info.primaryCpuAbi
    if abi ~= nil and abi ~= PROFILE.abi then error("关闭指引：架构不符", 0) end
    local ranges = gg.getRangesList(PROFILE.gameModule)
    if type(ranges) ~= "table" or not ranges[1] or not ranges[2] or
       ranges[2].start ~= requireBase() or
       ranges[2].start - ranges[1].start ~= GUIDE_DATA_SEGMENT_DELTA then
      error("关闭指引：游戏模块映射不符", 0)
    end
    local identity = {pid=tonumber(info.pid), elf=ranges[1].start}
    if expected and (expected.pid ~= identity.pid or expected.elf ~= identity.elf) then
      error("关闭指引：目标进程已经变化", 0)
    end
    return identity
  end

  local function readGuideConfig()
    local result = {target=guideTarget(), guards={}, rows={}, specs={}}
    local function guard(address, flags)
      local value = Memory.read(address, flags)
      result.guards[#result.guards + 1] = {address=address, flags=flags, value=value}
      return tonumber(value)
    end
    local function guardMany(requests)
      local values = Memory.readMany(requests)
      local numbers = {}
      for index, request in ipairs(requests) do
        result.guards[#result.guards + 1] = {
          address=request.address, flags=request.flags,
          value=values[index].value,
        }
        numbers[index] = tonumber(values[index].value)
      end
      return numbers
    end
    local function pointer(address)
      return requireMappedPointer(guard(address, TYPE_QWORD), 8, "指引配置对象")
    end

    local elf = result.target.elf
    local codeRequests = {}
    for index, item in ipairs(GUIDE_CODE) do
      codeRequests[index] = {address=elf + item[1], flags=TYPE_DWORD}
    end
    local codeWords = guardMany(codeRequests)
    for index, item in ipairs(GUIDE_CODE) do
      if (codeWords[index] & 0xFFFFFFFF) ~= item[2] then
        error("关闭指引：原生指引代码不符，请退出旧脚本并重启游戏", 0)
      end
    end
    local manager = pointer(requireBase() + TAG["全局基址头"])
    local dictionary = pointer(manager + OFFSET.guideDictionary)
    local node = pointer(dictionary + OFFSET.guideFirstNode)
    local seen, group = {}, nil
    for count = 1, 2048 do
      if node == 0 or seen[node] then break end
      seen[node] = true
      local values = guardMany({
        {address=node + OFFSET.guideNodeKey, flags=TYPE_QWORD},
        {address=node + OFFSET.guideNodeNext, flags=TYPE_QWORD},
      })
      if values[1] == 20 then group = node; break end
      node = untagPointer(values[2])
    end
    if not group or guard(group + OFFSET.guideNodeKey, TYPE_QWORD) ~= 20 or
       guard(group + OFFSET.guideNodeRowCount, TYPE_DWORD) ~= 8 then
      error("关闭指引：未找到原生 group 20 配置", 0)
    end
    local arrayOwner = pointer(group + OFFSET.guideNodeArray)
    local array = pointer(arrayOwner + OFFSET.guideArray)
    local count = guard(array, TYPE_DWORD)
    local capacity = guard(array + 4, TYPE_DWORD)
    if count ~= #GUIDE_IDS or capacity < count or capacity > 4096 then
      error("关闭指引：指引配置数量或容量不符", 0)
    end
    local slots = pointer(array + OFFSET.guideArraySlots)
    for _, mapOffset in ipairs(OFFSET.guideCacheMaps) do
      local cache = untagPointer(guard(manager + mapOffset, TYPE_QWORD))
      seen = {}
      for depth = 1, 64 do
        if cache == 0 then break end
        if seen[cache] then error("关闭指引：配置缓存树循环", 0) end
        seen[cache] = true
        local key = tonumber(guard(cache + OFFSET.guideCacheKey, TYPE_DWORD))
        if key == 20 then error("关闭指引：出现未验证的原生缓存路径", 0) end
        local child = 20 < key and OFFSET.guideCacheLeft or OFFSET.guideCacheRight
        cache = untagPointer(guard(cache + child, TYPE_QWORD))
        if depth == 64 and cache ~= 0 then error("关闭指引：缓存树过深", 0) end
      end
    end

    local roleManager = pointer(requireBase() + TAG["人物基址头"])
    local person = pointer(roleManager + TAG["人物基址"][2])
    result.secret = guard(
      requireBase() + PROFILE.selfValueOffset, TYPE_DWORD
    ) & 0xFFFFFFFF
    local anchors = {person + FIELD["人物等级"], person + FIELD["人物移速"]}
    local anchorRequests = {}
    for _, address in ipairs(anchors) do
      anchorRequests[#anchorRequests + 1] = {address=address, flags=TYPE_DWORD}
      anchorRequests[#anchorRequests + 1] = {address=address + 4, flags=TYPE_DWORD}
      anchorRequests[#anchorRequests + 1] = {address=address + 8, flags=TYPE_DWORD}
    end
    local anchorValues = Memory.readMany(anchorRequests)
    local keys = {}
    for index, address in ipairs(anchors) do
      local base = (index - 1) * 3
      local shift = tonumber(anchorValues[base + 3].value) & 0xFFFF
      if shift > 32 then error("关闭指引：角色 codec 锚点无效", 0) end
      local plain = rotateLeft32(
        tonumber(anchorValues[base + 2].value) ~ result.secret, shift
      )
      keys[index] = rotateLeft32(tonumber(anchorValues[base + 1].value), 25) ~
        (address & 0xFFFFFFFF) ~ plain
    end
    if keys[1] ~= keys[2] then error("关闭指引：角色 codec 锚点不一致", 0) end
    result.primary = keys[1]

    local slotRequests = {}
    for index = 1, #GUIDE_IDS do
      slotRequests[index] = {address=slots + (index - 1) * 8, flags=TYPE_QWORD}
    end
    local wrapperRequests = {}
    for index, raw in ipairs(guardMany(slotRequests)) do
      local wrapper = requireMappedPointer(raw, 8, "指引配置对象")
      wrapperRequests[index] = {
        address=wrapper + OFFSET.guideRecord, flags=TYPE_QWORD,
      }
    end
    seen = {}
    local addresses, vtableRequests = {}, {}
    for index, raw in ipairs(guardMany(wrapperRequests)) do
      local address = requireMappedPointer(raw, 8, "指引配置对象")
      if seen[address] then error("关闭指引：配置对象重复", 0) end
      seen[address] = true
      if address >= elf and address < elf + GUIDE_ELF_SPAN then
        error("关闭指引：配置记录不是已验证的堆对象", 0)
      end
      addresses[index] = address
      vtableRequests[index] = {address=address, flags=TYPE_QWORD}
    end
    local fieldRequests = {}
    for index, raw in ipairs(guardMany(vtableRequests)) do
      if untagPointer(raw) ~= elf + GUIDE_VTABLE_OFFSET then
        error("关闭指引：配置不是 YJGuideSeqData", 0)
      end
      fieldRequests[#fieldRequests + 1] = {
        address=addresses[index] + OFFSET.guideRecordSteps, flags=TYPE_QWORD,
      }
      fieldRequests[#fieldRequests + 1] = {
        address=addresses[index] + OFFSET.guideRecordStepCount, flags=TYPE_DWORD,
      }
    end
    local fields = guardMany(fieldRequests)
    for index, id in ipairs(GUIDE_IDS) do
      requireMappedPointer(fields[index * 2 - 1], 8, "指引配置对象")
      local steps = fields[index * 2]
      if steps < 1 or steps > 128 then error("关闭指引：步骤数量异常", 0) end
      result.rows[#result.rows + 1] = {address=addresses[index], id=id}
    end
    return result
  end

  local function validateGuideConfig(config, collect)
    guideTarget(config.target)
    local actual = Memory.readMany(config.guards)
    for index, saved in ipairs(config.guards) do
      local value = tonumber(actual[index].value)
      local expected = tonumber(saved.value)
      if saved.flags == TYPE_DWORD then
        value, expected = value & 0xFFFFFFFF, expected & 0xFFFFFFFF
      end
      if value ~= expected then error("关闭指引：配置所有者已经变化", 0) end
    end
    local requests = {}
    for _, row in ipairs(config.rows) do
      local id = OFFSET.guideRecordId
      for _, offset in ipairs({id, id + 4, id + 8, OFFSET.guideRecordPredecessor}) do
        requests[#requests + 1] = {address=row.address + offset, flags=TYPE_DWORD}
      end
    end
    actual = Memory.readMany(requests)
    for index, row in ipairs(config.rows) do
      local n = (index - 1) * 4
      local first, second, shift, predecessor =
        tonumber(actual[n+1].value), tonumber(actual[n+2].value),
        tonumber(actual[n+3].value) & 0xFFFF, tonumber(actual[n+4].value)
      local decoded = rotateLeft32(first, 25) ~
        ((row.address + OFFSET.guideRecordId) & 0xFFFFFFFF) ~ config.primary
      if shift > 32 or decoded ~= row.id or
         rotateLeft32(second ~ config.secret, shift) ~= row.id then
        error("关闭指引：配置 ID 或双副本不符", 0)
      end
      local original = GUIDE_PREDECESSORS[row.id] or 0
      local systemGuide = row.id >= 900000 and row.id <= 900100
      if predecessor ~= original and not (systemGuide and predecessor == row.id) then
        error("关闭指引：前置条件不是原版或本脚本已知值", 0)
      end
      local excluded = row.id == 900001 or row.id == 900002 or
                       (row.id >= 900005 and row.id <= 900013)
      if collect and systemGuide and not excluded and predecessor ~= row.id then
        config.specs[#config.specs + 1] = {
          address=row.address + OFFSET.guideRecordPredecessor,
          flags=TYPE_DWORD, kind="raw", value=row.id,
        }
        config.originals[#config.originals + 1] = predecessor
      end
    end
    return true
  end

  local function disableGuides()
    local config = readGuideConfig()
    config.originals = {}
    validateGuideConfig(config, true)
    if #config.specs == 0 then
      trace("guide metadata already disabled writes=0")
      return 0
    end
    if type(gg.processPause) ~= "function" or type(gg.processResume) ~= "function" then
      error("关闭指引：缺少暂停/恢复接口，未修改", 0)
    end
    if type(gg.isProcessPaused) == "function" and gg.isProcessPaused() then
      error("关闭指引：游戏已暂停，请先恢复运行", 0)
    end
    local paused, pauseResult = pcall(gg.processPause)
    if not paused or pauseResult == false or type(pauseResult) == "string" then
      error("关闭指引：暂停游戏失败，未修改", 0)
    end
    local ok, problem = pcall(function()
      validateGuideConfig(config, false)
      Transaction.write(config.specs, {
        label="关闭指引配置", singleSnapshot=true,
        validateOriginal=function(original)
          for index, expected in ipairs(config.originals) do
            if tonumber(original[index][0]) ~= expected then
              error("关闭指引：提交前前置条件变化", 0)
            end
          end
          return true
        end,
        validateIdentity=function() return validateGuideConfig(config, false) end,
      })
    end)
    local resumed, resumeResult = pcall(gg.processResume)
    if not resumed or resumeResult == false or type(resumeResult) == "string" then
      error("关闭指引：恢复游戏失败，请在修改器中恢复进程运行", 0)
    end
    if not ok then error(problem, 0) end
    trace(string.format("guide metadata disabled group=20 total=121 writes=%d code_writes=0", #config.specs))
    return #config.specs
  end

  function actions.guanbizhiyin()
    local writes = disableGuides()
    local enabled = app.settings.get("auto_guide_off") == "1"
    local message = writes > 0 and
      string.format("关闭成功（修改 %d 条指引前置）", writes) or "指引已是关闭状态"
    local choice = gg.alert(
      message .. "\n\n自动关闭：" .. (enabled and "已开启" or "未开启") ..
      "\n开启后，以后每次启动脚本都会自动关闭指引（游戏重启后需再次运行脚本）。",
      enabled and "保持开启" or "开启自动", enabled and "关闭自动" or "暂不开启"
    )
    if choice == 1 and not enabled then
      app.settings.set("auto_guide_off", "1")
      gg.toast("已开启：以后启动脚本自动关闭指引")
    elseif choice == 2 and enabled then
      app.settings.set("auto_guide_off", "0")
      gg.toast("已关闭自动关闭指引")
    end
    return true
  end

  app.startupHooks[#app.startupHooks + 1] = function()
    if app.settings.get("auto_guide_off") ~= "1" then return end
    local ok, result = pcall(disableGuides)
    if ok then
      gg.toast(result > 0 and "已自动关闭指引" or "指引已是关闭状态")
    else
      trace("auto guide off failed: " .. tostring(result))
      gg.toast("自动关闭指引失败：" .. tostring(result))
    end
  end

  local function requireItems()
    if type(Items) ~= "table" or
       type(Items.findItemsByGroupName) ~= "function" or
       type(Items.readItemsFromKnownGroup) ~= "function" then
      error("地图无怪依赖全局物品模块", 0)
    end
    return Items
  end

  local function readMapRecordValues(snapshot, trailingRequests, monsterMustMatch)
    local requests = {
      {address=snapshot.group.countAddress, flags=TYPE_DWORD},
      {address=snapshot.group.countAddress + Items.offset.groupArray, flags=TYPE_QWORD},
    }
    for _, record in ipairs(snapshot.records) do
      requests[#requests + 1] = {
        address=record.slotAddress, flags=TYPE_QWORD,
      }
      requests[#requests + 1] = {
        address=record.objectFieldAddress, flags=TYPE_QWORD,
      }
      requests[#requests + 1] = {
        address=record.address + OFFSET.mapMonsters, flags=TYPE_QWORD,
      }
    end
    for _, request in ipairs(trailingRequests or {}) do
      requests[#requests + 1] = request
    end
    local values = Memory.readMany(requests)
    if values[1].value ~= snapshot.group.count then
      error("九重天地图数量已经变化", 0)
    end
    if untagPointer(values[2].value) ~= snapshot.groupArrayAddress then
      error("九重天地图数组已经变化", 0)
    end
    local cursor, monsters = 3, {}
    for index, record in ipairs(snapshot.records) do
      if untagPointer(values[cursor].value) ~= record.slotObjectAddress then
        error(record.name .. "地图槽位已经变化", 0)
      end
      if untagPointer(values[cursor + 1].value) ~= record.address then
        error(record.name .. "地图对象已经变化", 0)
      end
      if monsterMustMatch and values[cursor + 2].value ~= record.monsterRaw then
        error(record.name .. "怪物对象已经变化", 0)
      end
      monsters[index] = values[cursor + 2].value
      cursor = cursor + 3
    end
    return values, cursor, monsters
  end

  local function readCachedNineHeavens(cache)
    if type(cache) ~= "table" or type(cache.group) ~= "table" or
       type(cache.records) ~= "table" or #cache.records == 0 then
      error("九重天缓存无效", 0)
    end
    local _, _, monsters = readMapRecordValues(cache, nil, false)
    local records = {}
    for index, cached in ipairs(cache.records) do
      records[index] = {
        address=cached.address,
        name=cached.name,
        monsterRaw=monsters[index],
        slotAddress=cached.slotAddress,
        slotObjectAddress=cached.slotObjectAddress,
        objectFieldAddress=cached.objectFieldAddress,
      }
    end
    return records, cache.group
  end

  local function readNineHeavens()
    if state.nineHeavens then
      local ok, records, group = pcall(
        readCachedNineHeavens, state.nineHeavens
      )
      if ok then
        trace("map nine_heavens cache=hit items=" .. #records)
        return records, group
      end
      trace("map nine_heavens cache=invalid reason=" .. tostring(records))
      state.nineHeavens = nil
    end

    local lookupStart = os.clock()
    local items, reason = requireItems().findItemsByGroupName("九重天")
    if not items then error("九重天数据不可用：" .. tostring(reason), 0) end
    if #items == 0 or #items > 10000 then
      error("九重天地图数量异常", 0)
    end
    trace(string.format("map nine_heavens phase=group_lookup seconds=%.3f",
      os.clock() - lookupStart))

    local recordsStart = os.clock()
    local records, nameSeen, nameRequests, monsterRequests = {}, {}, {}, {}
    local group
    for index, item in ipairs(items) do
      if type(item) ~= "table" or type(item.address) ~= "number" then
        error("九重天地图记录无效", 0)
      end
      if type(item.group) ~= "table" or
         type(item.group.countAddress) ~= "number" then
        error("九重天物品组身份缺失", 0)
      end
      group = group or item.group
      if item.group.countAddress ~= group.countAddress then
        error("九重天地图记录来自不同物品组", 0)
      end
      if not Memory.isMapped(item.address, OFFSET.mapObjectSize) then
        error("九重天地图对象范围无效", 0)
      end
      if type(item.groupArrayAddress) ~= "number" or
         type(item.slotAddress) ~= "number" or
         type(item.slotObjectAddress) ~= "number" or
         type(item.objectFieldAddress) ~= "number" then
        error("九重天地图对象身份缺失", 0)
      end
      records[index] = {
        address=item.address,
        slotAddress=item.slotAddress,
        slotObjectAddress=item.slotObjectAddress,
        objectFieldAddress=item.objectFieldAddress,
      }
      nameRequests[index] = {
        address=item.address + OFFSET.mapName,
        flags=TYPE_QWORD,
      }
      monsterRequests[index] = {
        address=item.address + OFFSET.mapMonsters,
        flags=TYPE_QWORD,
      }
    end
    local names = Memory.readStrings(nameRequests, 32)
    local missingIndexes, retryRequests = {}, {}
    for index = 1, #records do
      local name = names[index]
      if type(name) ~= "string" or name == "" then
        missingIndexes[#missingIndexes + 1] = index
        retryRequests[#retryRequests + 1] = nameRequests[index]
      end
    end

    local recoveredNames = 0
    if #retryRequests > 0 then
      pcall(gg.sleep, 150)
      pcall(Memory.refreshRanges)
      local retriedNames = Memory.readStrings(retryRequests, 32)
      for retryIndex, recordIndex in ipairs(missingIndexes) do
        local name = retriedNames[retryIndex]
        if type(name) == "string" and name ~= "" then
          names[recordIndex] = name
          recoveredNames = recoveredNames + 1
        end
      end
    end
    local monsterValues = Memory.readMany(monsterRequests)
    if #monsterValues ~= #records then
      error("九重天怪物对象读取不完整", 0)
    end
    local loadedRecords, skippedNames = {}, 0
    for index, record in ipairs(records) do
      record.monsterRaw = monsterValues[index].value
      local name = names[index]
      if type(name) == "string" and name ~= "" then
        record.name = name
        loadedRecords[#loadedRecords + 1] = record
        nameSeen[name] = (nameSeen[name] or 0) + 1
      else
        skippedNames = skippedNames + 1
      end
    end
    records = loadedRecords
    trace(string.format(
      "map nine_heavens names loaded=%d skipped=%d retried=%d recovered=%d",
      #records, skippedNames, #missingIndexes, recoveredNames
    ))
    if nameSeen["决战黄泉路"] ~= 1 then
      error("无法唯一定位无怪模板“决战黄泉路”", 0)
    end
    if nameSeen["幽冥冰窟"] ~= 1 then
      error("无法唯一定位特殊地图“幽冥冰窟”", 0)
    end
    local cachedRecords = {}
    for index, record in ipairs(records) do
      cachedRecords[index] = {
        address=record.address,
        name=record.name,
        slotAddress=record.slotAddress,
        slotObjectAddress=record.slotObjectAddress,
        objectFieldAddress=record.objectFieldAddress,
      }
    end
    state.nineHeavens = {
      group=group,
      groupArrayAddress=items[1].groupArrayAddress,
      records=cachedRecords,
    }
    trace(string.format("map nine_heavens phase=records seconds=%.3f",
      os.clock() - recordsStart))
    return records, group
  end

  local function validateMapRecords(snapshot, trailingRequests)
    local values, cursor = readMapRecordValues(snapshot, trailingRequests, true)
    return values, cursor
  end

  local function collectNoMonsterMutations(records)
    local sourceObject, underworldObject
    local redirectObjects = {}
    local skippedEmpty = {}
    for _, record in ipairs(records) do
      local monsterObject = untagPointer(record.monsterRaw)
      if monsterObject == 0 then
        if record.name == "决战黄泉路" or record.name == "幽冥冰窟" then
          error(record.name .. "关键怪物对象为空", 0)
        end
        skippedEmpty[#skippedEmpty + 1] = record.name
      else
        monsterObject = requireMappedPointer(
          monsterObject, 8, record.name .. "怪物对象"
        )
        if record.name == "幽冥冰窟" then
          underworldObject = monsterObject
        else
          redirectObjects[#redirectObjects + 1] = monsterObject
          if record.name == "决战黄泉路" then sourceObject = monsterObject end
        end
      end
    end
    if #skippedEmpty > 0 then
      trace("map skipped empty monster objects=" .. #skippedEmpty ..
            " names=" .. table.concat(skippedEmpty, ","))
    end
    if not sourceObject then error("无怪模板“决战黄泉路”不可用", 0) end
    if not underworldObject then error("特殊地图“幽冥冰窟”不可用", 0) end

    local sourceValue = Memory.read(sourceObject, TYPE_QWORD)
    local sourceRoot = requireMappedPointer(sourceValue, 84, "无怪模板根对象")
    local identity = {
      sourceObject=sourceObject,
      sourceValue=sourceValue,
      sourceRoot=sourceRoot,
      underworldObject=underworldObject,
      underworldEntries={},
    }
    local mutations, seen = {}, {}
    local function add(address, flags, value, label)
      local size = flags == TYPE_QWORD and 8 or 4
      if not Memory.isMapped(address, size) then error(label .. "地址无效", 0) end
      local key = string.format("%X:%d", address, flags)
      if seen[key] then
        if seen[key].applied ~= value then error(label .. "写入冲突", 0) end
        return
      end
      local entry = {
        address=address,
        flags=flags,
        original=nil,
        applied=value,
        label=label,
      }
      seen[key] = entry
      mutations[#mutations + 1] = entry
    end

    for index, address in ipairs(redirectObjects) do
      add(address, TYPE_QWORD, sourceValue, "地图怪物重定向 " .. index)
    end
    add(sourceRoot + OFFSET.monsterParam, TYPE_DWORD, 1152224051,
        "黄泉路怪物参数")
    local sourceSwitch = requireMappedPointer(
      Memory.read(sourceRoot + OFFSET.monsterSwitch, TYPE_QWORD), 4,
      "黄泉路怪物开关"
    )
    identity.sourceSwitch = sourceSwitch
    add(sourceSwitch, TYPE_DWORD, 0, "黄泉路怪物开关")

    if not Memory.isMapped(underworldObject, UNDERWORLD_SLOTS * 8) then
      error("幽冥冰窟怪物数组无效", 0)
    end
    local underworldSlots = {}
    for index = 0, UNDERWORLD_SLOTS - 1 do
      underworldSlots[index + 1] = {
        address=underworldObject + index * 8,
        flags=TYPE_QWORD,
      }
    end
    local slotValues = Memory.readMany(underworldSlots)
    local skippedObjects, skippedSwitches = 0, 0
    for index, slot in ipairs(slotValues) do
      local object = untagPointer(slot.value)
      if object == 0 then
        skippedObjects = skippedObjects + 1
      else
        object = requireMappedPointer(
          object, 88, "幽冥冰窟怪物槽 " .. index
        )
        local switchRaw = Memory.read(object + OFFSET.monsterSwitch, TYPE_QWORD)
        local switchAddress = untagPointer(switchRaw)
        if switchAddress == 0 then
          skippedSwitches = skippedSwitches + 1
        else
          switchAddress = requireMappedPointer(
            switchAddress, 4, "幽冥冰窟怪物开关 " .. index
          )
          identity.underworldEntries[#identity.underworldEntries + 1] = {
            slotIndex=index,
            object=object,
            switchAddress=switchAddress,
          }
          add(switchAddress, TYPE_DWORD, 0,
              "幽冥冰窟怪物开关 " .. index)
        end
      end
    end
    if skippedObjects > 0 or skippedSwitches > 0 then
      trace(string.format(
        "map skipped empty underworld objects=%d switches=%d",
        skippedObjects, skippedSwitches
      ))
    end
    local originalRequests = {}
    for index, mutation in ipairs(mutations) do
      originalRequests[index] = {
        address=mutation.address,
        flags=mutation.flags,
      }
    end
    local originals = Memory.readMany(originalRequests)
    for index, mutation in ipairs(mutations) do
      mutation.original = originals[index].value
    end
    return mutations, identity
  end

  local function validateNoMonsterIdentity(snapshot)
    local identity = snapshot.identity
    local requests = {
      {address=identity.sourceObject, flags=TYPE_QWORD},
      {address=identity.sourceRoot + OFFSET.monsterSwitch, flags=TYPE_QWORD},
    }
    for _, entry in ipairs(identity.underworldEntries) do
      requests[#requests + 1] = {
        address=identity.underworldObject + (entry.slotIndex - 1) * 8,
        flags=TYPE_QWORD,
      }
      requests[#requests + 1] = {
        address=entry.object + OFFSET.monsterSwitch,
        flags=TYPE_QWORD,
      }
    end
    local values, cursor = validateMapRecords(snapshot, requests)
    if requireMappedPointer(values[cursor].value, 84, "无怪模板根对象") ~=
       identity.sourceRoot then
      error("无怪模板根对象已经变化", 0)
    end
    if requireMappedPointer(values[cursor + 1].value, 4, "黄泉路怪物开关") ~=
       identity.sourceSwitch then
      error("黄泉路怪物开关对象已经变化", 0)
    end
    cursor = cursor + 2
    for _, entry in ipairs(identity.underworldEntries) do
      local index = entry.slotIndex
      if requireMappedPointer(
          values[cursor].value,
          88, "幽冥冰窟怪物槽 " .. index
        ) ~= entry.object then
        error("幽冥冰窟怪物槽已经变化", 0)
      end
      if requireMappedPointer(
          values[cursor + 1].value, 4,
          "幽冥冰窟怪物开关 " .. index
        ) ~= entry.switchAddress then
        error("幽冥冰窟怪物开关对象已经变化", 0)
      end
      cursor = cursor + 2
    end
    return true
  end

  local function mutationSpecs(mutations, field)
    local specs = {}
    for index, mutation in ipairs(mutations) do
      specs[index] = {
        kind="raw", address=mutation.address, flags=mutation.flags,
        value=mutation[field], label=mutation.label,
      }
    end
    return specs
  end

  function actions.dituwuguai()
    if state.noMonster then
      gg.alert("地图无怪已经开启，请先执行“无怪恢复”")
      return false
    end
    local actionStart = os.clock()
    local phaseStart = actionStart
    local records, group = readNineHeavens()
    trace(string.format("map no_monster phase=read seconds=%.3f",
      os.clock() - phaseStart))
    phaseStart = os.clock()
    local mutations, identity = collectNoMonsterMutations(records)
    trace(string.format("map no_monster phase=plan seconds=%.3f fields=%d",
      os.clock() - phaseStart, #mutations))
    local snapshot = {
      records=records,
      group=group,
      groupArrayAddress=state.nineHeavens.groupArrayAddress,
      mutations=mutations,
      identity=identity,
    }
    phaseStart = os.clock()
    local ok, problem = pcall(Transaction.write,
      mutationSpecs(mutations, "applied"), {
        label="地图无怪",
        singleSnapshot=true,
        validateOriginal=function(live)
          for index, mutation in ipairs(mutations) do
            if not sameValue(
                live[index][0], mutation.original, mutation.flags
              ) then
              error("地图无怪写入前字段已经变化（第 " .. index .. " 项）", 0)
            end
          end
          return true
        end,
        validateIdentity=function() return validateNoMonsterIdentity(snapshot) end,
      }
    )
    if not ok then
      if tostring(problem):find("未强制回滚", 1, true) then
        state.noMonster = snapshot
      end
      error(tostring(problem), 0)
    end
    state.noMonster = snapshot
    trace(string.format(
      "map no_monster phase=transaction seconds=%.3f total=%.3f",
      os.clock() - phaseStart, os.clock() - actionStart
    ))
    gg.toast("修改完成；无怪恢复仅限本次脚本运行期间")
    return true
  end

  function actions.dituhuifu()
    local actionStart = os.clock()
    local snapshot = state.noMonster
    if not snapshot then
      gg.alert("当前没有可恢复的地图无怪快照")
      return false
    end
    Transaction.write(mutationSpecs(snapshot.mutations, "original"), {
      label="无怪恢复",
      singleSnapshot=true,
      validateOriginal=function(live)
        for index, mutation in ipairs(snapshot.mutations) do
          local stillApplied = sameValue(
            live[index][0], mutation.applied, mutation.flags
          )
          local alreadyOriginal = sameValue(
            live[index][0], mutation.original, mutation.flags
          )
          if not stillApplied and not alreadyOriginal then
            error(string.format(
              "无怪字段已被游戏改写（第 %d 项），为避免覆盖新状态已拒绝恢复",
              index
            ), 0)
          end
        end
        return true
      end,
      validateIdentity=function() return validateNoMonsterIdentity(snapshot) end,
    })
    state.noMonster = nil
    trace(string.format("map no_monster restore total=%.3f fields=%d",
      os.clock() - actionStart, #snapshot.mutations))
    gg.toast("修改完成")
    return true
  end

  return {
    actions=actions,
    readNineHeavens=readNineHeavens,
    getNoMonsterState=function() return state.noMonster end,
  }
end)

installModule("inventory", function(app)
  local Memory = app.Memory
  local Codec = app.Codec
  local TAG = app.TAG
  local FIELD = app.FIELD
  local runtime = app.runtime
  local requireInteger = app.requireInteger
  local untagPointer = app.untagPointer
  local codecAddress = app.codecAddress
  local rotateLeft32 = app.rotateLeft32
  local copyArray = app.copyArray
  local trim = app.trim
  local trace = app.trace
  local actionError = app.actionError

  local TYPE_DWORD = gg.TYPE_DWORD
  local TYPE_QWORD = gg.TYPE_QWORD
  local U32_MASK = app.U32_MASK
  local POINTER_MASK = app.POINTER_MASK

  local OFFSET = {
    treeLeft = 0x00,
    treeRight = 0x08,
    treeFirstObject = 0x20,
    treeSecondObject = 0x28,
    inventoryTarget = 0x10,
    inventoryMetadata = 0x18,
    catalogId = 0x08,
    catalogName = 0x30,
    catalogSecondName = 0x38,
    searchName = 0xF8,

    bagBoardVtable = 0x7ACB0,
    itemInfoVtable = 0x538D0,
    itemInfoItem = 0x2C0,
    nodeChildren = 0x100,
    arrayData = 0x18,
    arrayItems = 0x10,
  }

  local LIMIT = {
    treeNodes = 100000,
    sceneChildren = 1024,
    selectedItems = 4096,
    pointerHighDistance = 4,
  }

  local state = {
    pointerContext = nil,
    lastSelection = {},
    lastKeyword = "",
  }

  local function pointerValue(value, label, allowZero)
    local number = tonumber(value)
    if not number or number ~= number or number == math.huge or
       number == -math.huge or number ~= math.floor(number) then
      error((label or "指针") .. "不是有效整数", 0)
    end
    local address = untagPointer(number) & POINTER_MASK
    if address == 0 and not allowZero then
      error((label or "指针") .. "为空", 0)
    end
    return address
  end

  local function requireRange(address, size, label)
    address = pointerValue(address, label, false)
    size = requireInteger(size, 1, 0x7FFFFFFF, (label or "对象") .. "长度")
    local lastAddress = address + size - 1
    if lastAddress < address or not Memory.isMapped(address, size) then
      error(string.format("%s范围无效: 0x%X + 0x%X",
        label or "对象", address, size), 0)
    end
    return address
  end

  local function copyPointerContext(context)
    if not context then return nil end
    return {
      personAddress=context.personAddress,
      ownerName=context.ownerName,
      pointerCodecTagPrefix=context.pointerCodecTagPrefix,
      sameOwnerHighCandidates=copyArray(context.sameOwnerHighCandidates),
      inventoryHighCandidates=copyArray(context.inventoryHighCandidates),
    }
  end

  local function appendUnique(output, seen, value)
    value = requireInteger(value, 1, 0x00FFFFFF, "指针高位")
    if not seen[value] then
      seen[value] = true
      output[#output + 1] = value
    end
  end

  local function refreshPointerContext()
    if type(runtime.gameBase) ~= "number" then
      error("inventory: libgame.so 基址尚未初始化", 0)
    end

    local ranges = Memory.refreshRanges()
    if type(ranges) ~= "table" or #ranges == 0 then
      error("未获取到进程内存映射", 0)
    end
    local personAddress = Memory.resolve(
      runtime.gameBase, TAG["人物基址"], 1
    )
    local ownerName
    for _, range in ipairs(ranges) do
      if type(range.start) == "number" and type(range["end"]) == "number" and
         personAddress >= range.start and personAddress <= range["end"] then
        ownerName = range.name
        break
      end
    end
    if ownerName == nil then error("人物对象不属于有效内存映射", 0) end

    local rawA0High = Memory.read(
      runtime.gameBase + TAG["A0基址"] + 4, TYPE_DWORD
    )
    local tagPrefix = rawA0High & 0xFF000000
    local sameOwner, sameSeen = {}, {}
    local expanded, expandedSeen = {}, {}
    local personHigh = personAddress >> 32

    for _, range in ipairs(ranges) do
      local rangeStart = tonumber(range.start)
      if rangeStart and rangeStart >= 0x100000000 then
        local high = rangeStart >> 32
        if range.name == ownerName then
          appendUnique(sameOwner, sameSeen, high)
          appendUnique(expanded, expandedSeen, high)
        end
      end
    end
    if #sameOwner == 0 then error("未找到人物对象对应的指针高位", 0) end

    if tagPrefix ~= 0 then
      for _, range in ipairs(ranges) do
        local rangeStart = tonumber(range.start)
        if rangeStart and rangeStart >= 0x100000000 then
          local high = rangeStart >> 32
          if high >= personHigh - LIMIT.pointerHighDistance and
             high <= personHigh + LIMIT.pointerHighDistance then
            appendUnique(expanded, expandedSeen, high)
          end
        end
      end
    end
    table.sort(sameOwner)
    table.sort(expanded)

    local context = {
      personAddress=personAddress,
      ownerName=ownerName,
      pointerCodecTagPrefix=tagPrefix,
      sameOwnerHighCandidates=sameOwner,
      inventoryHighCandidates=expanded,
    }
    runtime.pointerCodecTagPrefix = tagPrefix
    runtime.inventoryHighCandidates = copyArray(expanded)
    state.pointerContext = copyPointerContext(context)
    trace(string.format(
      "inventory pointer context person=0x%X tag=0x%X highs=%d",
      personAddress, tagPrefix, #expanded
    ))
    return copyPointerContext(context)
  end

  local function currentHighCandidates()
    local context = refreshPointerContext()
    if #context.inventoryHighCandidates == 0 then
      error("背包指针高位候选为空", 0)
    end
    return context.inventoryHighCandidates
  end

  local function readTreeSnapshot(root)
    root = requireRange(root, OFFSET.treeRight + 8, "背包树根")
    local links, frontier, discovered = {}, {root}, 0
    while #frontier > 0 do
      local batch, requests, queued = {}, {}, {}
      for _, node in ipairs(frontier) do
        if not links[node] and not queued[node] then
          requireRange(node, OFFSET.treeSecondObject + 8, "背包树节点")
          discovered = discovered + 1
          if discovered > LIMIT.treeNodes then error("背包节点数量异常", 0) end
          queued[node] = true
          batch[#batch + 1] = node
          requests[#requests + 1] = {
            address=node + OFFSET.treeLeft, flags=TYPE_QWORD,
          }
          requests[#requests + 1] = {
            address=node + OFFSET.treeRight, flags=TYPE_QWORD,
          }
        end
      end
      local values = #requests > 0 and Memory.readMany(requests) or {}
      local nextFrontier = {}
      for index, node in ipairs(batch) do
        local leftRaw = values[index * 2 - 1].value
        local rightRaw = values[index * 2].value
        local link = {
          leftPresent=(leftRaw & U32_MASK) ~= 0,
          rightPresent=(rightRaw & U32_MASK) ~= 0,
          left=pointerValue(leftRaw, "背包左节点", true),
          right=pointerValue(rightRaw, "背包右节点", true),
        }
        if link.leftPresent and link.left == 0 then error("背包左节点为空", 0) end
        if link.rightPresent and link.right == 0 then error("背包右节点为空", 0) end
        links[node] = link
        if link.leftPresent then nextFrontier[#nextFrontier + 1] = link.left end
        if link.rightPresent then nextFrontier[#nextFrontier + 1] = link.right end
      end
      frontier = nextFrontier
    end

    local nodes, seen, stack = {}, {}, {root}
    while #stack > 0 do
      local node = stack[#stack]
      stack[#stack] = nil
      if node ~= 0 and not seen[node] then
        seen[node] = true
        local link = links[node]
        nodes[#nodes + 1] = {
          address=node,
          left=link.left,
          right=link.right,
          leftPresent=link.leftPresent,
          rightPresent=link.rightPresent,
        }
        if link.rightPresent then stack[#stack + 1] = link.right end
        if link.leftPresent then stack[#stack + 1] = link.left end
      end
    end
    if #nodes == 0 then error("动态背包尚未加载", 0) end
    return nodes
  end

  local function validateTreeTopology(nodes)
    local requests = {}
    for _, node in ipairs(nodes) do
      requests[#requests + 1] = {
        address=node.address + OFFSET.treeLeft, flags=TYPE_QWORD,
      }
      requests[#requests + 1] = {
        address=node.address + OFFSET.treeRight, flags=TYPE_QWORD,
      }
    end
    local values = Memory.readMany(requests)
    for index, node in ipairs(nodes) do
      local leftRaw = values[(index - 1) * 2 + 1].value
      local rightRaw = values[(index - 1) * 2 + 2].value
      if ((leftRaw & U32_MASK) ~= 0) ~= node.leftPresent or
         ((rightRaw & U32_MASK) ~= 0) ~= node.rightPresent or
         pointerValue(leftRaw, "背包左节点", true) ~= node.left or
         pointerValue(rightRaw, "背包右节点", true) ~= node.right then
        error("读取期间背包树结构发生变化，请重试", 0)
      end
    end
    return true
  end

  local function readNodeObjects(nodes)
    local requests = {}
    for _, node in ipairs(nodes) do
      requests[#requests + 1] = {
        address=node.address + OFFSET.treeFirstObject, flags=TYPE_QWORD,
      }
      requests[#requests + 1] = {
        address=node.address + OFFSET.treeSecondObject, flags=TYPE_QWORD,
      }
    end
    local values = Memory.readMany(requests)
    local objects = {}
    for index, node in ipairs(nodes) do
      local first = pointerValue(
        values[(index - 1) * 2 + 1].value, "背包主对象", false
      )
      local second = pointerValue(
        values[(index - 1) * 2 + 2].value, "背包叠加对象", false
      )
      requireRange(first,
        math.max(FIELD["装备壳子"] + 20, OFFSET.inventoryTarget + 28),
        "背包主对象")
      requireRange(second, OFFSET.inventoryMetadata + 12, "背包叠加对象")
      objects[index] = {node=node.address, first=first, second=second}
    end
    return objects
  end

  local function locateCatalog(encodedLow, highCandidates, label)
    local matches, seen = {}, {}
    for _, high in ipairs(highCandidates) do
      local address = codecAddress(encodedLow, high, 0)
      if not seen[address] and
         Memory.isMapped(address, OFFSET.catalogSecondName + 8) then
        seen[address] = true
        local ok, itemId, name, secondName = pcall(function()
          local decodedId = Codec.decode(address + OFFSET.catalogId)
          if decodedId <= 1200 then return nil end
          local decodedName = Memory.readString(address + OFFSET.catalogName, 96)
          if decodedName == "" then return nil end
          return decodedId, decodedName,
            Memory.readString(address + OFFSET.catalogSecondName, 96)
        end)
        if ok and itemId then
          matches[#matches + 1] = {
            address=address,
            high=high,
            id=itemId,
            name=name,
            secondName=secondName,
          }
        end
      end
    end
    if #matches == 1 then return matches[1] end
    if #matches > 1 then
      error((label or "背包物品") .. "压缩指针命中不唯一，请重试", 0)
    end
    error((label or "背包物品") .. "无法解码，请等待背包稳定后重试", 0)
  end

  local function validateInventorySnapshot(snapshot)
    if type(snapshot) ~= "table" or type(snapshot.entries) ~= "table" or
       type(snapshot.nodes) ~= "table" then
      error("背包快照无效", 0)
    end
    local currentRootSlot = Memory.resolve(
      runtime.gameBase, TAG["动态背包"], 8
    )
    if currentRootSlot ~= snapshot.rootSlot or
       pointerValue(Memory.read(currentRootSlot, TYPE_QWORD),
         "动态背包根", false) ~= snapshot.root then
      error("动态背包根对象已经变化，请重试", 0)
    end
    validateTreeTopology(snapshot.nodes)
    local objects = readNodeObjects(snapshot.nodes)
    if #objects ~= #snapshot.entries then error("背包快照数量不一致", 0) end

    for index, entry in ipairs(snapshot.entries) do
      local object = objects[index]
      if object.node ~= entry.node or object.first ~= entry.firstObject or
         object.second ~= entry.secondObject then
        error("背包槽位身份已经变化，请重试", 0)
      end
      local encoded = Codec.decode5(
        object.first + FIELD["装备壳子"]
      )
      if encoded ~= entry.encodedLow or
         codecAddress(encoded, entry.catalogHigh, 0) ~= entry.catalogAddress or
         Codec.decode(entry.catalogAddress + OFFSET.catalogId) ~= entry.id or
         Memory.readString(entry.catalogAddress + OFFSET.catalogName, 96) ~=
           entry.name or
         Memory.readString(
           entry.catalogAddress + OFFSET.catalogSecondName, 96
         ) ~= entry.secondName then
        error("背包物品身份已经变化，请重试", 0)
      end
    end
    return true
  end

  local function readInventorySnapshot()
    local highCandidates = currentHighCandidates()
    local rootSlot = Memory.resolve(runtime.gameBase, TAG["动态背包"], 8)
    local root = pointerValue(
      Memory.read(rootSlot, TYPE_QWORD), "动态背包根", false
    )
    local nodes = readTreeSnapshot(root)
    validateTreeTopology(nodes)
    if pointerValue(Memory.read(rootSlot, TYPE_QWORD),
        "动态背包根", false) ~= root then
      error("读取期间动态背包根对象发生变化，请重试", 0)
    end

    local objects = readNodeObjects(nodes)
    local shellRequests = {}
    for index, object in ipairs(objects) do
      shellRequests[index] = {
        address=object.first + FIELD["装备壳子"], flags=TYPE_DWORD,
      }
    end
    local encodedValues = Codec.decode5Many(shellRequests)
    local entries = {}
    for index, object in ipairs(objects) do
      local catalog = locateCatalog(
        encodedValues[index], highCandidates, "第 " .. index .. " 个背包物品"
      )
      entries[index] = {
        index=index,
        node=object.node,
        firstObject=object.first,
        secondObject=object.second,
        targetBaseAddress=object.first + OFFSET.inventoryTarget,
        targetCountAddress=object.first + OFFSET.inventoryTarget + 0x10,
        metadataAddress=object.second + OFFSET.inventoryMetadata,
        encodedLow=encodedValues[index],
        catalogAddress=catalog.address,
        catalogHigh=catalog.high,
        id=catalog.id,
        name=catalog.name,
        secondName=catalog.secondName,
      }
    end
    local snapshot = {
      rootSlot=rootSlot,
      root=root,
      nodes=nodes,
      entries=entries,
    }
    validateInventorySnapshot(snapshot)
    trace(string.format("inventory snapshot complete entries=%d", #entries))
    return snapshot
  end

  local function readSelectedInventorySnapshot(selection)
    if type(selection) ~= "table" or #selection == 0 then
      error("定点背包快照缺少选择项", 0)
    end

    local highCandidates
    local context = state.pointerContext
    if type(context) == "table" and
       type(context.inventoryHighCandidates) == "table" and
       #context.inventoryHighCandidates > 0 then
      highCandidates = copyArray(context.inventoryHighCandidates)
    else
      highCandidates = currentHighCandidates()
    end

    local wanted, wantedCount = {}, 0
    for index, selected in ipairs(selection) do
      local address = requireRange(
        selected.address, OFFSET.searchName + 8,
        "第 " .. index .. " 个已选物品"
      )
      if wanted[address] then error("选择结果含有重复物品", 0) end
      wanted[address] = {index=index, selected=selected}
      wantedCount = wantedCount + 1
    end

    local rootSlot = Memory.resolve(runtime.gameBase, TAG["动态背包"], 8)
    local root = pointerValue(
      Memory.read(rootSlot, TYPE_QWORD), "动态背包根", false
    )
    local nodes = readTreeSnapshot(root)
    validateTreeTopology(nodes)

    local objectRequests = {}
    for _, node in ipairs(nodes) do
      objectRequests[#objectRequests + 1] = {
        address=node.address + OFFSET.treeFirstObject, flags=TYPE_QWORD,
      }
      objectRequests[#objectRequests + 1] = {
        address=node.address + OFFSET.treeSecondObject, flags=TYPE_QWORD,
      }
    end
    local objectValues = Memory.readMany(objectRequests)
    local matched = {}
    for index, node in ipairs(nodes) do
      local first = pointerValue(
        objectValues[(index - 1) * 2 + 1].value,
        "背包主对象", false
      )
      local target = first + OFFSET.inventoryTarget
      local requested = wanted[target]
      if requested then
        if matched[requested.index] then
          error("已选物品在背包树中命中不唯一", 0)
        end
        local second = pointerValue(
          objectValues[(index - 1) * 2 + 2].value,
          "背包叠加对象", false
        )
        requireRange(first,
          math.max(FIELD["装备壳子"] + 20, OFFSET.inventoryTarget + 28),
          "已选背包主对象")
        requireRange(second, OFFSET.inventoryMetadata + 12,
          "已选背包叠加对象")
        matched[requested.index] = {
          node=node.address,
          first=first,
          second=second,
          selected=requested.selected,
        }
      end
    end
    for index = 1, wantedCount do
      if not matched[index] then
        error("第 " .. index .. " 个已选物品已不在动态背包中", 0)
      end
    end

    local shellRequests = {}
    for index, item in ipairs(matched) do
      shellRequests[index] = {
        address=item.first + FIELD["装备壳子"], flags=TYPE_DWORD,
      }
    end
    local encodedValues = Codec.decode5Many(shellRequests)
    local entries = {}
    for index, item in ipairs(matched) do
      local encoded = encodedValues[index]
      local catalog = locateCatalog(
        encoded, highCandidates, "第 " .. index .. " 个已选物品"
      )
      entries[index] = {
        index=index,
        node=item.node,
        firstObject=item.first,
        secondObject=item.second,
        targetBaseAddress=item.first + OFFSET.inventoryTarget,
        targetCountAddress=item.first + OFFSET.inventoryTarget + 0x10,
        metadataAddress=item.second + OFFSET.inventoryMetadata,
        encodedLow=encoded,
        catalogAddress=catalog.address,
        catalogHigh=catalog.high,
        id=catalog.id,
        name=catalog.name,
        secondName=catalog.secondName,
      }
    end

    if pointerValue(Memory.read(rootSlot, TYPE_QWORD),
        "动态背包根", false) ~= root then
      error("读取期间动态背包根对象发生变化，请重试", 0)
    end
    local identityRequests = {}
    for _, entry in ipairs(entries) do
      identityRequests[#identityRequests + 1] = {
        address=entry.node + OFFSET.treeFirstObject, flags=TYPE_QWORD,
      }
      identityRequests[#identityRequests + 1] = {
        address=entry.node + OFFSET.treeSecondObject, flags=TYPE_QWORD,
      }
    end
    local identities = Memory.readMany(identityRequests)
    local idRequests = {}
    for index, entry in ipairs(entries) do
      if pointerValue(identities[(index - 1) * 2 + 1].value,
          "背包主对象", false) ~= entry.firstObject or
         pointerValue(identities[(index - 1) * 2 + 2].value,
          "背包叠加对象", false) ~= entry.secondObject then
        error("已选物品槽位在读取期间发生变化，请重试", 0)
      end
      idRequests[index] = {
        address=entry.catalogAddress + OFFSET.catalogId,
      }
    end
    local checkedShells = Codec.decode5Many(shellRequests)
    local checkedIds = Codec.decodeMany(idRequests)
    for index, entry in ipairs(entries) do
      if (checkedShells[index] & U32_MASK) ~= (entry.encodedLow & U32_MASK) or
         (checkedIds[index] & U32_MASK) ~= (entry.id & U32_MASK) then
        error("已选物品身份在读取期间发生变化，请重试", 0)
      end
    end

    local snapshot = {
      rootSlot=rootSlot,
      root=root,
      nodes=nodes,
      entries=entries,
      selectedOnly=true,
    }
    trace(string.format(
      "inventory selected snapshot complete selected=%d tree_nodes=%d",
      #entries, #nodes
    ))
    return snapshot
  end

  local function copySelection(entries)
    local result = {}
    for index, entry in ipairs(entries or {}) do
      result[index] = {
        address=entry.address,
        name=entry.name,
        value=entry.value,
        marker=entry.marker,
        high=entry.high,
        encodedLow=entry.encodedLow,
        flags=TYPE_DWORD,
      }
    end
    return result
  end

  local function selectItemsFromList()
    state.lastSelection = {}
    pcall(gg.clearResults)
    local snapshot = readInventorySnapshot()
    if #snapshot.entries == 0 then
      gg.toast("背包为空")
      return {}, {reason="completed"}
    end
    local shown
    while true do
      local input = gg.prompt(
        {"物品名称关键字（多个用空格分隔，留空显示全部）"},
        {state.lastKeyword or ""}, {"text"}
      )
      if not input then return {}, {reason="cancelled"} end
      local keywords = {}
      local text = tostring(input[1] or ""):gsub("，", " ")
      for word in text:gmatch("[^%s,]+") do
        keywords[#keywords + 1] = word
      end
      state.lastKeyword = table.concat(keywords, " ")
      shown = {}
      for _, entry in ipairs(snapshot.entries) do
        local match = #keywords == 0
        for _, word in ipairs(keywords) do
          if entry.name:find(word, 1, true) then match = true; break end
        end
        if match then shown[#shown + 1] = entry end
      end
      if #shown > 0 then break end
      gg.toast("没有名称包含该关键字的物品")
    end

    local countRequests = {}
    for index, entry in ipairs(shown) do
      countRequests[index] = {address=entry.targetCountAddress}
    end
    local okCounts, counts = pcall(app.Codec.decodeMany, countRequests)
    local labels = {}
    for index, entry in ipairs(shown) do
      local count = okCounts and counts[index] or nil
      labels[index] = count and string.format("%s ×%d", entry.name, count) or
        entry.name
    end
    local choice = gg.multiChoice(
      labels, nil, string.format("选择物品（共 %d 件，可多选）", #shown)
    )
    if type(choice) ~= "table" then return {}, {reason="cancelled"} end

    local selected = {}
    for index, entry in ipairs(shown) do
      if choice[index] then
        selected[#selected + 1] = {
          address=entry.targetBaseAddress,
          name=entry.name,
          high=entry.firstObject >> 32,
          encodedLow=entry.encodedLow,
          flags=TYPE_DWORD,
        }
      end
    end
    state.lastSelection = copySelection(selected)
    trace(string.format("inventory list selector count=%d", #selected))
    return selected, {reason=#selected > 0 and "completed" or "cancelled"}
  end

  local function readNodeChildren(node)
    if node == 0 or not Memory.isMapped(node + OFFSET.nodeChildren, 8) then
      return {}
    end
    local arrayObject = untagPointer(Memory.read(node + OFFSET.nodeChildren, TYPE_QWORD))
    if arrayObject == 0 or not Memory.isMapped(arrayObject + OFFSET.arrayData, 8) then
      return {}
    end
    local data = untagPointer(Memory.read(arrayObject + OFFSET.arrayData, TYPE_QWORD))
    if data == 0 or not Memory.isMapped(data, OFFSET.arrayItems + 8) then return {} end
    local header = Memory.readMany({
      {address=data, flags=TYPE_DWORD},
      {address=data + OFFSET.arrayItems, flags=TYPE_QWORD},
    })
    local count = tonumber(header[1].value) or 0
    local items = untagPointer(header[2].value)
    if count < 1 or count > LIMIT.sceneChildren or items == 0 or
       not Memory.isMapped(items, count * 8) then
      return {}
    end
    local requests = {}
    for index = 1, count do
      requests[index] = {address=items + (index - 1) * 8, flags=TYPE_QWORD}
    end
    local children = {}
    for _, value in ipairs(Memory.readMany(requests)) do
      local child = untagPointer(value.value)
      if child ~= 0 and Memory.isMapped(child, 8) then children[#children + 1] = child end
    end
    return children
  end

  local function filterByVtable(nodes, vtable)
    if #nodes == 0 then return {} end
    local requests = {}
    for index, node in ipairs(nodes) do
      requests[index] = {address=node, flags=TYPE_QWORD}
    end
    local matched = {}
    for index, value in ipairs(Memory.readMany(requests)) do
      if untagPointer(value.value) == vtable then matched[#matched + 1] = nodes[index] end
    end
    return matched
  end

  local function readOpenedItems(current)
    local base = runtime.gameBase
    if not current.bagBoard or
       untagPointer(Memory.read(current.bagBoard, TYPE_QWORD)) ~=
         base + OFFSET.bagBoardVtable then
      current.bagBoard = nil
      local scene = untagPointer(Memory.read(
        base + TAG["动态搜值头"], TYPE_QWORD))
      local boards = filterByVtable(readNodeChildren(scene),
        base + OFFSET.bagBoardVtable)
      current.bagBoard = boards[1]
      if not current.bagBoard then return {} end
    end
    local infos = filterByVtable(readNodeChildren(current.bagBoard),
      base + OFFSET.itemInfoVtable)
    if #infos == 0 then return {} end
    local requests = {}
    for index, info in ipairs(infos) do
      requests[index] = {address=info + OFFSET.itemInfoItem}
    end
    local items = {}
    for _, raw in ipairs(Codec.decode64Many(requests)) do
      local item = untagPointer(raw)
      if item ~= 0 then items[#items + 1] = item end
    end
    return items
  end

  local function indexInventoryTargets(snapshot)
    local byTarget = {}
    for _, entry in ipairs(snapshot.entries) do
      byTarget[entry.targetBaseAddress] = entry
    end
    return byTarget
  end

  local function selectItemsByClick()
    local Listener = app.Listener
    if type(Listener) ~= "table" or type(Listener.run) ~= "function" then
      error("点击选物需要先加载 Listener 模块", 0)
    end
    state.lastSelection = {}
    pcall(gg.clearResults)
    local shared = {
      byTarget=indexInventoryTargets(readInventorySnapshot()),
      seen={},
      selected={},
      bagBoard=nil,
      refreshed=false,
      lastRecoveryReason=nil,
    }
    gg.toast("请在背包中依次点击物品（弹出详情即记录），完成后打开修改器结束")
    local report = Listener.run({
      name="inventory_click_select",
      intervalMs=50,
      hideOnCancel=true,
      initialState=shared,
      tick=function(current)
        for _, item in ipairs(readOpenedItems(current)) do
          local target = item + OFFSET.inventoryTarget
          if not current.seen[target] then
            local entry = current.byTarget[target]
            if not entry and not current.refreshed then
              current.refreshed = true
              current.byTarget = indexInventoryTargets(readInventorySnapshot())
              entry = current.byTarget[target]
            end
            current.seen[target] = true
            if entry then
              if #current.selected >= LIMIT.selectedItems then
                error("记录物品数量异常", 0)
              end
              current.selected[#current.selected + 1] = {
                address=target,
                name=entry.name,
                high=entry.firstObject >> 32,
                encodedLow=entry.encodedLow,
                flags=TYPE_DWORD,
              }
              gg.toast(string.format("已记录 %d 件：%s", #current.selected, entry.name))
            else
              gg.toast("该物品不在背包中，未记录")
            end
          end
        end
        return nil
      end,
      recover=function(problem, current)
        local reason = tostring(problem):match("^[^\r\n]+") or tostring(problem)
        if shared.lastRecoveryReason ~= reason then
          trace("inventory click selector recover: " .. reason)
          shared.lastRecoveryReason = reason
        end
        current = current or shared
        current.bagBoard = nil
        return current
      end,
      cleanup=function(current)
        state.lastSelection = copySelection((current or shared).selected)
      end,
    })
    local selected = copySelection(state.lastSelection)
    if report.cleanupError then
      error("点击选物清理失败：" .. tostring(report.cleanupError), 0)
    end
    if report.reason ~= "cancelled" and report.reason ~= "completed" then
      error("点击选物异常结束：" .. tostring(report.error or report.reason), 0)
    end
    trace(string.format("inventory click selector count=%d", #selected))
    return selected, {reason=#selected > 0 and "completed" or "cancelled"}
  end

  local function selectItems()
    local selected, report = selectItemsByClick()
    if #selected > 0 then return selected, report end
    local choice = gg.alert("没有记录到物品。\n可改用列表方式（按名称关键字筛选）选择。",
      "列表选择", "取消")
    if choice ~= 1 then return selected, report end
    return selectItemsFromList()
  end

  local validateDropSnapshot

  local DROP = {
    entrySize = 0x18,
    itemPointer = 0x00,
    rate = 0x08,
    count = 0x20,
    maxEntries = 64,
    maxCount = 99999,
    guaranteed = 10000000,
  }

  local function dropShellOffset() return FIELD["装备壳子"] end

  local function readDropSnapshot()
    local highCandidates = currentHighCandidates()
    local rootSlot = Memory.resolve(runtime.gameBase, TAG["掉落基址"], 16)
    local values = Memory.readMany({
      {address=rootSlot, flags=TYPE_QWORD},
      {address=rootSlot + 8, flags=TYPE_QWORD},
    })
    local first = pointerValue(values[1].value, "掉落表起点", true)
    local finish = pointerValue(values[2].value, "掉落表终点", true)
    if first == 0 or finish <= first then
      error("当前场景没有掉落表，请在普通关卡内使用", 0)
    end
    if (finish - first) % DROP.entrySize ~= 0 or
       (finish - first) // DROP.entrySize > DROP.maxEntries then
      error("掉落表结构异常", 0)
    end
    local count = (finish - first) // DROP.entrySize
    requireRange(first, count * DROP.entrySize, "掉落表")

    local itemRequests = {}
    for index = 1, count do
      itemRequests[index] = {
        address=first + (index - 1) * DROP.entrySize + DROP.itemPointer,
        flags=TYPE_QWORD,
      }
    end
    local itemValues = Memory.readMany(itemRequests)
    local records = {}
    for index = 1, count do
      local entry = first + (index - 1) * DROP.entrySize
      local item = pointerValue(itemValues[index].value, "掉落物品指针", true)
      if item ~= 0 then
        requireRange(item, dropShellOffset() + 20, "掉落物品对象")
        records[#records + 1] = {
          slotIndex=index,
          entryAddress=entry,
          rateAddress=entry + DROP.rate,
          itemPointer=item,
          countAddress=item + DROP.count,
          shellAddress=item + dropShellOffset(),
        }
      end
    end
    if #records == 0 then error("掉落表为空", 0) end

    local shellRequests, valueRequests = {}, {}
    for index, record in ipairs(records) do
      shellRequests[index] = {address=record.shellAddress}
      valueRequests[#valueRequests + 1] = {address=record.rateAddress}
      valueRequests[#valueRequests + 1] = {address=record.countAddress}
    end
    local encoded = Codec.decode5Many(shellRequests)
    local decodedValues = Codec.decodeMany(valueRequests)
    local decoded = {}
    for index, record in ipairs(records) do
      local ok, catalog = pcall(locateCatalog, encoded[index], highCandidates,
        "掉落槽位 " .. record.slotIndex)
      record.rate = decodedValues[index * 2 - 1]
      record.count = decodedValues[index * 2]
      if ok then
        record.id = catalog.id
        record.name = catalog.name
        decoded[#decoded + 1] = record
      else
        trace(string.format("drop skipped slot=%d reason=%s",
          record.slotIndex, tostring(catalog)))
      end
    end
    if #decoded == 0 then error("未能解码任何掉落物品，请等待场景加载完成后重试", 0) end
    return {rootSlot=rootSlot, first=first, finish=finish, records=decoded}
  end

  local function checkDropIdentity(snapshot)
    local values = Memory.readMany({
      {address=snapshot.rootSlot, flags=TYPE_QWORD},
      {address=snapshot.rootSlot + 8, flags=TYPE_QWORD},
    })
    if untagPointer(values[1].value) ~= snapshot.first or
       untagPointer(values[2].value) ~= snapshot.finish then
      error("掉落表已经变化（可能已切换关卡），请重新打开自定掉落", 0)
    end
    local requests = {}
    for index, record in ipairs(snapshot.records) do
      requests[index] = {
        address=record.entryAddress + DROP.itemPointer, flags=TYPE_QWORD,
      }
    end
    local items = Memory.readMany(requests)
    for index, record in ipairs(snapshot.records) do
      if untagPointer(items[index].value) ~= record.itemPointer then
        error("掉落物品对象已经变化，请重新打开自定掉落", 0)
      end
    end
    return true
  end

  validateDropSnapshot = function(snapshot) return checkDropIdentity(snapshot) end

  local function readRawTriples(addresses)
    local requests = {}
    for _, address in ipairs(addresses) do
      for word = 0, 2 do
        requests[#requests + 1] = {address=address + word * 4, flags=TYPE_DWORD}
      end
    end
    local values = Memory.readMany(requests)
    local triples = {}
    for index = 1, #addresses do
      local words = {}
      for word = 0, 2 do
        words[word] = tonumber(values[(index - 1) * 3 + word + 1].value) & U32_MASK
      end
      triples[index] = words
    end
    return triples
  end

  local function applyDropInput(snapshot, input)
    if type(input) ~= "table" then error("掉落输入无效", 0) end
    if #input ~= #snapshot.records then error("掉落输入数量不一致", 0) end
    local plans = {}
    for index, record in ipairs(snapshot.records) do
      local text = trim(input[index])
      if text ~= "" then
        if text == "0" then
          plans[#plans + 1] = {record=record, rate=0}
        else
          local amount = requireInteger(text, 1, DROP.maxCount,
            "掉落槽位 " .. record.slotIndex .. " 的掉落数量")
          plans[#plans + 1] = {record=record, count=amount, rate=DROP.guaranteed}
        end
      end
    end
    if #plans == 0 then return {changed=0, unchanged=true} end

    validateDropSnapshot(snapshot)
    local journal = state.dropJournal or {}
    if state.dropJournalRoot ~= snapshot.first then journal = {} end
    local fresh = {}
    for _, plan in ipairs(plans) do
      if not journal[plan.record.entryAddress] then fresh[#fresh + 1] = plan.record end
    end
    if #fresh > 0 then
      local addresses = {}
      for _, record in ipairs(fresh) do
        addresses[#addresses + 1] = record.rateAddress
        addresses[#addresses + 1] = record.countAddress
      end
      local triples = readRawTriples(addresses)
      for index, record in ipairs(fresh) do
        journal[record.entryAddress] = {
          itemPointer=record.itemPointer,
          countAddress=record.countAddress,
          rateWords=triples[index * 2 - 1],
          countWords=triples[index * 2],
        }
      end
    end
    state.dropJournal = journal
    state.dropJournalRoot = snapshot.first

    local specs = {}
    for _, plan in ipairs(plans) do
      local record = plan.record
      specs[#specs + 1] = {
        kind="key", address=record.rateAddress, value=plan.rate,
        label="掉落槽位 " .. record.slotIndex .. " 掉落权重",
      }
      if plan.count then
        specs[#specs + 1] = {
          kind="key", address=record.countAddress, value=plan.count,
          label="掉落槽位 " .. record.slotIndex .. " 掉落数量",
        }
      end
    end
    app.Transaction.write(specs, {
      label="自定掉落",
      validateIdentity=function() return checkDropIdentity(snapshot) end,
    })
    return {changed=#plans, unchanged=false}
  end

  local function restoreDrops()
    local journal = state.dropJournal
    if not journal or next(journal) == nil then return 0, 0 end
    local snapshot = readDropSnapshot()
    if snapshot.first ~= state.dropJournalRoot then
      state.dropJournal = nil
      error("已切换关卡，掉落表已由游戏重建，无需恢复", 0)
    end
    local live = {}
    for _, record in ipairs(snapshot.records) do live[record.entryAddress] = record end
    local writes, restored, skipped = {}, 0, 0
    for address, entry in pairs(journal) do
      local current = live[address]
      if current and current.itemPointer == entry.itemPointer then
        for word = 0, 2 do
          writes[#writes + 1] = {address=address + DROP.rate + word * 4,
            flags=TYPE_DWORD, value=entry.rateWords[word]}
          writes[#writes + 1] = {address=entry.countAddress + word * 4,
            flags=TYPE_DWORD, value=entry.countWords[word]}
        end
        restored = restored + 1
      else
        skipped = skipped + 1
      end
    end
    if #writes > 0 then
      app.runWithTargetPaused("恢复掉落", function()
        checkDropIdentity(snapshot)
        Memory.writeMany(writes)
      end)
    end
    state.dropJournal = nil
    return restored, skipped
  end

  local function promptDrop()
    local snapshot = readDropSnapshot()
    local labels, defaults, types = {}, {}, {}
    for index, record in ipairs(snapshot.records) do
      labels[index] = string.format(
        "%02d. %s ×%s（留空保持，0=关闭，其余=必掉数量）",
        record.slotIndex, record.name, tostring(record.count)
      )
      defaults[index] = ""
      types[index] = "number"
    end
    local input = gg.prompt(labels, defaults, types)
    if input == nil then
      trace("drop prompt cancelled without writes")
      return {cancelled=true, changed=0}
    end
    local result = applyDropInput(snapshot, input)
    if result.unchanged then
      gg.toast("未填写修改项，掉落保持不变")
    else
      gg.toast("掉落修改完成，击杀小怪即可获得")
    end
    trace(string.format("drop complete changed=%d", result.changed))
    return result
  end

  local actions = {}

  function actions.sz()
    local ok, selected, report = pcall(selectItems)
    if not ok then return actionError("点击选物", selected) end
    if #selected == 0 then
      gg.toast("未记录物品")
      return false, selected, report
    end
    gg.toast(string.format("已记录 %d 个物品", #selected))
    return true, selected, report
  end

  function actions.Drop()
    local ok, result = pcall(promptDrop)
    if not ok then return actionError("自定掉落", result) end
    return result.cancelled ~= true, result
  end

  function actions.DropRestore()
    local ok, restored, skipped = pcall(restoreDrops)
    if not ok then return actionError("恢复掉落", restored) end
    if restored == 0 and skipped == 0 then
      gg.toast("没有需要恢复的掉落修改")
      return false
    end
    gg.alert(string.format("恢复掉落完成：恢复 %d 个槽位%s", restored,
      skipped > 0 and string.format("，跳过 %d 个（物品对象已变化）", skipped) or ""))
    return true
  end

  local api = {
    actions=actions,
    refreshPointerContext=refreshPointerContext,
    readInventorySnapshot=readInventorySnapshot,
    readSelectedInventorySnapshot=readSelectedInventorySnapshot,
    validateInventorySnapshot=validateInventorySnapshot,
    selectItems=selectItems,
    readDropSnapshot=readDropSnapshot,
    validateDropSnapshot=validateDropSnapshot,
    applyDropInput=applyDropInput,
  }

  return api
end)

installModule("physics", function(app)
  local Memory, Codec = app.Memory, app.Codec
  local Transaction = app.Transaction
  local TAG, FIELD, runtime = app.TAG, app.FIELD, app.runtime
  local PANEL_FIELDS = app.PANEL_FIELDS
  local Items, Listener = app.items, app.Listener
  local requireInteger, requireNumber = app.requireInteger, app.requireNumber
  local floatToDword, untagPointer = app.floatToDword, app.untagPointer
  local trace = app.trace
  local gameBase = app.gameBase
  local resolveTag = app.resolveTag

  local TYPE_DWORD = gg.TYPE_DWORD
  local TYPE_QWORD = gg.TYPE_QWORD
  local MIN_VALID_POINTER = app.MIN_VALID_POINTER
  local FAIRY_SLOT_SIZE = app.FAIRY_SLOT_SIZE
  local FAIRY_MAX_SLOTS = app.FAIRY_MAX_SLOTS
  local COMBAT_PERSON_SIZE = FIELD["普攻基址"] + FAIRY_SLOT_SIZE
  local OFFSET = {
    titleVtable = 0x1F4CC8,
    titleAttrMap = 0xF0,
    titleHideVector = 0x120,
    hideAttrMap = 0x30,
    mapLeft = 0x00,
    mapRight = 0x08,
    mapNodeValue = 0x38,
  }
  local actions, api = {}, {}

  local COMBAT_TARGET_SPECS = {
    {id="person", label="人物", tagName="人物基址"},
  }
  if TAG["幻境基址"] then
    table.insert(COMBAT_TARGET_SPECS, 1, {
      id="instance", label="特殊副本人物", tagName="幻境基址",
      sameClassAs="人物基址",
    })
  end

  local function sameObjectClass(address, tagName)
    local okReference, reference = pcall(resolveTag, tagName, 8)
    if not okReference then return false end
    local values = Memory.readMany({
      {address=address, flags=TYPE_QWORD},
      {address=reference, flags=TYPE_QWORD},
    })
    local left, right = tonumber(values[1].value), tonumber(values[2].value)
    return left ~= nil and left ~= 0 and left == right
  end

  local function resolveCombatTargets(size, allowEmpty)
    local targets, seen, problems = {}, {}, {}
    for _, spec in ipairs(COMBAT_TARGET_SPECS) do
      local ok, address = pcall(resolveTag, spec.tagName, size or 1)
      if ok and type(address) == "number" and spec.sameClassAs and
         not sameObjectClass(address, spec.sameClassAs) then
        ok, address = false, "当前场景不是可写的特殊副本人物"
      end
      if ok and type(address) == "number" and not seen[address] then
        seen[address] = true
        targets[#targets + 1] = {
          id=spec.id, label=spec.label, tagName=spec.tagName,
          address=address,
        }
      elseif not ok then
        problems[#problems + 1] = spec.label .. "=" .. tostring(address)
      end
    end
    if #targets == 0 and not allowEmpty then
      error("一键物理战斗对象尚未加载：" .. table.concat(problems, "；"), 0)
    end
    return targets
  end

  local function validateCombatTarget(target, size)
    local current = resolveTag(target.tagName, size or 1)
    if current ~= target.address then
      error("一键物理" .. target.label .. "对象已经变化", 0)
    end
    return true
  end

  local function mappedPointer(value, size, label)
    local address = untagPointer(value)
    if address < MIN_VALID_POINTER or
       not Memory.isMapped(address, size or 1) then
      error(string.format("%s无效: 0x%X", label, address), 0)
    end
    return address
  end

  local function fairyVector(person, label)
    local field = person + FIELD["普攻基址"]
    local values = Memory.readMany({
      {address=field, flags=TYPE_QWORD},
      {address=field + 8, flags=TYPE_QWORD},
      {address=field + 16, flags=TYPE_QWORD},
    })
    local owner = mappedPointer(values[1].value, 1, label .. "起点")
    local finish = untagPointer(values[2].value)
    local capacity = untagPointer(values[3].value)
    if finish < owner or capacity < finish or
       (finish - owner) % FAIRY_SLOT_SIZE ~= 0 or
       (capacity - owner) % FAIRY_SLOT_SIZE ~= 0 then
      error(label .. "容器边界异常", 0)
    end
    local count = (finish - owner) // FAIRY_SLOT_SIZE
    local capacityCount = (capacity - owner) // FAIRY_SLOT_SIZE
    if count < 1 or count > FAIRY_MAX_SLOTS or
       capacityCount < count or capacityCount > FAIRY_MAX_SLOTS then
      error(string.format(
        "%s容器数量异常: count=%d capacity=%d",
        label, count, capacityCount
      ), 0)
    end
    mappedPointer(owner, count * FAIRY_SLOT_SIZE, label .. "数组")
    return {
      owner=owner, finish=finish, capacity=capacity,
      count=count, capacityCount=capacityCount,
    }
  end

  local function sameFairyVector(left, right)
    return type(left) == "table" and type(right) == "table" and
      left.owner == right.owner and left.finish == right.finish and
      left.capacity == right.capacity and left.count == right.count
  end

  local function validateFairyVector(person, expected, label)
    local current = fairyVector(person, label)
    if not sameFairyVector(current, expected) then
      error(label .. "对象已经变化", 0)
    end
    return current
  end

  local function writeCodecTransaction(items, label, validateIdentity)
    if #items == 0 then return true end
    local specs = {}
    for index, item in ipairs(items) do
      specs[index] = {
        kind="key", address=item.address, value=item.value,
        label=label .. "第 " .. index .. " 项",
      }
    end
    return Transaction.write(specs, {
      label=label, validateIdentity=validateIdentity, singleSnapshot=true,
    })
  end

  local function findItems(groupName, options)
    if type(Items.findItemsByGroupName) ~= "function" then
      error("全局物品查询接口缺失", 0)
    end
    local items, reason = Items.findItemsByGroupName(groupName, options)
    if not items then error(tostring(reason), 0) end
    if #items == 0 or #items > 100000 then error(groupName .. "数量异常", 0) end
    return items
  end

  local function recoverListener(problem, listenerState)
    local message = tostring(problem)
    local writeValidationFailure =
      message:find("写后", 1, true) and
      (message:find("验证失败", 1, true) or
       message:find("校验失败", 1, true))
    if writeValidationFailure or
       message:find("回滚", 1, true) or
       message:find("失败，已安全恢复原值", 1, true) or
       message:find("失败；为避免污染新对象未强制回滚", 1, true) then
      return Listener.stop("write_failure", message)
    end
    listenerState.recoveryFailures =
      (listenerState.recoveryFailures or 0) + 1
    local targetMapped = false
    local okMapped, mapped = pcall(
      Memory.isMapped, gameBase(), 1, true
    )
    if okMapped then targetMapped = mapped == true end
    if not targetMapped then
      return Listener.stop("target_unavailable", message)
    end
    if listenerState.recoveryFailures == 1 or
       listenerState.recoveryFailures % 100 == 0 then
      trace(string.format(
        "physics waiting for scene failures=%d problem=%s",
        listenerState.recoveryFailures, message
      ))
    end
    return listenerState
  end

  local function findTitleItems()
    if type(Items.walkGlobalItems) ~= "function" or
       type(Items.readItemsFromKnownGroup) ~= "function" then
      error("全局物品查询接口缺失", 0)
    end
    local nodes, reason = Items.walkGlobalItems()
    if not nodes then error(tostring(reason), 0) end
    local counts = Memory.readMany(nodes)
    local arrayRequests = {}
    for index, node in ipairs(nodes) do
      arrayRequests[index] = {
        address=node.address + Items.offset.groupArray, flags=TYPE_QWORD,
      }
    end
    local arrays = Memory.readMany(arrayRequests)
    local slotRequests, owners = {}, {}
    for index, value in ipairs(arrays) do
      local array = untagPointer(value.value)
      local count = tonumber(counts[index].value) or 0
      if array ~= 0 and count > 0 and Memory.isMapped(array, 8) then
        slotRequests[#slotRequests + 1] = {address=array, flags=TYPE_QWORD}
        owners[#owners + 1] = index
      end
    end
    local slots = Memory.readMany(slotRequests)
    local itemRequests, itemOwners = {}, {}
    for position, value in ipairs(slots) do
      local slot = untagPointer(value.value)
      if slot ~= 0 and Memory.isMapped(slot + Items.offset.slotObject, 8) then
        itemRequests[#itemRequests + 1] = {
          address=slot + Items.offset.slotObject, flags=TYPE_QWORD,
        }
        itemOwners[#itemOwners + 1] = owners[position]
      end
    end
    local itemValues = Memory.readMany(itemRequests)
    local vtableRequests, vtableOwners = {}, {}
    for position, value in ipairs(itemValues) do
      local item = untagPointer(value.value)
      if item ~= 0 and Memory.isMapped(item, 8) then
        vtableRequests[#vtableRequests + 1] = {address=item, flags=TYPE_QWORD}
        vtableOwners[#vtableOwners + 1] = itemOwners[position]
      end
    end
    local vtables = Memory.readMany(vtableRequests)
    local wanted = gameBase() + OFFSET.titleVtable
    local found
    for position, value in ipairs(vtables) do
      if untagPointer(value.value) == wanted then
        if found then error("称号目录物品组不唯一", 0) end
        found = vtableOwners[position]
      end
    end
    if not found then error("未找到称号目录（YJTitleData）", 0) end
    local node = nodes[found]
    local items, itemReason = Items.readItemsFromKnownGroup({
      address=node.address, countAddress=node.address,
      count=tonumber(counts[found].value), nodeAddress=node.nodeAddress,
    })
    if not items then error(tostring(itemReason), 0) end
    if #items == 0 or #items > 100000 then error("称号目录数量异常", 0) end
    return items
  end

  local function collectMapNodes(roots, label)
    local result, frontier = {}, {}
    for index, root in ipairs(roots) do
      result[index] = {}
      if root ~= 0 then frontier[#frontier + 1] = {owner=index, node=root} end
    end
    local visited, total = {}, 0
    while #frontier > 0 do
      local requests = {}
      for _, entry in ipairs(frontier) do
        if visited[entry.node] then error(label .. "出现循环", 0) end
        visited[entry.node] = true
        total = total + 1
        if total > 100000 then error(label .. "节点数量异常", 0) end
        mappedPointer(entry.node, OFFSET.mapNodeValue + 12, label .. "节点")
        local owned = result[entry.owner]
        owned[#owned + 1] = entry.node
        requests[#requests + 1] = {
          address=entry.node + OFFSET.mapLeft, flags=TYPE_QWORD,
        }
        requests[#requests + 1] = {
          address=entry.node + OFFSET.mapRight, flags=TYPE_QWORD,
        }
      end
      local values = Memory.readMany(requests)
      local nextFrontier = {}
      for index, entry in ipairs(frontier) do
        for side = 0, 1 do
          local child = untagPointer(values[index * 2 - 1 + side].value)
          if child ~= 0 then
            nextFrontier[#nextFrontier + 1] = {owner=entry.owner, node=child}
          end
        end
      end
      frontier = nextFrontier
    end
    return result
  end

  local function titleSnapshot()
    local items = findTitleItems()
    local records, requests = {}, {}
    local group = items[1].group
    for index, item in ipairs(items) do
      if item.group.countAddress ~= group.countAddress then
        error("称号记录来自不同目录", 0)
      end
      mappedPointer(item.address, OFFSET.titleHideVector + 16, "称号对象 " .. index)
      records[index] = {
        item=item.address,
        slotAddress=item.slotAddress,
        slotObjectAddress=item.slotObjectAddress,
        objectFieldAddress=item.objectFieldAddress,
      }
      requests[#requests + 1] = {
        address=item.address + OFFSET.titleAttrMap + 8, flags=TYPE_QWORD,
      }
      requests[#requests + 1] = {
        address=item.address + OFFSET.titleHideVector, flags=TYPE_QWORD,
      }
      requests[#requests + 1] = {
        address=item.address + OFFSET.titleHideVector + 8, flags=TYPE_QWORD,
      }
    end
    local values = Memory.readMany(requests)
    local baseRoots, hideRequests, hideOwners = {}, {}, {}
    for index, record in ipairs(records) do
      local cursor = (index - 1) * 3
      record.baseRoot = untagPointer(values[cursor + 1].value)
      record.hideBegin = untagPointer(values[cursor + 2].value)
      record.hideEnd = untagPointer(values[cursor + 3].value)
      baseRoots[index] = record.baseRoot
      local hideCount = 0
      if record.hideBegin ~= 0 then
        if record.hideEnd < record.hideBegin or
           (record.hideEnd - record.hideBegin) % 8 ~= 0 or
           record.hideEnd - record.hideBegin > 64 * 8 then
          error("称号隐藏属性容器异常 " .. index, 0)
        end
        hideCount = (record.hideEnd - record.hideBegin) // 8
        if hideCount > 0 then
          mappedPointer(record.hideBegin, hideCount * 8, "称号隐藏属性数组 " .. index)
        end
      end
      for slot = 1, hideCount do
        hideRequests[#hideRequests + 1] = {
          address=record.hideBegin + (slot - 1) * 8, flags=TYPE_QWORD,
        }
        hideOwners[#hideOwners + 1] = index
      end
      record.hideObjects = {}
    end
    local hideValues = Memory.readMany(hideRequests)
    local rootRequests = {}
    for position, value in ipairs(hideValues) do
      local record = records[hideOwners[position]]
      local object = mappedPointer(
        value.value, OFFSET.hideAttrMap + 16, "称号隐藏属性对象"
      )
      record.hideObjects[#record.hideObjects + 1] = object
      rootRequests[position] = {
        address=object + OFFSET.hideAttrMap + 8, flags=TYPE_QWORD,
      }
    end
    local rootValues = Memory.readMany(rootRequests)
    local hideRoots = {}
    for position, value in ipairs(rootValues) do
      hideRoots[position] = untagPointer(value.value)
    end
    local baseNodes = collectMapNodes(baseRoots, "称号基础属性")
    local hideNodes = collectMapNodes(hideRoots, "称号隐藏属性")
    for index, record in ipairs(records) do
      record.baseNodes = baseNodes[index]
      record.hideRoots, record.hideNodes = {}, {}
    end
    for position, owner in ipairs(hideOwners) do
      local record = records[owner]
      record.hideRoots[#record.hideRoots + 1] = hideRoots[position]
      for _, node in ipairs(hideNodes[position]) do
        record.hideNodes[#record.hideNodes + 1] = node
      end
    end
    records.group = group
    records.groupArrayAddress = items[1].groupArrayAddress
    return records
  end

  local function validateTitleCatalog(records)
    local group = records.group
    if type(group) ~= "table" or type(group.countAddress) ~= "number" or
       group.count ~= #records then
      error("称号目录快照无效", 0)
    end
    local requests = {
      {address=group.countAddress, flags=TYPE_DWORD},
      {address=group.countAddress + Items.offset.groupArray, flags=TYPE_QWORD},
    }
    for _, record in ipairs(records) do
      requests[#requests + 1] = {address=record.slotAddress, flags=TYPE_QWORD}
      requests[#requests + 1] = {
        address=record.objectFieldAddress, flags=TYPE_QWORD,
      }
      requests[#requests + 1] = {
        address=record.item + OFFSET.titleAttrMap + 8, flags=TYPE_QWORD,
      }
      requests[#requests + 1] = {
        address=record.item + OFFSET.titleHideVector, flags=TYPE_QWORD,
      }
      requests[#requests + 1] = {
        address=record.item + OFFSET.titleHideVector + 8, flags=TYPE_QWORD,
      }
      for slot, object in ipairs(record.hideObjects) do
        requests[#requests + 1] = {
          address=record.hideBegin + (slot - 1) * 8, flags=TYPE_QWORD,
        }
        requests[#requests + 1] = {
          address=object + OFFSET.hideAttrMap + 8, flags=TYPE_QWORD,
        }
      end
    end
    local values = Memory.readMany(requests)
    if values[1].value ~= group.count then error("称号目录数量已经变化", 0) end
    if untagPointer(values[2].value) ~= records.groupArrayAddress then
      error("称号目录数组已经变化", 0)
    end
    local cursor = 3
    for index, record in ipairs(records) do
      if untagPointer(values[cursor].value) ~= record.slotObjectAddress or
         untagPointer(values[cursor + 1].value) ~= record.item then
        error("称号对象已经变化 " .. index, 0)
      end
      if untagPointer(values[cursor + 2].value) ~= record.baseRoot or
         untagPointer(values[cursor + 3].value) ~= record.hideBegin or
         untagPointer(values[cursor + 4].value) ~= record.hideEnd then
        error("称号属性结构已经变化 " .. index, 0)
      end
      cursor = cursor + 5
      for slot, object in ipairs(record.hideObjects) do
        if untagPointer(values[cursor].value) ~= object or
           untagPointer(values[cursor + 1].value) ~= record.hideRoots[slot] then
          error("称号隐藏属性已经变化 " .. index, 0)
        end
        cursor = cursor + 2
      end
    end
    return true
  end

  local function titleWrites(records, baseValue, hiddenValue)
    local writes = {}
    for _, record in ipairs(records) do
      if baseValue ~= nil then
        for _, node in ipairs(record.baseNodes) do
          writes[#writes + 1] = {
            address=node + OFFSET.mapNodeValue, value=baseValue,
          }
        end
      end
      if hiddenValue ~= nil then
        for _, node in ipairs(record.hideNodes) do
          writes[#writes + 1] = {
            address=node + OFFSET.mapNodeValue, value=hiddenValue,
          }
        end
      end
    end
    if #writes == 0 then error("没有已加载的称号属性可修改", 0) end
    return writes
  end

  function actions.chenghao()
    local before = titleSnapshot()
    local answer = gg.prompt(
      {"基础属性（留空保持）", "隐藏属性（留空保持）"},
      {"99999", ""}, {"number", "number"}
    )
    if not answer then return false end
    local baseValue, hiddenValue
    if tostring(answer[1] or "") ~= "" then
      baseValue = requireInteger(answer[1], 0, 0x7FFFFFFF, "称号基础属性")
    end
    if tostring(answer[2] or "") ~= "" then
      hiddenValue = requireInteger(answer[2], 0, 0x7FFFFFFF, "称号隐藏属性")
    end
    if baseValue == nil and hiddenValue == nil then return false end

    validateTitleCatalog(before)
    local writes = titleWrites(before, baseValue, hiddenValue)
    app.restoreJournal.capture("称号秒杀", "key", writes, function()
      return validateTitleCatalog(before)
    end)
    writeCodecTransaction(writes, "称号秒杀", function()
      return validateTitleCatalog(before)
    end)
    trace(string.format("physics title writes=%d titles=%d", #writes, #before))
    gg.toast(string.format("修改完成（%d 个称号，%d 项属性）", #before, #writes))
    return true
  end

  local function parsePhysicsOptions()
    local answer = gg.prompt({
      "监听倍率（自带护盾无敌）", "监听移速（留空则不监听）", "监听仙术（仅战斗对象）",
      "修改面板",
    }, {500, "", true, false}, {
      "number", "number", "checkbox", "checkbox",
    })
    if not answer then return nil end
    local options = {
      multiplier=requireNumber(answer[1], 0.01, 100000, "监听倍率"),
      fairy=answer[3] == true,
      panel=answer[4] == true,
    }
    if tostring(answer[2] or "") ~= "" then
      options.speed = requireNumber(answer[2], 0.01, 100, "监听移速")
    end
    if options.panel then
      local labels, defaults, types = {}, {}, {}
      for index, item in ipairs(PANEL_FIELDS) do
        labels[index], defaults[index], types[index] =
          item.name .. "（0-100000000，可留空）", "", "number"
      end
      local panelAnswer = gg.prompt(labels, defaults, types)
      if not panelAnswer then return nil end
      options.panelValues = {}
      for index, item in ipairs(PANEL_FIELDS) do
        if tostring(panelAnswer[index] or "") ~= "" then
          options.panelValues[item.offset] = requireNumber(
            panelAnswer[index], 0, 100000000, item.name
          )
        end
      end
    end
    return options
  end

  local function writePhysicsCodecs(codecWrites, fairyWrites, validateIdentity)
    if #codecWrites == 0 and #fairyWrites == 0 then return true end
    local specs = {}
    for _, item in ipairs(codecWrites) do
      specs[#specs + 1] = {
        kind="key", address=item.address, value=item.value,
        label="一键物理字段",
      }
    end
    for _, item in ipairs(fairyWrites) do
      specs[#specs + 1] = {
        kind="key64", address=item.address, value=item.value,
        label="一键物理仙术槽",
      }
    end
    return Transaction.write(specs, {
      label="一键物理", validateIdentity=validateIdentity,
      validateApplied=function()
        local decoded = Codec.decodeMany(codecWrites)
        for index, item in ipairs(codecWrites) do
          if (decoded[index] & 0xFFFFFFFF) ~= (item.value & 0xFFFFFFFF) then
            error("一键物理解码写后验证失败", 0)
          end
        end
        local fairyDecoded = Codec.decode64Many(fairyWrites)
        for index, item in ipairs(fairyWrites) do
          if fairyDecoded[index] ~= item.value then
            error("一键物理仙术写后验证失败", 0)
          end
        end
        return true
      end,
    })
  end

  local function physicsJournal(options)
    if type(options.journal) ~= "table" then
      options.journal = {panel={}, fairy={}}
    end
    if type(options.journal.panel) ~= "table" then
      options.journal.panel = {}
    end
    if type(options.journal.fairy) ~= "table" then
      options.journal.fairy = {}
    end
    return options.journal
  end

  local function capturePanelJournal(options, person)
    if not options.panel or not next(options.panelValues or {}) then return end
    local journal = physicsJournal(options)
    if journal.panel[person] then return end
    local record = {person=person, entries={}}
    for offset, value in pairs(options.panelValues) do
      record.entries[#record.entries + 1] = {
        address=person + offset,
        applied=floatToDword(value),
      }
    end
    local originals = Codec.decodeMany(record.entries)
    for index, entry in ipairs(record.entries) do
      entry.original = originals[index]
    end
    journal.panel[person] = record
  end

  local function captureFairyJournal(options, person, vector, address, original)
    local journal = physicsJournal(options)
    local record = journal.fairy[vector.owner]
    if not record then
      record = {
        person=person,
        owner=vector.owner, finish=vector.finish,
        capacity=vector.capacity, count=vector.count, entries={},
      }
      journal.fairy[vector.owner] = record
    end
    if not record.entries[address] then
      record.entries[address] = {
        address=address,
        original=original,
        applied=92203,
      }
    end
  end

  local function applyPanel(options)
    if not options.panel or not next(options.panelValues or {}) then return false end
    local person = resolveTag("人物基址", 1)
    capturePanelJournal(options, person)
    local fields = {}
    for offset, value in pairs(options.panelValues) do
      fields[#fields + 1] = {address=person + offset, value=floatToDword(value)}
    end
    local current = Codec.decodeMany(fields)
    local writes = {}
    for index, field in ipairs(fields) do
      if current[index] ~= field.value then writes[#writes + 1] = field end
    end
    writePhysicsCodecs(writes, {}, function()
      if resolveTag("人物基址", 1) ~= person then
        error("一键物理面板人物对象已经变化", 0)
      end
      return true
    end)
    if #writes > 0 then
      trace(string.format(
        "physics panel applied target=person address=0x%X fields=%d",
        person, #writes
      ))
    end
    return true
  end

  local function applyPhysics(options)
    applyPanel(options)
    local targets = resolveCombatTargets(COMBAT_PERSON_SIZE)
    local guardBits = floatToDword(1)
    local targetBits = floatToDword(options.multiplier)
    local speedBits = options.speed and floatToDword(options.speed) or nil
    if type(runtime.physicsMultiplierOwnership) ~= "table" then
      runtime.physicsMultiplierOwnership = {}
    end
    if type(options.guardTrace) ~= "table" then options.guardTrace = {} end
    if type(options.ownedReuseTraced) ~= "table" then
      options.ownedReuseTraced = {}
    end

    local eligible = {}
    for _, target in ipairs(targets) do
      local multiplierAddress = target.address + FIELD["人物秒杀"]
      local fields = {
        {address=target.address + FIELD["人物等级"]},
        {address=target.address + FIELD["护盾基址"]},
        {address=target.address + FIELD["护盾基址"] + 12},
        {address=multiplierAddress},
      }
      if speedBits then
        fields[5] = {address=target.address + FIELD["人物移速"]}
      end
      local structureOk, structureProblem = pcall(function()
        local decoded = Codec.decodeMany(fields)
        local level, shield0, shield1 = decoded[1], decoded[2], decoded[3]
        if level < 1 or level > 1000 or
           (shield0 ~= 0 and shield0 ~= 1) or
           (shield1 ~= 0 and shield1 ~= 1) then
          error(string.format(
            "人物结构校验失败: level=%s shield0=%s shield1=%s",
            tostring(level), tostring(shield0), tostring(shield1)
          ), 0)
        end
        target.level, target.shield0, target.shield1 = level, shield0, shield1
        target.currentBits, target.currentSpeedBits = decoded[4], decoded[5]
      end)
      local currentBits = structureOk and target.currentBits or nil
      local ownedBits = runtime.physicsMultiplierOwnership[target.address]
      if structureOk and (currentBits == guardBits or currentBits == targetBits or
         currentBits == ownedBits) then
        target.multiplierAddress = multiplierAddress
        target.currentBits = currentBits
        target.ownedBits = ownedBits
        eligible[#eligible + 1] = target
        options.guardTrace[target.id] = nil
        if currentBits == ownedBits and currentBits ~= guardBits and
           currentBits ~= targetBits and
           not options.ownedReuseTraced[target.address] then
          trace(string.format(
            "physics reusing owned multiplier target=%s address=0x%X " ..
            "from=0x%X to=0x%X",
            target.id, target.address, currentBits & 0xFFFFFFFF,
            targetBits & 0xFFFFFFFF
          ))
          options.ownedReuseTraced[target.address] = true
        end
      elseif not structureOk then
        trace(string.format(
          "physics rejected target=%s address=0x%X problem=%s",
          target.id, target.address, tostring(structureProblem)
        ))
      else
        local previous = options.guardTrace[target.id]
        if type(previous) ~= "table" or
           previous.address ~= target.address or
           previous.current ~= currentBits or previous.owned ~= ownedBits then
          trace(string.format(
            "physics waiting guard target=%s address=0x%X current=0x%X " ..
            "wanted=0x%X owned=%s",
            target.id, target.address, currentBits & 0xFFFFFFFF,
            targetBits & 0xFFFFFFFF,
            ownedBits and string.format("0x%X", ownedBits & 0xFFFFFFFF) or "nil"
          ))
          options.guardTrace[target.id] = {
            address=target.address, current=currentBits, owned=ownedBits,
          }
        end
      end
    end
    if #eligible == 0 then return false end

    local codecWrites, fairyWrites = {}, {}
    local fairyWriteSeen = {}
    for _, target in ipairs(eligible) do
      local person = target.address
      if target.shield0 ~= 1 then
        codecWrites[#codecWrites + 1] = {
          address=person + FIELD["护盾基址"], value=1,
        }
      end
      if target.shield1 ~= 1 then
        codecWrites[#codecWrites + 1] = {
          address=person + FIELD["护盾基址"] + 12, value=1,
        }
      end
      if target.currentBits ~= targetBits then
        codecWrites[#codecWrites + 1] = {
          address=target.multiplierAddress, value=targetBits,
        }
        target.multiplierWriteQueued = true
      end
      if speedBits and target.currentSpeedBits ~= speedBits then
        codecWrites[#codecWrites + 1] = {
          address=person + FIELD["人物移速"], value=speedBits,
        }
      end
      if options.fairy then
        local okFairy, vector = pcall(
          fairyVector, person, target.label .. "仙术"
        )
        if okFairy then
          target.fairyVector = vector
          if not fairyWriteSeen[vector.owner] then
            fairyWriteSeen[vector.owner] = true
            local slots = {}
            for index = 0, vector.count - 1 do
              slots[index + 1] = {
                address=vector.owner + index * FAIRY_SLOT_SIZE,
              }
            end
            local decodedSlots = Codec.decode64Many(slots)
            for index, slot in ipairs(slots) do
              local decoded = decodedSlots[index]
              if decoded >= 0 and decoded <= 999999 and decoded ~= 92203 then
                captureFairyJournal(options, person, vector, slot.address, decoded)
                fairyWrites[#fairyWrites + 1] = {
                  address=slot.address, value=92203,
                }
              end
            end
          end
        else
          trace(string.format(
            "physics fairy unavailable target=%s address=0x%X problem=%s",
            target.id, target.address, tostring(vector)
          ))
        end
      end
    end

    writePhysicsCodecs(codecWrites, fairyWrites, function()
      for _, target in ipairs(eligible) do
        validateCombatTarget(target, COMBAT_PERSON_SIZE)
        if target.fairyVector then
          validateFairyVector(
            target.address, target.fairyVector,
            "一键物理" .. target.label .. "仙术"
          )
        end
      end
      return true
    end)
    local targetLabels = {}
    for _, target in ipairs(eligible) do
      runtime.physicsMultiplierOwnership[target.address] = targetBits
      targetLabels[#targetLabels + 1] = string.format(
        "%s:0x%X", target.id, target.address
      )
    end
    if #codecWrites > 0 or #fairyWrites > 0 then
      local now = os.time()
      options.appliedWriteCount = (options.appliedWriteCount or 0) +
        #codecWrites + #fairyWrites
      if options.lastAppliedTraceAt ~= now then
        options.lastAppliedTraceAt = now
        trace(string.format(
          "physics applied time=%d targets=%s codec=%d fairy=%d total=%d",
          now, table.concat(targetLabels, ","),
          #codecWrites, #fairyWrites, options.appliedWriteCount
        ))
      end
    end
    return true
  end

  local function cleanupPhysics(options, outcome)
    if type(options) == "table" then options.restoreSkipped = 0 end
    if type(outcome) == "table" and
       outcome.reason == "target_unavailable" then
      runtime.physicsMultiplierOwnership = {}
    end
    local journal = type(options) == "table" and options.journal or nil
    if type(journal) ~= "table" then
      trace("physics cleanup panel=0 fairy=0 skipped=0")
      return true
    end

    local targets = resolveCombatTargets(COMBAT_PERSON_SIZE, true)
    if options.fairy and next(journal.fairy or {}) then
      local seen = {}
      for _, target in ipairs(targets) do seen[target.address] = true end
      local personOk, person = pcall(resolveTag, "人物基址", COMBAT_PERSON_SIZE)
      if personOk and not seen[person] then
        targets[#targets + 1] = {
          id="person_restore", label="普通人物恢复",
          tagName="人物基址", address=person,
        }
      end
    end
    local codecWrites, fairyWrites = {}, {}
    local skipped = 0
    local validationTargets, validationByAddress = {}, {}
    local function markValidationTarget(target)
      local record = validationByAddress[target.address]
      if not record then
        record = target
        validationByAddress[target.address] = record
        validationTargets[#validationTargets + 1] = record
      end
      return record
    end

    local panelPerson
    if next(journal.panel or {}) then
      local panelOk, currentPerson = pcall(resolveTag, "人物基址", 1)
      for person, panelRecord in pairs(journal.panel) do
        if panelOk and currentPerson == person then
          for _, entry in ipairs(panelRecord.entries) do
            local current = Codec.decode(entry.address)
            if current == entry.applied and current ~= entry.original then
              codecWrites[#codecWrites + 1] = {
                address=entry.address, value=entry.original,
              }
              panelPerson = person
            elseif current ~= entry.original then
              skipped = skipped + 1
            end
          end
        else
          skipped = skipped + #panelRecord.entries
        end
      end
    end

    local fairySeen, fairyHandled = {}, {}
    for _, target in ipairs(targets) do
      local person = target.address
      if options.fairy then
        local okFairy, vector = pcall(
          fairyVector, person, target.label .. "仙术"
        )
        local fairyRecord = okFairy and not fairySeen[vector.owner] and
          journal.fairy and journal.fairy[vector.owner] or nil
        if fairyRecord and fairyRecord.person == person and
           sameFairyVector(vector, fairyRecord) then
          fairySeen[vector.owner] = true
          fairyHandled[vector.owner] = true
          local validationTarget = markValidationTarget(target)
          validationTarget.restoreFairyVector = vector
          for _, entry in pairs(fairyRecord.entries) do
            if entry.address >= vector.owner and
               entry.address < vector.finish and
               (entry.address - vector.owner) % FAIRY_SLOT_SIZE == 0 then
              local current = Codec.decode64(entry.address)
              if current == entry.applied and current ~= entry.original then
                fairyWrites[#fairyWrites + 1] = {
                  address=entry.address, value=entry.original,
                }
              elseif current ~= entry.original then
                skipped = skipped + 1
              end
            end
          end
        end
      end
    end
    for owner, record in pairs(journal.fairy or {}) do
      if not fairyHandled[owner] then
        for _ in pairs(record.entries) do skipped = skipped + 1 end
      end
    end

    writePhysicsCodecs(codecWrites, fairyWrites, function()
      for _, target in ipairs(validationTargets) do
        validateCombatTarget(target, COMBAT_PERSON_SIZE)
        if target.restoreFairyVector then
          validateFairyVector(
            target.address, target.restoreFairyVector,
            "一键物理清理时" .. target.label .. "仙术"
          )
        end
      end
      if panelPerson and resolveTag("人物基址", 1) ~= panelPerson then
        error("一键物理清理时面板人物对象已经变化", 0)
      end
      return true
    end)
    trace(string.format(
      "physics cleanup panel=%d fairy=%d skipped=%d",
      #codecWrites, #fairyWrites, skipped
    ))
    options.restoreSkipped = skipped
    options.journal = nil
    return true
  end

  local HUANGGU_PRESET = {
    multiplier=9999,
    fairy=false,
    panel={["暴击"]=6, ["命中"]=6, ["破魔"]=6, ["破邪"]=6666, ["伤害率"]=9},
  }

  local function huangguOptions()
    local options = {
      multiplier=HUANGGU_PRESET.multiplier,
      fairy=HUANGGU_PRESET.fairy,
      panel=true,
      panelValues={},
    }
    for _, item in ipairs(PANEL_FIELDS) do
      local value = HUANGGU_PRESET.panel[item.name]
      if value ~= nil then options.panelValues[item.offset] = value end
    end
    return options
  end

  local runPhysicsListener

  function actions.yjwl()
    local options = parsePhysicsOptions()
    if not options then return false end
    return runPhysicsListener(options)
  end

  function actions.hgwl()
    return runPhysicsListener(huangguOptions())
  end

  runPhysicsListener = function(options)
    local panelCount = 0
    for _ in pairs(options.panelValues or {}) do panelCount = panelCount + 1 end
    trace(string.format(
      "physics listener options multiplier=%s speed=%s fairy=%s " ..
      "panel=%s panel_fields=%d shield=auto",
      tostring(options.multiplier), tostring(options.speed),
      tostring(options.fairy), tostring(options.panel), panelCount
    ))
    gg.toast("开启成功")
    local result = Listener.run({
      name="one_key_physics",
      intervalMs=50,
      hideOnCancel=true,
      initialState=options,
      tick=function(listenerOptions)
        applyPhysics(listenerOptions)
        listenerOptions.recoveryFailures = 0
      end,
      recover=recoverListener,
      cleanup=function(listenerOptions, outcome)
        return cleanupPhysics(listenerOptions, outcome)
      end,
    })
    if result.cleanupError then
      error("一键物理监听结束，但面板/仙术自动恢复失败：" ..
        tostring(result.cleanupError), 0)
    end
    if result.reason == "cancelled" then
      if (options.restoreSkipped or 0) > 0 then
        gg.toast("监听已关闭，部分原值未恢复")
      else
        gg.toast("关闭成功")
      end
      return false
    end
    if result.reason == "target_unavailable" then
      gg.toast("游戏进程已退出，一键物理监听已安全停止")
      return false
    end
    if not result.ok then
      error("一键物理监听中断：" .. tostring(
        result.error or result.value or result.reason
      ), 0)
    end
    return true
  end

  api.applyPhysics = applyPhysics
  api.cleanupPhysics = cleanupPhysics
  return {actions=actions, api=api}
end)

installModule("equipment", function(app)
  local Memory = app.Memory
  local Codec = app.Codec
  local Transaction = app.Transaction
  local TAG = app.TAG
  local FIELD = app.FIELD
  local requireInteger = app.requireInteger
  local requireNumber = app.requireNumber
  local floatToDword = app.floatToDword
  local untagPointer = app.untagPointer
  local rotateLeft32 = app.rotateLeft32
  local trim = app.trim
  local trace = app.trace

  local TYPE_DWORD = gg.TYPE_DWORD
  local TYPE_QWORD = gg.TYPE_QWORD
  local U32_MASK = app.U32_MASK

  local LIMIT = {
    stackCount = 1000000,
    pearlId = 0x7FFFFFFF,
    pearlLevel = 1000000,
    quality = 1000000,
    attributeNodes = 512,
    attributeAbs = 3.4e38,
  }

  local OFFSET = {
    pearlOpenOrId = 0x08,
    pearlLevel = 0x14,
    pearlBreakthrough = 0x20,
    pearlStride = 0x38,
    attributeKey = 0x10,
    attributeValue = 0x28,
  }

  local ATTRIBUTE_TOKENS = {
    {"A7", "生命"}, {"A8", "魔法"}, {"A9", "攻击"},
    {"AA", "防御"}, {"CY", "破魔"}, {"AC", "魔抗"},
    {"AD", "幸运"}, {"AE", "闪避"}, {"AF", "暴击"},
    {"BL", "神力"}, {"AG", "回血"}, {"EG", "爆伤"},
    {"D8", "破邪"}, {"CK", "免伤"}, {"CJ", "伤害率"},
    {"CI", "抗暴率"}, {"CH", "命中率"}, {"BK", "豁免"},
    {"AH", "回蓝"}, {"AB", "成长率"}, {"AN", "五行1"},
    {"AO", "五行2"}, {"B8", "五行3"}, {"EH", "战力"},
    {"EJ", "悟性"}, {"BS", "防御成长(业力)"},
    {"BR", "攻击成长(业力)"}, {"BP", "生命成长(业力)"},
    {"BV", "残念"}, {"BU", "暴伤"}, {"BT", "品质经验"},
    {"EK", "灵力"}, {"EI", "根骨"},
  }

  local PERFECT_LEGEND = {
    {prefixes={"武器-"}, label="武器", attrs={{"A9", 3500}, {"AF", 0.4}}},
    {prefixes={"衣服-", "防具-"}, label="衣服", attrs={
      {"A7", 4000}, {"A8", 3000}, {"A9", 2500}, {"AF", 0.15},
    }},
    {prefixes={"饰品"}, label="饰品", attrs={
      {"A9", 1500}, {"AF", 0.10}, {"AE", 0.10}, {"AC", 0.10},
    }},
  }
  local PERFECT_LEGEND_EXCLUDE = {"化身"}

  local PEARL_PRESETS = {
    {"精攻", 502152}, {"精血", 502150}, {"精爆", 502154},
    {"精抗", 502167}, {"精伤", 502191},
    {"史攻", 502162}, {"史血", 502160}, {"史爆", 502164},
    {"史抗", 502168}, {"史伤", 502192},
  }
  local PERFECT_KARMA_QUALITY = 5
  local PERFECT_KARMA = {
    {branch="子", label="子业力", attrs={{"A9", 155}, {"BR", 236}}},
    {branch="丑", label="丑业力", attrs={{"AA", 56}, {"BS", 88}}},
    {branch="寅", label="寅业力", attrs={{"A7", 1368}, {"BP", 2088}}},
    {branch="卯", label="卯业力", attrs={
      {"A9", 80}, {"AA", 48}, {"BR", 156}, {"BS", 70},
    }},
    {branch="辰", label="辰业力", attrs={
      {"A7", 460}, {"AA", 26}, {"BP", 1220}, {"BS", 66},
    }},
    {branch="巳", label="巳业力", attrs={
      {"A7", 618}, {"A9", 55}, {"BP", 1188}, {"BR", 136},
    }},
  }

  local state = {auxiliary = nil}

  local function inventoryApi()
    local inventory = app.inventory or app.Inventory
    if type(inventory) ~= "table" or
       type(inventory.selectItems) ~= "function" or
       type(inventory.readInventorySnapshot) ~= "function" or
       type(inventory.validateInventorySnapshot) ~= "function" then
      error("装备功能需要先加载 inventory 模块", 0)
    end
    return inventory
  end

  local function copyIdentity(entry)
    return {
      node=entry.node,
      firstObject=entry.firstObject,
      secondObject=entry.secondObject,
      targetBaseAddress=entry.targetBaseAddress,
      targetCountAddress=entry.targetCountAddress,
      metadataAddress=entry.metadataAddress,
      encodedLow=entry.encodedLow,
      catalogAddress=entry.catalogAddress,
      catalogHigh=entry.catalogHigh,
      id=entry.id,
      name=entry.name,
      secondName=entry.secondName,
    }
  end

  local function sameIdentity(entry, identity)
    return entry.node == identity.node and
      entry.firstObject == identity.firstObject and
      entry.secondObject == identity.secondObject and
      entry.targetBaseAddress == identity.targetBaseAddress and
      entry.targetCountAddress == identity.targetCountAddress and
      entry.metadataAddress == identity.metadataAddress and
      entry.catalogAddress == identity.catalogAddress and
      entry.id == identity.id and entry.name == identity.name
  end

  local function findIdentity(snapshot, identity, label)
    local found
    for _, entry in ipairs(snapshot.entries) do
      if sameIdentity(entry, identity) then
        if found then error((label or "装备") .. "身份不唯一", 0) end
        found = entry
      end
    end
    if not found then error((label or "装备") .. "已经移动或被替换，请重新选择", 0) end
    return found
  end

  local function mapSelection(snapshot, selected)
    local byAddress = {}
    for _, entry in ipairs(snapshot.entries) do
      if byAddress[entry.targetBaseAddress] then
        error("背包目标地址重复，拒绝继续", 0)
      end
      byAddress[entry.targetBaseAddress] = entry
    end
    local mapped, seen = {}, {}
    for index, item in ipairs(selected) do
      local entry = byAddress[item.address]
      if not entry then
        error(string.format("第 %d 个选择项已不在动态背包中", index), 0)
      end
      if seen[entry.targetBaseAddress] then
        error("选择结果含有重复装备", 0)
      end
      seen[entry.targetBaseAddress] = true
      mapped[#mapped + 1] = entry
    end
    return mapped
  end

  local function selectInventoryEntries(label, exactOne)
    local inventory = inventoryApi()
    local selected, report = inventory.selectItems()
    if #selected == 0 then
      gg.toast("未选择" .. label)
      return nil, report
    end
    if exactOne and #selected ~= 1 then
      gg.toast(label .. "只能选择一个")
      return nil, report
    end
    local snapshot
    if type(inventory.readSelectedInventorySnapshot) == "function" then
      snapshot = inventory.readSelectedInventorySnapshot(selected)
    else
      snapshot = inventory.readInventorySnapshot()
    end
    local entries = mapSelection(snapshot, selected)
    local identities = {}
    for index, entry in ipairs(entries) do
      identities[index] = copyIdentity(entry)
    end
    return {
      inventory=inventory,
      snapshot=snapshot,
      entries=entries,
      identities=identities,
      selected=selected,
      report=report,
    }
  end

  local validateFastInventoryIdentities

  local function validateMappedSnapshot(snapshot)
    if type(snapshot) == "table" and snapshot.selectedOnly == true then
      local identities = {}
      for index, entry in ipairs(snapshot.entries or {}) do
        identities[index] = copyIdentity(entry)
      end
      if #identities == 0 then error("定点背包快照没有物品", 0) end
      return validateFastInventoryIdentities(snapshot, identities)
    end
    return inventoryApi().validateInventorySnapshot(snapshot)
  end

  local function u32(value)
    return value & U32_MASK
  end

  validateFastInventoryIdentities = function(snapshot, identities)
    if type(snapshot) ~= "table" or type(snapshot.rootSlot) ~= "number" or
       type(snapshot.root) ~= "number" or type(identities) ~= "table" or
       #identities == 0 then
      error("所选物品身份快照无效", 0)
    end
    if untagPointer(Memory.read(snapshot.rootSlot, TYPE_QWORD)) ~= snapshot.root then
      error("所选物品操作期间动态背包根已经变化", 0)
    end

    local objectRequests = {}
    for _, identity in ipairs(identities) do
      objectRequests[#objectRequests + 1] = {
        address=identity.node + 0x20, flags=TYPE_QWORD,
      }
      objectRequests[#objectRequests + 1] = {
        address=identity.node + 0x28, flags=TYPE_QWORD,
      }
    end
    local objectValues = Memory.readMany(objectRequests)
    local shellRequests, catalogRequests = {}, {}
    for index, identity in ipairs(identities) do
      local first = untagPointer(objectValues[(index - 1) * 2 + 1].value)
      local second = untagPointer(objectValues[(index - 1) * 2 + 2].value)
      if first ~= identity.firstObject or second ~= identity.secondObject or
         identity.targetBaseAddress ~= first + 0x10 or
         identity.targetCountAddress ~= first + 0x20 or
         identity.metadataAddress ~= second + 0x18 then
        error("所选第 " .. index .. " 件物品槽位已经变化", 0)
      end
      shellRequests[index] = {
        address=first + FIELD["装备壳子"],
      }
      catalogRequests[index] = {
        address=identity.catalogAddress + 0x08,
      }
    end

    local shells = Codec.decode5Many(shellRequests)
    local ids = Codec.decodeMany(catalogRequests)
    for index, identity in ipairs(identities) do
      if u32(shells[index]) ~= u32(identity.encodedLow) or
         u32(ids[index]) ~= u32(identity.id) then
        error("所选第 " .. index .. " 件物品身份已经变化", 0)
      end
    end
    return true
  end

  local function refreshInventoryIdentity(inventory, rootSnapshot, identity, label)
    label = label or "所选物品"
    if type(inventory) ~= "table" or
       type(inventory.readSelectedInventorySnapshot) ~= "function" then
      error(label .. "无法刷新身份", 0)
    end
    local refreshed = inventory.readSelectedInventorySnapshot({
      {address=identity.targetBaseAddress},
    })
    if refreshed.rootSlot ~= rootSnapshot.rootSlot or
       refreshed.root ~= rootSnapshot.root then
      error(label .. "刷新期间动态背包根已经变化", 0)
    end
    local entry = refreshed.entries and refreshed.entries[1]
    if not entry or refreshed.entries[2] or
       entry.targetBaseAddress ~= identity.targetBaseAddress or
       entry.id ~= identity.id or entry.name ~= identity.name or
       entry.secondName ~= identity.secondName then
      error(label .. "已经移动或被替换，请重新记录", 0)
    end
    local rebound = copyIdentity(entry)
    validateFastInventoryIdentities(refreshed, {rebound})
    return refreshed, rebound
  end

  local function requireSeparateStackTargets(auxiliary, targets)
    if type(auxiliary) ~= "table" or
       type(auxiliary.targetBaseAddress) ~= "number" or
       type(targets) ~= "table" or #targets == 0 then
      error("循环叠加目标身份无效", 0)
    end
    for index, target in ipairs(targets) do
      if type(target) ~= "table" or
         type(target.targetBaseAddress) ~= "number" then
        error("第 " .. index .. " 个循环叠加目标身份无效", 0)
      end
      if target.targetBaseAddress == auxiliary.targetBaseAddress then
        error("辅助物不能同时作为循环叠加目标", 0)
      end
    end
    return true
  end

  local function normalizeSpecs(specs)
    local normalized, seen = {}, {}
    for index, spec in ipairs(specs) do
      if type(spec) ~= "table" or
         (spec.kind ~= "key" and spec.kind ~= "key5" and
          spec.kind ~= "key64") then
        error("第 " .. index .. " 个写入项无效", 0)
      end
      local address = tonumber(spec.address)
      if not address or address ~= address or address == math.huge or
         address == -math.huge or address < 1 or
         address ~= math.floor(address) then
        error("加密字段地址不是有效正整数", 0)
      end
      local value = requireInteger(
        spec.value, -0x80000000, 0xFFFFFFFF, spec.label or "目标值"
      )
      local key = spec.kind .. ":" .. tostring(address)
      local previous = seen[key]
      if previous then
        if u32(previous.value) ~= u32(value) then
          error("同一字段存在冲突目标值", 0)
        end
      else
        local item = {
          kind=spec.kind,
          address=address,
          value=value,
          rekey=spec.rekey == true,
          label=spec.label or "加密字段",
        }
        seen[key] = item
        normalized[#normalized + 1] = item
      end
    end
    return normalized
  end

  local function verifySpecs(specs)
    local keyRequests, keyIndexes = {}, {}
    local key5Requests, key5Indexes = {}, {}
    local key64Requests, key64Indexes = {}, {}
    for index, spec in ipairs(specs) do
      local requests, indexes
      if spec.kind == "key" then
        requests, indexes = keyRequests, keyIndexes
      elseif spec.kind == "key64" then
        requests, indexes = key64Requests, key64Indexes
      else
        requests, indexes = key5Requests, key5Indexes
      end
      requests[#requests + 1] = {address=spec.address}
      indexes[#indexes + 1] = index
    end

    local decoded = {}
    local function collect(values, indexes)
      for position, index in ipairs(indexes) do
        decoded[index] = values[position]
      end
    end
    if #keyRequests > 0 then
      collect(Codec.decodeMany(keyRequests), keyIndexes)
    end
    if #key5Requests > 0 then
      collect(Codec.decode5Many(key5Requests), key5Indexes)
    end
    if #key64Requests > 0 then
      collect(Codec.decode64Many(key64Requests), key64Indexes)
    end

    for index, spec in ipairs(specs) do
      local matches
      if spec.kind == "key64" then
        matches = decoded[index] == spec.value
      else
        matches = u32(decoded[index]) == u32(spec.value)
      end
      if not matches then
        return false, spec.label .. "写后值不一致"
      end
    end
    return true
  end

  local function transactionalWrite(specs, validateIdentity, options)
    specs = normalizeSpecs(specs)
    if #specs == 0 then return {changed=0, unchanged=true} end
    if type(validateIdentity) ~= "function" then
      error("批量写入缺少身份复验", 0)
    end
    options = options or {}
    local transactionOptions = {
      label="装备批量写入",
      validateIdentity=validateIdentity,
    }
    if options.singleSnapshot == true then
      transactionOptions.singleSnapshot = true
    end
    if options.validateOriginal ~= nil then
      if type(options.validateOriginal) ~= "function" then
        error("写前值校验器无效", 0)
      end
      transactionOptions.validateOriginal = options.validateOriginal
    end
    if options.verifyDecoded == true then
      transactionOptions.validateApplied = function()
        local verified, problem = verifySpecs(specs)
        if not verified then error(problem, 0) end
        return true
      end
    end
    Transaction.write(specs, transactionOptions)
    local verified, problem = verifySpecs(specs)
    if not verified then error(problem, 0) end
    return {changed=#specs, unchanged=false}
  end

  local function stackSpecs(entries, target)
    target = requireInteger(target, 1, LIMIT.stackCount, "叠加数量")
    local counts, metadata = {}, {}
    for index, entry in ipairs(entries) do
      counts[#counts + 1] = {
        kind="key",
        address=entry.targetCountAddress,
        value=target,
        label="第 " .. index .. " 件物品数量",
      }
      metadata[#metadata + 1] = {
        kind="key64",
        address=entry.metadataAddress,
        value=target,
        label="第 " .. index .. " 件物品叠加元数据",
      }
    end
    local specs = {}
    for _, spec in ipairs(counts) do specs[#specs + 1] = spec end
    for _, spec in ipairs(metadata) do specs[#specs + 1] = spec end
    return specs
  end

  local function validateStackOriginal(entries, original)
    for index, entry in ipairs(entries) do
      local countRaw = original[index]
      local metadataRaw = original[#entries + index]
      local count = rotateLeft32(countRaw[4] ~ TAG["自拟值"], countRaw[8])
      local metadata = Codec.decode64(entry.metadataAddress)
      local primary = metadataRaw[0]
      if metadata ~= count or
         u32(primary ~ (primary >> 32)) ~= rotateLeft32(count, 7) then
        error("第 " .. index .. " 件物品原始数量副本不一致，请重启游戏后重新记录", 0)
      end
    end
    return true
  end

  local function applyStack(snapshot, entries, target)
    return transactionalWrite(stackSpecs(entries, target), function()
      validateMappedSnapshot(snapshot)
    end, {
      verifyDecoded=true,
      validateOriginal=function(original)
        return validateStackOriginal(entries, original)
      end,
    })
  end

  local function readStackCounts(entries)
    local requests = {}
    for index, entry in ipairs(entries) do
      requests[index] = {address=entry.targetCountAddress}
    end
    local counts = Codec.decodeMany(requests)
    for index, count in ipairs(counts) do
      counts[index] = requireInteger(
        count, 0, LIMIT.stackCount, "第 " .. index .. " 件物品当前数量"
      )
    end
    if #counts ~= #entries then error("批量读取物品数量不完整", 0) end
    return counts
  end

  local function incrementStackSpecs(entries, counts, increment)
    increment = requireInteger(
      increment, 1, LIMIT.stackCount, "循环叠加增加量"
    )
    local countsSpecs, metadataSpecs = {}, {}
    for index, entry in ipairs(entries) do
      local nextValue = requireInteger(
        counts[index] + increment, 1, LIMIT.stackCount,
        "第 " .. index .. " 件物品叠加后数量"
      )
      countsSpecs[index] = {
        kind="key",
        address=entry.targetCountAddress,
        value=nextValue,
        label="第 " .. index .. " 件物品循环数量",
      }
      metadataSpecs[index] = {
        kind="key64",
        address=entry.metadataAddress,
        value=nextValue,
        label="第 " .. index .. " 件物品循环元数据",
      }
    end
    local specs = {}
    for _, spec in ipairs(countsSpecs) do specs[#specs + 1] = spec end
    for _, spec in ipairs(metadataSpecs) do specs[#specs + 1] = spec end
    return specs
  end

  local function applyStackIncrement(snapshot, entries, increment, identityValidator)
    local validateIdentity = identityValidator or function()
      return validateMappedSnapshot(snapshot)
    end
    validateIdentity()
    local counts = readStackCounts(entries)
    local specs = incrementStackSpecs(entries, counts, increment)
    local itemCount = #entries
    local function validateOriginal(original)
      validateStackOriginal(entries, original)
      for index = 1, itemCount do
        local raw = original[index]
        local decoded = rotateLeft32(raw[4] ~ TAG["自拟值"], raw[8])
        if u32(decoded) ~= u32(counts[index]) then
          error("循环叠加目标数量在写入前发生变化", 0)
        end
      end
      return true
    end
    return transactionalWrite(specs, validateIdentity, {
      verifyDecoded=true,
      singleSnapshot=true,
      validateOriginal=validateOriginal,
    })
  end

  local function buildPearlSnapshot(selection)
    local requests = {}
    for index, entry in ipairs(selection.entries) do
      requests[index] = {
        address=entry.targetBaseAddress + FIELD["启灵珠"],
        flags=TYPE_QWORD,
      }
    end
    local values = Memory.readMany(requests)
    local pearls = {}
    for index, entry in ipairs(selection.entries) do
      local root = untagPointer(values[index].value)
      if root == 0 or not Memory.isMapped(
          root, OFFSET.pearlStride * 3 + OFFSET.pearlBreakthrough + 12
        ) then
        error("第 " .. index .. " 件装备的启灵对象无效", 0)
      end
      pearls[index] = {
        pointerSlot=requests[index].address,
        root=root,
        identity=copyIdentity(entry),
      }
    end
    local snapshot = {
      inventory=selection.inventory,
      inventorySnapshot=selection.snapshot,
      pearls=pearls,
    }
    return snapshot
  end

  local function validatePearlSnapshot(snapshot)
    validateMappedSnapshot(snapshot.inventorySnapshot)
    local requests = {}
    for index, pearl in ipairs(snapshot.pearls) do
      requests[index] = {address=pearl.pointerSlot, flags=TYPE_QWORD}
    end
    local values = Memory.readMany(requests)
    for index, pearl in ipairs(snapshot.pearls) do
      if untagPointer(values[index].value) ~= pearl.root then
        error("第 " .. index .. " 件装备的启灵对象已经变化", 0)
      end
    end
    return true
  end

  local function pearlSpecs(snapshot, fieldOffset, slotValues, label)
    local specs = {}
    for itemIndex, pearl in ipairs(snapshot.pearls) do
      for slot = 1, 4 do
        local value = slotValues[slot]
        if value ~= nil then
          specs[#specs + 1] = {
            kind="key",
            address=pearl.root + fieldOffset + (slot - 1) * OFFSET.pearlStride,
            value=value,
            label=string.format("第 %d 件装备孔 %d 的%s", itemIndex, slot, label),
          }
        end
      end
    end
    return specs
  end

  local function pearlLevelSpecs(snapshot, levels, breakthroughs)
    local specs = pearlSpecs(
      snapshot, OFFSET.pearlLevel, levels, "等级"
    )
    local second = pearlSpecs(
      snapshot, OFFSET.pearlBreakthrough, breakthroughs, "突破"
    )
    for _, spec in ipairs(second) do specs[#specs + 1] = spec end
    return specs
  end

  local function readAttributeChain(rootField)
    local nodes, seen = {}, {}
    local current = rootField
    while true do
      if #nodes >= LIMIT.attributeNodes then error("装备属性节点数量异常", 0) end
      if seen[current] then error("装备属性链出现循环", 0) end
      if not Memory.isMapped(current, OFFSET.attributeValue + 12) then
        error("装备属性节点地址无效", 0)
      end
      seen[current] = true
      local raw = Memory.read(current, TYPE_QWORD)
      local nextPointer = 0
      if (raw & U32_MASK) ~= 0 then
        nextPointer = untagPointer(raw)
        if nextPointer == 0 then error("装备属性节点指针无效", 0) end
      end
      nodes[#nodes + 1] = {
        address=current,
        nextPointer=nextPointer,
        valueAddress=current + OFFSET.attributeValue,
      }
      if nextPointer == 0 then break end
      current = nextPointer
    end
    local keyAddresses = {}
    for index, node in ipairs(nodes) do
      keyAddresses[index] = node.address + OFFSET.attributeKey
    end
    local names = Memory.readStdStrings(keyAddresses, 96)
    for index, node in ipairs(nodes) do node.name = names[index] end
    return nodes
  end

  local function attributeRoot(targetBase)
    local ok, rootField = pcall(Memory.resolve, targetBase, TAG["属性地址"],
      OFFSET.attributeValue + 12)
    if not ok then error("没有找到装备属性表：" .. tostring(rootField), 0) end
    return "属性地址", rootField
  end

  local function buildAttributeSnapshot(selection)
    if #selection.entries ~= 1 then error("自定属性只能选择一件装备", 0) end
    local entry = selection.entries[1]
    local category, rootField = attributeRoot(entry.targetBaseAddress)
    local path = TAG[category]
    local nodes = readAttributeChain(rootField)
    local attributes = {}
    for _, node in ipairs(nodes) do
      for tokenIndex, token in ipairs(ATTRIBUTE_TOKENS) do
        if node.name:find(token[1], 1, true) then
          attributes[#attributes + 1] = {
            order=tokenIndex,
            token=token[1],
            label=token[2],
            nodeAddress=node.address,
            valueAddress=node.valueAddress,
            name=node.name,
          }
          break
        end
      end
    end
    if #attributes == 0 then error("没有识别到可修改的装备属性", 0) end
    table.sort(attributes, function(left, right) return left.order < right.order end)
    return {
      inventory=selection.inventory,
      inventorySnapshot=selection.snapshot,
      identity=copyIdentity(entry),
      category=category,
      path=path,
      rootField=rootField,
      nodes=nodes,
      attributes=attributes,
    }
  end

  local function validateAttributeSnapshot(snapshot)
    validateFastInventoryIdentities(
      snapshot.inventorySnapshot, {snapshot.identity}
    )
    local entry = findIdentity(
      snapshot.inventorySnapshot, snapshot.identity, "自定属性装备"
    )
    local category, rootField = attributeRoot(entry.targetBaseAddress)
    if category ~= snapshot.category then
      error("装备属性类别已经变化", 0)
    end
    if rootField ~= snapshot.rootField then error("装备属性根节点已经变化", 0) end
    local nodes = readAttributeChain(rootField)
    if #nodes ~= #snapshot.nodes then error("装备属性链长度已经变化", 0) end
    for index, node in ipairs(nodes) do
      local old = snapshot.nodes[index]
      if node.address ~= old.address or node.nextPointer ~= old.nextPointer or
         node.name ~= old.name or node.valueAddress ~= old.valueAddress then
        error("装备属性节点身份已经变化", 0)
      end
    end
    return true
  end

  local function optionalInteger(value, minimum, maximum, label)
    local text = trim(value)
    if text == "" then return nil end
    return requireInteger(text, minimum, maximum, label)
  end

  local function runAction(label, body, unchangedIsFalse)
    local ok, result = pcall(body)
    if not ok then
      pcall(gg.clearResults)
      return app.actionError(label, result)
    end
    if result.cancelled == true then return false, result end
    if unchangedIsFalse and result.unchanged == true then
      return false, result
    end
    return true, result
  end

  local actions = {}

  function actions.diejia()
    return runAction("手动叠加", function()
      local selection = selectInventoryEntries("要叠加的物品", false)
      if not selection then return {cancelled=true} end
      local input = gg.prompt({
        string.format("目标数量（已记录 %d 件）", #selection.entries),
      }, {1}, {"number"})
      if input == nil then return {cancelled=true} end
      local target = requireInteger(
        input[1], 1, LIMIT.stackCount, "叠加数量"
      )
      trace(string.format("equipment stack64 manual selected=%d target=%d",
        #selection.entries, target))
      local report = applyStack(selection.snapshot, selection.entries, target)
      trace("equipment stack64 manual verified full-qword")
      gg.toast(string.format("叠加完成：%d 件物品", #selection.entries))
      return report
    end)
  end

  function actions.jilufuzhu()
    return runAction("记录辅助物", function()
      local selection = selectInventoryEntries("辅助物", true)
      if not selection then return {cancelled=true} end
      local auxiliary = {identity=copyIdentity(selection.entries[1])}
      validateFastInventoryIdentities(
        selection.snapshot, selection.identities
      )
      state.auxiliary = auxiliary
      gg.toast("辅助物记录完成")
      return {identity=auxiliary.identity}
    end)
  end

  function actions.xunhuandiejia()
    return runAction("循环叠加", function()
      if not state.auxiliary then error("请先记录一个辅助物", 0) end
      local selection = selectInventoryEntries("循环叠加目标", false)
      if not selection then return {cancelled=true} end
      local input = gg.prompt({"想要循环的数量"}, {1}, {"number"})
      if input == nil then return {cancelled=true} end
      local increment = requireInteger(
        input[1], 1, LIMIT.stackCount, "循环叠加增加量"
      )
      local identities = {}
      for index, entry in ipairs(selection.entries) do
        local identity = copyIdentity(entry)
        identities[index] = identity
      end
      requireSeparateStackTargets(state.auxiliary.identity, identities)

      local auxiliaryEntry = copyIdentity(state.auxiliary.identity)
      local auxiliarySnapshot = selection.snapshot
      local function validateTargetIdentity()
        return validateFastInventoryIdentities(
          selection.snapshot, identities
        )
      end
      local function validateAuxiliaryIdentity()
        local valid, problem = pcall(
          validateFastInventoryIdentities,
          auxiliarySnapshot,
          {auxiliaryEntry}
        )
        if valid then return true end
        if not tostring(problem):find("物品身份已经变化", 1, true) then
          error(problem, 0)
        end

        auxiliarySnapshot, auxiliaryEntry = refreshInventoryIdentity(
          selection.inventory,
          selection.snapshot,
          auxiliaryEntry,
          "辅助物"
        )
        requireSeparateStackTargets(auxiliaryEntry, identities)
        trace("equipment stack auxiliary identity rebound")
        return true
      end
      local function validateLoopIdentity()
        validateAuxiliaryIdentity()
        return validateTargetIdentity()
      end
      validateLoopIdentity()
      local auxiliaryAddress = auxiliaryEntry.targetCountAddress
      local baseline = Memory.read(auxiliaryAddress, TYPE_DWORD)
      local Listener = app.Listener
      if type(Listener) ~= "table" or
         type(Listener.run) ~= "function" or
         type(Listener.stop) ~= "function" then
        error("循环叠加需要先加载 Listener 模块", 0)
      end

      gg.toast("辅助物数量变化时自动叠加；打开修改器停止")
      trace(string.format("equipment stack64 loop selected=%d increment=%d",
        #selection.entries, increment))
      local function waitForStack(milliseconds)
        local slept, problem = pcall(gg.sleep, milliseconds)
        if gg.isVisible() then return false end
        if not slept then error(problem, 0) end
        return true
      end
      local shared = {baseline=baseline, observed=0, writes=0}
      local report = Listener.run({
        name="equipment_stack_loop",
        intervalMs=50,
        hideOnCancel=true,
        initialState=shared,
        tick=function(current)
          local raw = Memory.read(auxiliaryAddress, TYPE_DWORD)
          if u32(raw) == u32(current.baseline) then return nil end

          current.baseline = raw
          current.observed = current.observed + 1

          if not waitForStack(500) then return Listener.stop("cancelled") end
          validateLoopIdentity()
          local writeOk, writeProblem
          for attempt = 1, 3 do
            if gg.isVisible() then return Listener.stop("cancelled") end
            writeOk, writeProblem = pcall(
              applyStackIncrement,
              selection.snapshot,
              selection.entries,
              increment,
              validateTargetIdentity
            )
            if writeOk then break end
            if not tostring(writeProblem):find(
                "循环叠加目标数量在写入前发生变化", 1, true
              ) or attempt == 3 then
              error(writeProblem, 0)
            end
            if not waitForStack(50) then return Listener.stop("cancelled") end
          end
          current.writes = current.writes + 1
          trace(string.format(
            "equipment stack loop trigger observed=%d writes=%d",
            current.observed, current.writes
          ))
          gg.toast("循环叠加已执行 " .. current.writes .. " 次")
          return nil
        end,
        recover=function(problem)
          return Listener.stop("listener_error", problem)
        end,
        cleanup=function(_, outcome)
          if outcome.reason == "cancelled" then
            outcome.cancelled = true
            pcall(gg.setVisible, false)
          end
          pcall(gg.clearResults)
        end,
      })
      report.writes = shared.writes
      report.observed = shared.observed
      if report.reason ~= "cancelled" then
        error("循环叠加异常结束：" ..
          tostring(report.error or report.value or report.reason), 0)
      end
      gg.toast("循环叠加已停止")
      return report
    end)
  end

  function actions.qilingquankai()
    return runAction("启灵全开", function()
      local selection = selectInventoryEntries("要开启启灵孔的装备", false)
      if not selection then return {cancelled=true} end
      local snapshot = buildPearlSnapshot(selection)
      local report = transactionalWrite(
        pearlSpecs(snapshot, OFFSET.pearlOpenOrId, {1, 1, 1, 1}, "开启值"),
        function() validatePearlSnapshot(snapshot) end
      )
      gg.toast("四孔全开")
      return report
    end)
  end

  local function choosePearlIds()
    local MANUAL = #PEARL_PRESETS + 2
    local items = {"保持不变"}
    for index, preset in ipairs(PEARL_PRESETS) do items[index + 1] = preset[1] end
    items[MANUAL] = "✏️ 手动输入 ID"
    state.pearlChoices = state.pearlChoices or {}
    local values, manualSlots = {}, {}
    for slot = 1, 4 do
      local choice = gg.choice(items, state.pearlChoices[slot] or 1,
        string.format("孔%d 启灵（%d/4）", slot, slot))
      if choice == nil then return nil end
      state.pearlChoices[slot] = choice
      if choice == MANUAL then
        manualSlots[#manualSlots + 1] = slot
      elseif choice > 1 then
        values[slot] = PEARL_PRESETS[choice - 1][2]
      end
    end
    if #manualSlots > 0 then
      local labels, defaults, types = {}, {}, {}
      for index, slot in ipairs(manualSlots) do
        labels[index] = string.format("孔%d ID（留空保持）", slot)
        defaults[index] = ""
        types[index] = "number"
      end
      local input = gg.prompt(labels, defaults, types)
      if input == nil then return nil end
      for index, slot in ipairs(manualSlots) do
        values[slot] = optionalInteger(
          input[index], 0, LIMIT.pearlId, "孔 " .. slot .. " ID"
        )
      end
    end
    return values
  end

  function actions.zidingqiling()
    return runAction("自定启灵", function()
      local selection = selectInventoryEntries("要修改启灵 ID 的装备", false)
      if not selection then return {cancelled=true} end
      local snapshot = buildPearlSnapshot(selection)
      local values = choosePearlIds()
      if not values then return {cancelled=true} end
      local specs = pearlSpecs(
        snapshot, OFFSET.pearlOpenOrId, values, "ID"
      )
      local report = transactionalWrite(specs, function()
        validatePearlSnapshot(snapshot)
      end)
      if report.unchanged then gg.toast("未填写修改项")
      else gg.toast("启灵 ID 修改完成") end
      return report
    end, true)
  end

  function actions.qilingjieji()
    return runAction("启灵阶级", function()
      local selection = selectInventoryEntries("要修改启灵阶级的装备", false)
      if not selection then return {cancelled=true} end
      local snapshot = buildPearlSnapshot(selection)
      local mode = gg.alert(
        "选择修改方式（一键修改会统一四孔）",
        "一键修改阶级", "自定阶级"
      )
      if mode ~= 1 and mode ~= 2 then return {cancelled=true} end

      local levels, breakthroughs = {}, {}
      if mode == 1 then
        local input = gg.prompt(
          {"等级（留空保持）", "突破（留空保持）"},
          {50, 30}, {"number", "number"}
        )
        if input == nil then return {cancelled=true} end
        local level = optionalInteger(
          input[1], 0, LIMIT.pearlLevel, "启灵等级"
        )
        local breakthrough = optionalInteger(
          input[2], 0, LIMIT.pearlLevel, "启灵突破"
        )
        for slot = 1, 4 do
          levels[slot] = level
          breakthroughs[slot] = breakthrough
        end
      else
        local labels, defaults, types = {}, {}, {}
        for slot = 1, 4 do
          labels[#labels + 1] = "孔 " .. slot .. " 等级（留空保持）"
          labels[#labels + 1] = "孔 " .. slot .. " 突破（留空保持）"
          defaults[#defaults + 1], defaults[#defaults + 1] = "", ""
          types[#types + 1], types[#types + 1] = "number", "number"
        end
        local input = gg.prompt(labels, defaults, types)
        if input == nil then return {cancelled=true} end
        for slot = 1, 4 do
          levels[slot] = optionalInteger(
            input[(slot - 1) * 2 + 1], 0, LIMIT.pearlLevel,
            "孔 " .. slot .. " 等级"
          )
          breakthroughs[slot] = optionalInteger(
            input[(slot - 1) * 2 + 2], 0, LIMIT.pearlLevel,
            "孔 " .. slot .. " 突破"
          )
        end
      end

      local report = transactionalWrite(
        pearlLevelSpecs(snapshot, levels, breakthroughs),
        function() validatePearlSnapshot(snapshot) end
      )
      if report.unchanged then gg.toast("未填写修改项")
      else gg.toast("启灵阶级修改完成") end
      return report
    end, true)
  end

  function actions.zdsx()
    return runAction("自定属性", function()
      local selection = selectInventoryEntries("要修改属性的装备", true)
      if not selection then return {cancelled=true} end
      local snapshot = buildAttributeSnapshot(selection)
      local labels, defaults, types = {}, {}, {}
      for index, attribute in ipairs(snapshot.attributes) do
        labels[index] = string.format(
          "%s [%s]（留空保持）", attribute.label, attribute.token
        )
        defaults[index] = ""
        types[index] = "number"
      end
      local input = gg.prompt(labels, defaults, types)
      if input == nil then return {cancelled=true} end
      local specs = {}
      for index, attribute in ipairs(snapshot.attributes) do
        local text = trim(input[index])
        if text ~= "" then
          local value = requireNumber(
            text, -LIMIT.attributeAbs, LIMIT.attributeAbs,
            attribute.label .. "属性值"
          )
          specs[#specs + 1] = {
            kind="key",
            address=attribute.valueAddress,
            value=floatToDword(value),
            label=attribute.label .. "属性",
          }
        end
      end
      local report = transactionalWrite(specs, function()
        validateAttributeSnapshot(snapshot)
      end)
      if report.unchanged then gg.toast("未填写修改项")
      else gg.toast("装备属性修改完成") end
      return report
    end, true)
  end

  function actions.zbpz()
    return runAction("装备品质", function()
      local selection = selectInventoryEntries("要修改品质的装备", false)
      if not selection then return {cancelled=true} end
      local input = gg.prompt({"目标品质"}, {""}, {"number"})
      if input == nil then return {cancelled=true} end
      local quality = requireInteger(
        input[1], 0, LIMIT.quality, "装备品质"
      )
      local specs = {}
      for index, entry in ipairs(selection.entries) do
        specs[index] = {
          kind="key",
          address=entry.targetBaseAddress + FIELD["装备品质"],
          value=quality,
          label="第 " .. index .. " 件装备品质",
        }
      end
      local report = transactionalWrite(specs, function()
        validateFastInventoryIdentities(
          selection.snapshot, selection.identities
        )
      end)
      gg.toast("装备品质修改完成")
      return report
    end)
  end

  local function legendPreset(typeName)
    for _, keyword in ipairs(PERFECT_LEGEND_EXCLUDE) do
      if typeName:find(keyword, 1, true) then return nil end
    end
    for _, preset in ipairs(PERFECT_LEGEND) do
      for _, prefix in ipairs(preset.prefixes) do
        if typeName:sub(1, #prefix) == prefix then return preset end
      end
    end
    return nil
  end

  local function karmaPreset(typeName)
    if not typeName:find("业力", 1, true) then return nil end
    for _, preset in ipairs(PERFECT_KARMA) do
      if typeName:sub(-#preset.branch) == preset.branch then return preset end
    end
    return nil
  end

  local function applyPerfectPreset(label, findPreset, quality)
    local selection = selectInventoryEntries(label, false)
    if not selection then return {cancelled=true} end
    local specs, snapshots, lines, skipped = {}, {}, {}, {}
    for _, entry in ipairs(selection.entries) do
      local typeName = tostring(entry.secondName or "")
      local itemName = tostring(entry.name or "未知装备")
      local preset = findPreset(typeName)
      if not preset then
        skipped[#skipped + 1] = string.format("%s（%s）", itemName, typeName)
      else
        local snapshot = buildAttributeSnapshot({
          inventory=selection.inventory,
          snapshot=selection.snapshot,
          entries={entry},
        })
        local byToken = {}
        for _, attribute in ipairs(snapshot.attributes) do
          byToken[attribute.token] = byToken[attribute.token] or attribute
        end
        local missing = {}
        for _, pair in ipairs(preset.attrs) do
          local attribute = byToken[pair[1]]
          if attribute then
            specs[#specs + 1] = {
              kind="key", address=attribute.valueAddress,
              value=floatToDword(pair[2]),
              label=itemName .. attribute.label,
            }
          else
            missing[#missing + 1] = pair[1]
          end
        end
        if quality then
          specs[#specs + 1] = {
            kind="key",
            address=entry.targetBaseAddress + FIELD["装备品质"],
            value=quality, label=itemName .. "品质",
          }
        end
        snapshots[#snapshots + 1] = snapshot
        lines[#lines + 1] = string.format("%s → %s%s", itemName, preset.label,
          #missing > 0 and ("（缺少属性 " .. table.concat(missing, "、") .. "）") or "")
      end
    end
    if #specs == 0 then
      gg.alert("选中的装备都没有对应预设，未修改：\n" .. table.concat(skipped, "\n"))
      return {changed=0, unchanged=true}
    end
    local report = transactionalWrite(specs, function()
      for _, snapshot in ipairs(snapshots) do validateAttributeSnapshot(snapshot) end
    end)
    local message = "已套用预设：\n" .. table.concat(lines, "\n")
    if #skipped > 0 then
      message = message .. "\n\n没有对应预设（未修改）：\n" .. table.concat(skipped, "\n")
    end
    gg.alert(message)
    trace(string.format("perfect preset %s applied=%d skipped=%d writes=%d",
      label, #lines, #skipped, #specs))
    return report
  end

  function actions.wmcs()
    return runAction("一键完美传说", function()
      return applyPerfectPreset("要套用完美传说的装备", legendPreset, nil)
    end, true)
  end

  function actions.wmyl()
    return runAction("一键完美业力", function()
      return applyPerfectPreset("要套用完美业力的装备", karmaPreset,
        PERFECT_KARMA_QUALITY)
    end, true)
  end

  local api = {
    actions=actions,
    transactionalWrite=transactionalWrite,
    applyStack=applyStack,
    applyStackIncrement=applyStackIncrement,
    validateFastInventoryIdentities=validateFastInventoryIdentities,
    refreshInventoryIdentity=refreshInventoryIdentity,
    requireSeparateStackTargets=requireSeparateStackTargets,
    buildPearlSnapshot=buildPearlSnapshot,
    validatePearlSnapshot=validatePearlSnapshot,
    buildAttributeSnapshot=buildAttributeSnapshot,
    validateAttributeSnapshot=validateAttributeSnapshot,
    getAuxiliary=function()
      return state.auxiliary and {identity=state.auxiliary.identity} or nil
    end,
    clearAuxiliary=function() state.auxiliary = nil end,
  }

  return api
end)

installModule("creationPet", function(app)
  local Memory = app.Memory
  local Codec = app.Codec
  local TAG = app.TAG
  local FIELD = app.FIELD
  local runtime = app.runtime
  local Pet = app.pet
  local requireInteger = app.requireInteger
  local untagPointer = app.untagPointer
  local sameU32 = app.sameU32
  local traceback = app.traceback
  local runWithTargetPaused = app.runWithTargetPaused
  local trace = app.trace
  local gameBase = app.gameBase
  local requirePath = app.requirePath
  local requireField = app.requireField

  local TYPE_DWORD = gg.TYPE_DWORD
  local TYPE_QWORD = gg.TYPE_QWORD
  local U32_MASK = app.U32_MASK
  local PHYSICAL_MAXIMUM = Pet.physicalMaximum
  local BOOK_SLOTS = 110
  local CAPACITY_NOTICE_PREFIX = "宠物数组真实容量不足："

  local OFFSET = {
    bookOwner = FIELD["宠物指针"],
    bookName = FIELD["宠物名称"],
    referenceWord = 0x10,
    followTarget = 0x1120,
  }

  local state = {
    recordedBookPets={},
  }

  local function pointer(value, label)
    local number = tonumber(value)
    if not number or number ~= math.floor(number) then
      error((label or "指针") .. "不是整数", 0)
    end
    local address = untagPointer(number)
    if address == 0 then error((label or "指针") .. "为空", 0) end
    return address
  end

  local function nullablePointer(value, label)
    local number = tonumber(value)
    if not number or number ~= math.floor(number) then
      error((label or "指针") .. "不是整数", 0)
    end
    return untagPointer(number)
  end

  local function requireMapped(address, size, label, refresh)
    address = pointer(address, label)
    size = requireInteger(size or 1, 1, 0x7FFFFFFF,
                          (label or "内存") .. "长度")
    if not Memory.isMapped(address, size, refresh == true) then
      error(string.format("%s范围无效：0x%X + 0x%X",
        label or "内存", address, size), 0)
    end
    return address
  end

  local function verifyRawWrites(writes, label)
    if #writes == 0 then return true end
    local requests = {}
    for index, item in ipairs(writes) do
      requests[index] = {address=item.address, flags=item.flags}
    end
    local values = Memory.readMany(requests)
    for index, actual in ipairs(values) do
      local expected = writes[index]
      if expected.flags == TYPE_QWORD then
        if nullablePointer(actual.value, label) ~=
           nullablePointer(expected.value, label) then
          error((label or "原始内存") .. "写后验证失败", 0)
        end
      elseif not sameU32(actual.value, expected.value) then
        error((label or "原始内存") .. "写后验证失败", 0)
      end
    end
    return true
  end

  local function verifyExactQwordWrites(writes, label)
    if #writes == 0 then return true end
    local requests = {}
    for index, item in ipairs(writes) do
      requests[index] = {address=item.address, flags=TYPE_QWORD}
    end
    local values = Memory.readMany(requests)
    for index, actual in ipairs(values) do
      if tonumber(actual.value) ~= tonumber(writes[index].value) then
        error((label or "QWORD 原始内存") ..
          "写后标签位验证失败", 0)
      end
    end
    return true
  end

  local requireOwnedRawWrites, requireRawWritesOriginal

  local verifyCodecWrites = Codec.verifyWrites

  local function captureCodecTransaction(writes)
    if type(TAG["自拟值"]) ~= "number" then
      error("渠道服 Codec 自拟值尚未初始化", 0)
    end
    local requests = {}
    for _, item in ipairs(writes) do
      requireInteger(item.value, -0x80000000, 0xFFFFFFFF, "加密数值")
      requests[#requests + 1] = {address=item.address, flags=TYPE_DWORD}
      requests[#requests + 1] = {address=item.address + 4, flags=TYPE_DWORD}
      requests[#requests + 1] = {address=item.address + 8, flags=TYPE_DWORD}
    end
    local values = Memory.readMany(requests)
    local rollback = {rawOriginal={}, rawExpected={}}
    for index, item in ipairs(writes) do
      local base = (index - 1) * 3
      local raw0 = values[base + 1].value & U32_MASK
      local raw4 = values[base + 2].value & U32_MASK
      local raw8 = values[base + 3].value & U32_MASK
      local decoded = app.rotateLeft32(raw4 ~ TAG["自拟值"], raw8)
      rollback[index] = {address=item.address, value=decoded}
      local originals = {raw0, raw4, raw8}
      local targets = {Codec.encodeKey(
        raw0, raw4, raw8, item.value & U32_MASK, true
      )}
      for offsetIndex = 1, 3 do
        local address = item.address + (offsetIndex - 1) * 4
        rollback.rawOriginal[#rollback.rawOriginal + 1] = {
          address=address,
          flags=TYPE_DWORD,
          value=originals[offsetIndex],
        }
        rollback.rawExpected[#rollback.rawExpected + 1] = {
          address=address,
          flags=TYPE_DWORD,
          value=targets[offsetIndex],
        }
      end
    end
    return rollback
  end

  local function requireOwnedCodecWrites(originals, expected, label)
    if #originals ~= #expected then
      error((label or "加密字段") .. "回滚快照数量不一致", 0)
    end
    for index, original in ipairs(originals) do
      local target = expected[index]
      if not target or target.address ~= original.address then
        error((label or "加密字段") .. "回滚地址不一致", 0)
      end
    end
    if originals.rawOriginal and originals.rawExpected then
      requireOwnedRawWrites(
        originals.rawOriginal, originals.rawExpected,
        label or "加密字段回滚"
      )
      return true
    end
    for index, original in ipairs(originals) do
      local current = Codec.decode(original.address)
      if not sameU32(current, original.value) and
         not sameU32(current, expected[index].value) then
        error((label or "加密字段") ..
          "已被游戏或其他操作更新，拒绝覆盖回滚", 0)
      end
    end
    return true
  end

  local function restoreCodecRollback(rollback, label)
    if not rollback.rawOriginal then
      error((label or "加密字段") .. "缺少原始字回滚快照", 0)
    end
    Memory.writeMany(rollback.rawOriginal)
    verifyRawWrites(rollback.rawOriginal, (label or "加密字段") .. "原始字")
    verifyCodecWrites(rollback, label or "加密字段回滚")
  end

  local function writeCodecTransactional(
    writes, label, precommitValidator, rollbackIdentityValidator, onCaptured
  )
    if #writes == 0 then return true, {} end
    local rollback = captureCodecTransaction(writes)
    rollbackIdentityValidator = rollbackIdentityValidator or precommitValidator

    runWithTargetPaused(label or "加密字段写入", function()
      local precommitOk, precommitProblem = xpcall(function()
        if type(precommitValidator) == "function" then precommitValidator() end
        requireRawWritesOriginal(
          rollback.rawOriginal, (label or "加密字段") .. "提交"
        )
      end, traceback)
      if not precommitOk then
        error((label or "加密字段写入") .. "提交前验证失败：" ..
              tostring(precommitProblem), 0)
      end
      if type(onCaptured) == "function" then onCaptured(rollback) end

      local ok, problem = xpcall(function()
        Memory.writeMany(rollback.rawExpected)
        verifyRawWrites(rollback.rawExpected, label)
        verifyCodecWrites(writes, label)
      end, traceback)
      if ok then return true end

      local rollbackOk, rollbackProblem = pcall(function()
        if type(rollbackIdentityValidator) == "function" then
          rollbackIdentityValidator()
        end
        requireOwnedCodecWrites(
          rollback, writes, (label or "加密字段") .. "回滚"
        )
        if type(rollbackIdentityValidator) == "function" then
          rollbackIdentityValidator()
        end
        requireOwnedCodecWrites(
          rollback, writes, (label or "加密字段") .. "回滚复验"
        )
        restoreCodecRollback(rollback, (label or "加密字段") .. "回滚")
      end)
      if not rollbackOk then
        error(string.format("%s失败：%s；回滚失败：%s",
          label or "加密字段写入", tostring(problem),
          tostring(rollbackProblem)), 0)
      end
      error((label or "加密字段写入") .. "失败并已回滚：" ..
            tostring(problem), 0)
    end)
    return true, rollback
  end

  local function readPetBookSnapshot()
    Memory.refreshRanges()
    local base = Memory.resolve(
      gameBase(), requirePath("奇闻录宠物"), BOOK_SLOTS * 8
    )
    local requests = {}
    for index = 1, BOOK_SLOTS do
      requests[index] = {
        address=base + (index - 1) * 8,
        flags=TYPE_QWORD,
      }
    end
    local values = Memory.readMany(requests)
    local snapshot = {base=base, slots={}, entries={}}
    local ownerRequests, occupied = {}, {}
    for index, value in ipairs(values) do
      local raw = tonumber(value.value)
      snapshot.slots[index] = raw
      local address = raw and untagPointer(raw) or 0
      if address ~= 0 and Memory.isMapped(address + OFFSET.bookOwner, 8) then
        ownerRequests[#ownerRequests + 1] = {
          address=address + OFFSET.bookOwner, flags=TYPE_QWORD,
        }
        occupied[#occupied + 1] = {index=index, raw=raw, address=address}
      end
    end
    local ownerValues = #ownerRequests > 0 and
      Memory.readMany(ownerRequests) or {}
    local nameRequests, named = {}, {}
    for position, slot in ipairs(occupied) do
      local ownerRaw = ownerValues[position].value
      local owner = tonumber(ownerRaw) and untagPointer(ownerRaw) or 0
      if owner ~= 0 and Memory.isMapped(owner + OFFSET.bookName, 8) then
        slot.owner = owner
        nameRequests[#nameRequests + 1] = {address=owner + OFFSET.bookName}
        named[#named + 1] = slot
      end
    end
    local names = Memory.readStrings(nameRequests, 128)
    for position, slot in ipairs(named) do
      local name = names[position]
      if name ~= "" then
        local entry = {
          slotIndex=slot.index,
          slotAddress=requests[slot.index].address,
          petRaw=slot.raw,
          petAddress=slot.address,
          ownerAddress=slot.owner,
          name=name,
        }
        snapshot.entries[#snapshot.entries + 1] = entry
        snapshot[slot.index] = entry
      end
    end
    if #snapshot.entries == 0 then
      error("奇闻录宠物尚未加载，请打开奇闻录", 0)
    end
    return snapshot
  end

  local function sameBookEntry(a, b)
    return a ~= nil and b ~= nil and a.slotAddress == b.slotAddress and
      a.petRaw == b.petRaw and a.petAddress == b.petAddress and
      a.ownerAddress == b.ownerAddress and a.name == b.name
  end

  local function sameRecordedEntries(current, recorded)
    for _, old in ipairs(recorded) do
      if not sameBookEntry(current[old.slotIndex], old) then return false end
    end
    return true
  end

  local function bookSnapshotsEqual(left, right)
    if left.base ~= right.base then return false end
    for index = 1, BOOK_SLOTS do
      if left.slots[index] ~= right.slots[index] then return false end
      local a, b = left[index], right[index]
      if (a or b) and not sameBookEntry(a, b) then return false end
    end
    return true
  end

  local function validateBookEntries(snapshot, selected)
    local current = readPetBookSnapshot()
    if not bookSnapshotsEqual(snapshot, current) then
      return nil, "奇闻录 110 槽目录在操作期间发生变化"
    end
    if selected and not sameRecordedEntries(current, selected) then
      return nil, "所选奇闻录宠物身份已经变化"
    end
    return current
  end

  local function requireBookEntries(snapshot, selected)
    local current, problem = validateBookEntries(snapshot, selected)
    if not current then error(problem, 0) end
    return current
  end

  local function requireCapturedBookPets(entries, label)
    if type(entries) ~= "table" or #entries == 0 then
      error((label or "奇闻录宠物") .. "记录为空", 0)
    end
    local prefixes, ownerRequests = {}, {}
    for index, entry in ipairs(entries) do
      if type(entry) ~= "table" then
        error((label or "奇闻录宠物") .. "记录无效", 0)
      end
      prefixes[index] = string.format("%s第%d只", label or "奇闻录宠物", index)
      local petAddress = requireMapped(
        entry.petAddress, OFFSET.bookOwner + 8, prefixes[index] .. "对象"
      )
      ownerRequests[index] = {
        address=petAddress + OFFSET.bookOwner, flags=TYPE_QWORD,
      }
    end
    local owners = Memory.readMany(ownerRequests)
    local nameRequests = {}
    for index, entry in ipairs(entries) do
      local owner = untagPointer(owners[index].value)
      if owner ~= entry.ownerAddress then
        error(prefixes[index] .. "所有者已经变化", 0)
      end
      requireMapped(owner + OFFSET.bookName, 8, prefixes[index] .. "名称字段")
      nameRequests[index] = {address=owner + OFFSET.bookName}
    end
    local names = Memory.readStrings(nameRequests, 128)
    for index, entry in ipairs(entries) do
      if names[index] == "" or names[index] ~= entry.name then
        error(prefixes[index] .. "名称已经变化", 0)
      end
    end
    return true
  end

  local function validateRecordedBookPets(recorded)
    if type(recorded) ~= "table" or #recorded == 0 then
      return nil, "尚未记录奇闻录宠物"
    end
    local chainOk, current = pcall(readPetBookSnapshot)
    if not chainOk then
      local capturedOk, capturedProblem = pcall(
        requireCapturedBookPets, recorded, "已记录奇闻录宠物"
      )
      if not capturedOk then
        return nil, "奇闻录目录已卸载，且已记录对象也失效：" ..
          tostring(capturedProblem)
      end
      trace("pet book chain unloaded; validated captured objects: " ..
            tostring(current))
      return {capturedOnly=true, chainProblem=tostring(current)}
    end
    if not sameRecordedEntries(current, recorded) then
      return nil, "已记录的奇闻录宠物身份已变化，记录已清空"
    end
    return current
  end

  local function rawValueMatches(flags, actual, first, second)
    if flags == TYPE_QWORD then
      local current = nullablePointer(actual, "QWORD 所有权")
      return current == nullablePointer(first, "QWORD 原值") or
             current == nullablePointer(second, "QWORD 目标值")
    end
    return sameU32(actual, first) or sameU32(actual, second)
  end

  requireRawWritesOriginal = function(originals, label)
    local requests = {}
    for index, original in ipairs(originals) do
      requests[index] = {
        address=original.address,
        flags=original.flags,
      }
    end
    local current = Memory.readMany(requests)
    for index, value in ipairs(current) do
      local original = originals[index]
      if not rawValueMatches(
        original.flags, value.value, original.value, original.value
      ) then
        error((label or "事务字段") ..
          "在提交前已被游戏或其他操作更新", 0)
      end
    end
    return true
  end

  requireOwnedRawWrites = function(originals, expected, label)
    if #originals ~= #expected then
      error((label or "事务字段") .. "回滚快照数量不一致", 0)
    end
    local requests = {}
    for index, original in ipairs(originals) do
      local target = expected[index]
      if not target or target.address ~= original.address or
         target.flags ~= original.flags then
        error((label or "事务字段") .. "回滚地址不一致", 0)
      end
      requests[index] = {address=original.address, flags=original.flags}
    end
    local current = Memory.readMany(requests)
    for index, value in ipairs(current) do
      local original, target = originals[index], expected[index]
      if not rawValueMatches(
        original.flags, value.value, original.value, target.value
      ) then
        error((label or "事务字段") ..
          "已被游戏或其他操作更新，拒绝覆盖回滚", 0)
      end
    end
  end

  local function readPetListIdentity()
    local logicalCapacity, managerAddress = Pet.readLogicalCapacity()
    local upperAddress = Memory.resolve(
      gameBase(), requirePath("宠物数量上层"), 24
    )
    local countAddress = Memory.resolve(
      gameBase(), requirePath("宠物数量"), 24
    )
    if Memory.pointer(upperAddress) ~= countAddress then
      error("宠物数量结构在读取期间发生变化", 0)
    end
    local header = Memory.readMany({
      {address=countAddress, flags=TYPE_DWORD},
      {address=countAddress + 4, flags=TYPE_DWORD},
      {address=countAddress + 16, flags=TYPE_QWORD},
    })
    local count = tonumber(header[1].value)
    local capacity = tonumber(header[2].value)
    local arrayAddress = untagPointer(header[3].value)
    if not count or count ~= math.floor(count) or
       count < 0 or count > logicalCapacity then
      error("当前宠物数量异常：" .. tostring(count), 0)
    end
    if not capacity or capacity ~= math.floor(capacity) or
       capacity < count or capacity > PHYSICAL_MAXIMUM then
      error(string.format(
        "当前宠物数组容量异常：数量 %s，容量 %s",
        tostring(count), tostring(capacity)
      ), 0)
    end
    return {
      upperAddress=upperAddress,
      countAddress=countAddress,
      arrayAddress=arrayAddress,
      count=count,
      capacity=capacity,
      logicalCapacity=logicalCapacity,
      managerAddress=managerAddress,
    }
  end

  local function readPlayerFollowTarget()
    local personPath = requirePath("人物基址")
    if type(personPath) ~= "table" or #personPath < 2 or
       personPath[#personPath] ~= 0 then
      error("人物基址路径无法定位原始指针槽", 0)
    end
    local pointerFieldPath = {}
    for index = 1, #personPath - 1 do
      pointerFieldPath[index] = personPath[index]
    end
    local pointerField = Memory.resolve(gameBase(), pointerFieldPath, 8)
    local raw = Memory.read(pointerField, TYPE_QWORD)
    local target = requireMapped(
      untagPointer(raw), 8, "宠物跟随人物目标"
    )
    if Memory.pointer(pointerField) ~= target then
      error("人物跟随目标在读取期间发生变化", 0)
    end
    return {
      pointerField=pointerField,
      raw=raw,
      target=target,
    }
  end

  local function requirePlayerFollowTarget(expected)
    local current = readPlayerFollowTarget()
    if current.pointerField ~= expected.pointerField or
       current.target ~= expected.target or
       tonumber(current.raw) ~= tonumber(expected.raw) then
      error("人物跟随目标已经变化", 0)
    end
    return current
  end

  local function requirePetListIdentity(snapshot, firstCount, secondCount)
    local live = readPetListIdentity()
    if live.upperAddress ~= snapshot.upperAddress or
       live.countAddress ~= snapshot.countAddress or
       live.arrayAddress ~= snapshot.arrayAddress or
       live.capacity ~= snapshot.capacity or
       live.logicalCapacity ~= snapshot.logicalCapacity or
       live.managerAddress ~= snapshot.managerAddress or
       (live.count ~= firstCount and live.count ~= secondCount) then
      error("宠物列表身份或数量已被游戏更新，拒绝覆盖回滚", 0)
    end
    return live
  end

  local function rollbackExternalAppend(snapshot, originals, expected)
    requirePetListIdentity(snapshot, originals.count, expected.count)
    requireOwnedRawWrites(
      originals.metadata, expected.metadata, "宠物追加元数据"
    )
    requireOwnedRawWrites(
      originals.slots, expected.slots, "宠物追加槽位"
    )
    requirePetListIdentity(snapshot, originals.count, expected.count)
    requireOwnedRawWrites(
      originals.metadata, expected.metadata, "宠物追加元数据复验"
    )
    requireOwnedRawWrites(
      originals.slots, expected.slots, "宠物追加槽位复验"
    )
    requireOwnedRawWrites(
      originals.references, expected.references, "宠物追加引用原始字"
    )
    requireOwnedRawWrites(
      originals.followTargets, expected.followTargets,
      "宠物追加跟随目标"
    )
    requirePetListIdentity(snapshot, originals.count, expected.count)
    Memory.write(snapshot.countAddress, originals.count, TYPE_DWORD)
    Memory.writeMany(originals.metadata)
    if #originals.slots > 0 then Memory.writeMany(originals.slots) end
    Memory.writeMany(originals.followTargets)
    Memory.writeMany(originals.references)

    if tonumber(Memory.read(snapshot.countAddress, TYPE_DWORD)) ~=
       originals.count then
      error("外部宠物追加数量回滚验证失败", 0)
    end
    verifyRawWrites(originals.metadata, "外部宠物元数据回滚")
    if #originals.slots > 0 then
      verifyRawWrites(originals.slots, "外部宠物槽位回滚")
    end
    verifyRawWrites(originals.followTargets, "宠物追加跟随目标回滚")
    verifyExactQwordWrites(
      originals.followTargets, "宠物追加跟随目标回滚"
    )
    verifyRawWrites(originals.references, "外部宠物引用原始字回滚")
  end

  local function appendExternalPets(externalPets, precommitValidator)
    if type(externalPets) ~= "table" or #externalPets == 0 then
      return nil, "没有可追加的外部宠物"
    end
    local pointers, rawPointers = {}, {}
    local referenceOccurrences = {}
    for index, entry in ipairs(externalPets) do
      local value = type(entry) == "table" and entry.petAddress or entry
      local petAddress = requireMapped(value,
        requireField("宠物状态") + 4, "第 " .. index .. " 个外部宠物")
      local raw = type(entry) == "table" and entry.petRaw or value
      if type(raw) ~= "number" or raw ~= math.floor(raw) or
         untagPointer(raw) ~= petAddress then
        error("第 " .. index .. " 个外部宠物原始指针无效", 0)
      end
      pointers[index] = petAddress
      rawPointers[index] = raw
      referenceOccurrences[petAddress] =
        (referenceOccurrences[petAddress] or 0) + 1
    end

    local snapshot = Pet.readStableSnapshot()
    local targetCount = snapshot.count + #pointers
    if targetCount > snapshot.logicalCapacity then
      return nil, string.format(
        CAPACITY_NOTICE_PREFIX ..
        "宠物背包上限为 %d，已有 %d，本次最多还能新增 %d",
        snapshot.logicalCapacity, snapshot.count,
        snapshot.logicalCapacity - snapshot.count
      )
    end
    local current, validationProblem = Pet.validateSnapshot(snapshot, nil, nil)
    if not current then return nil, validationProblem end
    snapshot = current
    local expanded, expansionProblem = Pet.ensureAppendCapacity(
      snapshot, nil, targetCount, nil
    )
    if not expanded then
      return nil, CAPACITY_NOTICE_PREFIX .. tostring(expansionProblem)
    end
    snapshot = expanded

    local destination = snapshot.arrayAddress + snapshot.count * 8
    if snapshot.arrayAddress == 0 or
       not Memory.isMapped(destination, #pointers * 8, true) then
      return nil, "外部宠物目标槽位范围无效"
    end
    if not Memory.isMapped(snapshot.upperAddress + 8, 16) or
       not Memory.isMapped(snapshot.countAddress, 16) then
      return nil, "宠物数量元数据范围无效"
    end

    local slotRequests = {}
    for index = 1, #pointers do
      slotRequests[index] = {
        address=destination + (index - 1) * 8,
        flags=TYPE_QWORD,
      }
    end
    local slotValues = Memory.readMany(slotRequests)
    local originals = {
      count=snapshot.count,
      slots={},
      metadata={},
      references={},
      followTargets={},
    }
    for index, value in ipairs(slotValues) do
      originals.slots[index] = {
        address=slotRequests[index].address,
        flags=TYPE_QWORD,
        value=value.value,
      }
    end

    local metadataRequests = {
      {address=snapshot.upperAddress + 8, flags=TYPE_DWORD},
      {address=snapshot.upperAddress + 12, flags=TYPE_DWORD},
      {address=snapshot.upperAddress + 16, flags=TYPE_QWORD},
    }
    for offset = 8, 12, 4 do
      metadataRequests[#metadataRequests + 1] = {
        address=snapshot.countAddress + offset,
        flags=TYPE_DWORD,
      }
    end
    local metadataValues = Memory.readMany(metadataRequests)
    for index, value in ipairs(metadataValues) do
      originals.metadata[index] = {
        address=metadataRequests[index].address,
        flags=metadataRequests[index].flags,
        value=value.value,
      }
    end

    local referenceRequests = {}
    for petAddress in pairs(referenceOccurrences) do
      requireMapped(
        petAddress + OFFSET.referenceWord, 4, "外部宠物引用原始字"
      )
      referenceRequests[#referenceRequests + 1] = {
        address=petAddress + OFFSET.referenceWord,
        flags=TYPE_DWORD,
        petAddress=petAddress,
      }
    end
    table.sort(referenceRequests, function(left, right)
      return left.address < right.address
    end)
    local referenceValues = Memory.readMany(referenceRequests)
    local referenceWrites = {}
    for index, value in ipairs(referenceValues) do
      local request = referenceRequests[index]
      local original = tonumber(value.value) & U32_MASK
      local increase = referenceOccurrences[request.petAddress]
      if original + increase > U32_MASK then
        return nil, string.format(
          "第 0x%X 个外部宠物引用原始字即将溢出：0x%X + %d",
          request.petAddress, original, increase
        )
      end
      originals.references[index] = {
        address=request.address,
        flags=TYPE_DWORD,
        value=original,
      }
      referenceWrites[index] = {
        address=request.address,
        flags=TYPE_DWORD,
        value=original + increase,
      }
    end

    local playerTarget = readPlayerFollowTarget()
    local followTargetRequests, followTargetWrites = {}, {}
    for index, request in ipairs(referenceRequests) do
      followTargetRequests[index] = {
        address=request.petAddress + OFFSET.followTarget,
        flags=TYPE_QWORD,
      }
    end
    local followTargetValues = Memory.readMany(followTargetRequests)
    for index, value in ipairs(followTargetValues) do
      originals.followTargets[index] = {
        address=followTargetRequests[index].address,
        flags=TYPE_QWORD,
        value=value.value,
      }
      followTargetWrites[index] = {
        address=followTargetRequests[index].address,
        flags=TYPE_QWORD,
        value=playerTarget.raw,
      }
    end

    local newCount = snapshot.count + #pointers
    local slotWrites = {}
    for index, petRaw in ipairs(rawPointers) do
      slotWrites[index] = {
        address=destination + (index - 1) * 8,
        flags=TYPE_QWORD,
        value=petRaw,
      }
    end
    local metadataWrites = {
      {address=snapshot.upperAddress + 8, flags=TYPE_DWORD, value=0},
      {address=snapshot.upperAddress + 12, flags=TYPE_DWORD, value=0},
      {address=snapshot.upperAddress + 16, flags=TYPE_QWORD, value=0},
    }
    metadataWrites[#metadataWrites + 1] = {
      address=snapshot.countAddress + 8,
      flags=TYPE_DWORD,
      value=0,
    }
    metadataWrites[#metadataWrites + 1] = {
      address=snapshot.countAddress + 12,
      flags=TYPE_DWORD,
      value=newCount,
    }

    local expected = {
      count=newCount,
      slots=slotWrites,
      metadata=metadataWrites,
      references=referenceWrites,
      followTargets=followTargetWrites,
    }
    local writeStarted = false
    local ok, problem = xpcall(function()
      local last, changed = Pet.validateSnapshot(snapshot, nil, nil)
      if not last then error(changed, 0) end
      if type(precommitValidator) == "function" then
        precommitValidator()
      end
      requirePetListIdentity(snapshot, originals.count, originals.count)
      requireRawWritesOriginal(originals.slots, "宠物追加目标槽位")
      requireRawWritesOriginal(originals.metadata, "宠物追加元数据")
      requireRawWritesOriginal(originals.references, "宠物追加引用原始字")
      requireRawWritesOriginal(
        originals.followTargets, "宠物追加跟随目标"
      )
      requirePlayerFollowTarget(playerTarget)
      writeStarted = true
      Memory.writeMany(followTargetWrites)
      verifyExactQwordWrites(followTargetWrites, "外部宠物跟随目标")
      Memory.writeMany(referenceWrites)
      verifyRawWrites(referenceWrites, "外部宠物引用原始字")
      Memory.writeMany(slotWrites)
      Memory.writeMany(metadataWrites)
      Memory.write(snapshot.countAddress, newCount, TYPE_DWORD)

      verifyExactQwordWrites(slotWrites, "外部宠物槽位")
      verifyRawWrites(slotWrites, "外部宠物槽位")
      verifyRawWrites(metadataWrites, "外部宠物元数据")
      verifyRawWrites(referenceWrites, "外部宠物引用原始字")
      verifyRawWrites(followTargetWrites, "外部宠物跟随目标")
      verifyExactQwordWrites(followTargetWrites, "外部宠物跟随目标")
      if tonumber(Memory.read(snapshot.countAddress, TYPE_DWORD)) ~= newCount then
        error("外部宠物数量写后验证失败", 0)
      end
      local fresh = Pet.readStableSnapshot()
      if fresh.count ~= newCount or fresh.arrayAddress ~= snapshot.arrayAddress then
        error("外部宠物追加后的稳定快照不一致", 0)
      end
      for index, expected in ipairs(pointers) do
        local pet = fresh.pets[snapshot.count + index]
        if not pet or pet.petAddress ~= expected then
          error("外部宠物追加后的槽位身份不一致", 0)
        end
      end
    end, traceback)
    if ok then
      for index, request in ipairs(referenceRequests) do
        trace(string.format(
          "external retain pet=0x%X old=%s add=%d new=%s",
          request.petAddress,
          tostring(originals.references[index].value),
          referenceOccurrences[request.petAddress],
          tostring(referenceWrites[index].value)
        ))
      end
      trace(string.format(
        "external pet follow target=0x%X raw=%s count=%d",
        playerTarget.target, tostring(playerTarget.raw),
        #followTargetWrites
      ))
      trace(string.format("external pets appended old=%d add=%d new=%d",
        snapshot.count, #pointers, newCount))
      return true, newCount
    end
    if not writeStarted then
      return nil, "外部宠物追加提交前验证失败：" .. tostring(problem)
    end

    local rollbackOk, rollbackProblem = pcall(
      rollbackExternalAppend, snapshot, originals, expected
    )
    if not rollbackOk then
      return nil, string.format("外部宠物追加失败：%s；回滚失败：%s",
        tostring(problem), tostring(rollbackProblem))
    end
    return nil, "外部宠物追加失败并已回滚：" .. tostring(problem)
  end

  local actions = {}

  local function readAvailablePetSlots()
    local snapshot = Pet.readStableSnapshot()
    local remaining = snapshot.logicalCapacity - snapshot.count
    if remaining < 0 then
      error("宠物数组数量超过真实容量", 0)
    end
    return snapshot, remaining
  end

  local function filterBookEntries(entries, keyword)
    if type(entries) ~= "table" then
      error("宠物检索目录无效", 0)
    end
    keyword = tostring(keyword or "")
    keyword = keyword:match("^%s*(.-)%s*$") or ""
    if keyword == "" then return entries end

    local filtered = {}
    for _, entry in ipairs(entries) do
      if type(entry.name) == "string" and
         entry.name:find(keyword, 1, true) then
        filtered[#filtered + 1] = entry
      end
    end
    return filtered
  end

  function actions.huoquchong()
    local _, available = readAvailablePetSlots()
    local recordLimit = available - #state.recordedBookPets
    if recordLimit <= 0 then
      gg.alert(string.format(
        "安全拦截：当前宠物数组没有可追加槽位。\n" ..
        "本轮已记录 %d 只；本次没有写入。",
        #state.recordedBookPets
      ))
      return false
    end
    local snapshot = readPetBookSnapshot()
    local browseMode = gg.choice(
      {"📋 完整宠物列表（原方式）", "🔎 按名称搜索"},
      1,
      "选择宠物目录打开方式"
    )
    if not browseMode then return false end

    local queryText = ""
    if browseMode == 2 then
      local query = gg.prompt(
        {"宠物名称搜索（留空显示全部）"},
        {""},
        {"text"}
      )
      if not query then return false end
      queryText = tostring(query[1] or "")
    end
    local visibleEntries = filterBookEntries(snapshot.entries, queryText)
    if #visibleEntries == 0 then
      gg.alert("没有找到名称包含“" .. queryText ..
               "”的宠物。")
      return false
    end
    local labels = {}
    for index, entry in ipairs(visibleEntries) do
      labels[index] = string.format("[%03d] %s", entry.slotIndex, entry.name)
    end
    local choices = gg.multiChoice(labels, nil, string.format(
      "%s：选择要从奇闻录追加的宠物（本轮最多再选 %d 只）",
      browseMode == 1 and "完整列表" or "搜索结果",
      recordLimit
    ))
    if not choices then return false end

    local selected = {}
    for index, entry in ipairs(visibleEntries) do
      if choices[index] then selected[#selected + 1] = entry end
    end
    if #selected == 0 then return false end
    if #selected > recordLimit then
      gg.alert(string.format(
        "安全拦截：本次选择 %d 只，但当前最多还能记录 %d 只。\n" ..
        "请重新检索并减少选择；本次没有记录或写入。",
        #selected, recordLimit
      ))
      return false
    end
    requireBookEntries(snapshot, selected)

    for _, entry in ipairs(selected) do
      state.recordedBookPets[#state.recordedBookPets + 1] = {
        slotIndex=entry.slotIndex,
        slotAddress=entry.slotAddress,
        petRaw=entry.petRaw,
        petAddress=entry.petAddress,
        ownerAddress=entry.ownerAddress,
        name=entry.name,
      }
    end
    gg.toast("本次记录 " .. #selected .. " 只，累计 " ..
             #state.recordedBookPets .. " 只宠物")
    return true
  end

  function actions.wuzhongchong()
    local _, problem = validateRecordedBookPets(state.recordedBookPets)
    if problem then
      state.recordedBookPets = {}
      error(problem, 0)
    end
    local operationOk, ok, result = xpcall(function()
      return appendExternalPets(state.recordedBookPets, function()
        local _, changed = validateRecordedBookPets(state.recordedBookPets)
        if changed then error(changed, 0) end
      end)
    end, traceback)
    if not operationOk or not ok then
      local appendProblem = operationOk and result or ok
      if operationOk and type(appendProblem) == "string" and
         appendProblem:sub(1, #CAPACITY_NOTICE_PREFIX) ==
           CAPACITY_NOTICE_PREFIX then
        gg.alert(appendProblem ..
        "\n\n本次没有写入。")
        return false
      end
      error("无中追加失败：" .. tostring(appendProblem), 0)
    end
    state.recordedBookPets = {}
    gg.toast("无中完成，当前宠物数量：" .. result)
    return true
  end

  local CLONE_VECTOR = {skills=656, nirvana=680}

  local function readCodecVector(owner, label)
    local values = Memory.readMany({
      {address=owner, flags=TYPE_QWORD},
      {address=owner + 8, flags=TYPE_QWORD},
    })
    local first = untagPointer(values[1].value)
    local finish = untagPointer(values[2].value)
    if first == 0 then return {first=0, count=0} end
    if finish < first or (finish - first) % 12 ~= 0 or
       (finish - first) // 12 > 64 then
      error(label .. "容器异常", 0)
    end
    requireMapped(first, math.max(finish - first, 12), label)
    return {first=first, count=(finish - first) // 12}
  end

  local function cloneFieldPlan(sourcePet, targetPet)
    local stateOffset = requireField("宠物状态")
    local levelBack = requireField("宠物等级")
    local sourceState = sourcePet + stateOffset
    local targetState = targetPet + stateOffset
    local pairs_ = {
      {sourceState - levelBack, targetState - levelBack},
      {sourceState + 368, targetState + 368},
    }
    for index = 0, 3 do
      pairs_[#pairs_ + 1] = {sourceState + 200 + index * 12,
        targetState + 200 + index * 12}
    end
    for index = 0, 2 do
      pairs_[#pairs_ + 1] = {sourceState + 296 + index * 12,
        targetState + 296 + index * 12}
    end
    local notes = {}
    for name, offset in pairs(CLONE_VECTOR) do
      local label = name == "skills" and "宠物技能" or "宠物涅槃"
      local from = readCodecVector(sourceState + offset, "原" .. label)
      local to = readCodecVector(targetState + offset, "新" .. label)
      local count = math.min(from.count, to.count)
      for index = 0, count - 1 do
        pairs_[#pairs_ + 1] = {from.first + index * 12, to.first + index * 12}
      end
      if from.count > to.count then
        notes[#notes + 1] = string.format(
          "%s只复制前 %d 个（新宠物只有 %d 个槽）", label, count, to.count
        )
      end
    end
    local sources = {}
    for index, pair in ipairs(pairs_) do sources[index] = {address=pair[1]} end
    local decoded = Codec.decodeMany(sources)
    local writes = {}
    for index, pair in ipairs(pairs_) do
      writes[index] = {address=pair[2], value=decoded[index]}
    end
    return writes, notes
  end

  local function petListContains(snapshot, petAddress)
    for _, pet in ipairs(snapshot.pets) do
      if pet.petAddress == petAddress then return pet end
    end
    return nil
  end

  function actions.Division()
    local pets = Pet.readStableSnapshot()
    if #pets.pets == 0 then
      gg.toast("当前没有宠物")
      return false
    end
    local owners, ownerRequests = {}, {}
    for index, pet in ipairs(pets.pets) do
      ownerRequests[index] = {
        address=pet.petAddress + requireField("宠物指针"), flags=TYPE_QWORD,
      }
    end
    local ownerValues = Memory.readMany(ownerRequests)
    local nameRequests = {}
    for index, value in ipairs(ownerValues) do
      owners[index] = untagPointer(value.value)
      nameRequests[index] = {address=owners[index] + requireField("宠物名称")}
    end
    local names = Memory.readStrings(nameRequests, 64)
    local labels = {}
    for index, pet in ipairs(pets.pets) do
      labels[index] = string.format("%d. %s（%s）", index, names[index] ~= "" and
        names[index] or "未知", pet.state == 1 and "出战" or "休息")
    end
    local choice = gg.choice(labels, nil,
      "选择要裂变的宠物（需先打开奇闻录；每个物种只能多出一只）")
    if not choice then return false end
    local source = pets.pets[choice]
    local sourceOwner = owners[choice]

    local okBook, book = pcall(readPetBookSnapshot)
    if not okBook then
      gg.alert("请先打开奇闻录宠物页面后再裂变：" .. tostring(book))
      return false
    end
    local candidate
    for _, entry in ipairs(book.entries) do
      if entry.ownerAddress == sourceOwner and
         entry.petAddress ~= source.petAddress and
         not petListContains(pets, entry.petAddress) then
        candidate = entry
        break
      end
    end
    if not candidate then
      gg.alert(string.format(
        "奇闻录里没有可用的“%s”：该物种在奇闻录中只有一个对象，" ..
        "它已在宠物列表中（或就是原宠物本身）。本次没有写入。",
        names[choice]
      ))
      return false
    end

    local appendOk, ok, result = xpcall(function()
      return appendExternalPets({candidate}, function()
        requireBookEntries(book, {candidate})
      end)
    end, traceback)
    if not appendOk or not ok then
      error("裂变追加失败：" .. tostring(appendOk and result or ok), 0)
    end

    local after = Pet.readStableSnapshot()
    if not petListContains(after, candidate.petAddress) or
       not petListContains(after, source.petAddress) then
      error("裂变后宠物列表身份不一致，未复制属性", 0)
    end
    local writes, notes = cloneFieldPlan(source.petAddress, candidate.petAddress)
    Codec.writeVerified(writes, "裂变属性复制", function()
      local live = Pet.readStableSnapshot()
      if not petListContains(live, candidate.petAddress) or
         not petListContains(live, source.petAddress) then
        error("裂变复制期间宠物列表已经变化", 0)
      end
      return true
    end)
    trace(string.format("pet clone source=0x%X target=0x%X fields=%d count=%s",
      source.petAddress, candidate.petAddress, #writes, tostring(result)))
    local message = string.format(
      "裂变完成：新增一只“%s”，已复制等级/资质/根骨/阶数/涅槃/技能（%d 项）。" ..
      "当前宠物数量：%s", names[choice], #writes, tostring(result)
    )
    if #notes > 0 then message = message .. "\n" .. table.concat(notes, "；") end
    gg.alert(message)
    return true
  end

  local FULL_FUSION_PRESET = {504107, 504108, 1, 1, 1, 1, 1}

  local function buildFullFusionWrites(selected)
    if type(selected) ~= "table" or #selected == 0 then
      error("全融灵宠物选择为空", 0)
    end
    local stateOffset = requireField("宠物状态")
    local levelBackOffset = requireField("宠物等级")
    local nirvanaOffset = requireField("宠物涅槃")
    local writes, nirvanaOwners = {}, {}
    for _, entry in ipairs(selected) do
      if type(entry) ~= "table" then error("全融灵宠物记录无效", 0) end
      local stateAddress = entry.petAddress + stateOffset
      requireMapped(stateAddress, 4, "全融灵宠物状态")
      writes[#writes + 1] = {
        address=stateAddress - levelBackOffset,
        value=75,
      }
      local nirvana = Memory.pointer(stateAddress + nirvanaOffset)
      requireMapped(nirvana, (#FULL_FUSION_PRESET - 1) * 12 + 12,
                    "全融灵宠物涅槃数组")
      nirvanaOwners[#nirvanaOwners + 1] = {
        field=stateAddress + nirvanaOffset,
        address=nirvana,
      }
      for index, value in ipairs(FULL_FUSION_PRESET) do
        writes[#writes + 1] = {
          address=nirvana + (index - 1) * 12,
          value=value,
        }
      end
    end
    return writes, nirvanaOwners
  end

  function actions.quanrongling()
    local wantedNames = {
      "龙马虎虎", "白虎战神", "极寒天马", "青龙妖圣",
      "烈焰金刚", "朱雀巫女", "吟风翥鸾", "玄武大帝",
      "青龙邪君", "白虎邪君", "玲珑兔", "机械绵羊X",
    }
    local petSnapshot, remainingCapacity = readAvailablePetSlots()
    if remainingCapacity == 0 then
      gg.alert(
        "安全拦截：当前宠物数组已满，没有可追加槽位。\n" ..
        "本次没有修改全融灵字段，也没有写入宠物数组。"
      )
      return false
    end
    local snapshot = readPetBookSnapshot()
    local options = {
      "四宠套组（白虎战神/白虎邪君/极寒天马/青龙妖圣）",
    }
    for _, name in ipairs(wantedNames) do
      options[#options + 1] = name
    end
    local defaults = remainingCapacity >= 4 and {[1]=true} or {}
    local choices = gg.multiChoice(options, defaults, string.format(
      "全融灵：当前 %d/%d，最多追加 %d 只；" ..
      "剩余不足 4 时请单选具体宠物",
      petSnapshot.count, petSnapshot.logicalCapacity, remainingCapacity
    ))
    if not choices then return false end
    requireBookEntries(snapshot, nil)

    local wanted = {}
    if choices[1] then
      wanted["白虎战神"] = true
      wanted["白虎邪君"] = true
      wanted["极寒天马"] = true
      wanted["青龙妖圣"] = true
    end
    for index, name in ipairs(wantedNames) do
      if choices[index + 1] then wanted[name] = true end
    end
    if not next(wanted) then return false end

    local current = requireBookEntries(snapshot, nil)
    local selected = {}
    for _, entry in ipairs(current.entries) do
      if wanted[entry.name] then selected[#selected + 1] = entry end
    end
    if #selected == 0 then
      error("奇闻录中没有加载所选全融灵宠物", 0)
    end
    requireBookEntries(current, selected)

    local currentPets, petProblem = Pet.validateSnapshot(
      petSnapshot, nil, nil
    )
    if not currentPets then
      gg.alert("宠物列表已变化，请重新打开全融灵：" ..
               tostring(petProblem))
      return false
    end
    remainingCapacity = currentPets.logicalCapacity - currentPets.count
    if #selected > remainingCapacity then
      gg.alert(string.format(
        "安全拦截：本次选择 %d 只，但宠物背包最多还能追加 %d 只。\n" ..
        "请重新执行并减少选择；本次没有修改任何宠物字段。",
        #selected, remainingCapacity
      ))
      trace(string.format(
        "full fusion capacity preflight selected=%d count=%d capacity=%d",
        #selected, currentPets.count, currentPets.capacity
      ))
      return false
    end
    local expandedPets, expansionProblem = Pet.ensureAppendCapacity(
      currentPets, nil, currentPets.count + #selected, nil
    )
    if not expandedPets then
      gg.alert(
        "安全拦截：宠物数组真实扩容失败：" ..
        tostring(expansionProblem) .. "\n本次没有修改宠物字段。"
      )
      return false
    end
    petSnapshot = expandedPets

    local writes, nirvanaOwners = buildFullFusionWrites(selected)

    local fieldRollback
    local function validateSelectedAndNirvana()
      requireCapturedBookPets(selected, "所选全融灵宠物")
      for _, owner in ipairs(nirvanaOwners) do
        if Memory.pointer(owner.field) ~= owner.address then
          error("全融灵宠物涅槃子对象已经变化", 0)
        end
      end
      return true
    end
    local operationOk, appendOk, appendResult = xpcall(function()
      validateSelectedAndNirvana()
      local _, captured = writeCodecTransactional(
        writes,
        "全融灵已确认字段",
        validateSelectedAndNirvana,
        validateSelectedAndNirvana
      )
      fieldRollback = captured
      validateSelectedAndNirvana()
      return appendExternalPets(selected, function()
        validateSelectedAndNirvana()
      end)
    end, traceback)
    if not operationOk or not appendOk then
      local rollbackProblems = {}
      if fieldRollback then
        local fieldOk, fieldProblem = pcall(
          runWithTargetPaused, "全融灵字段回滚", function()
            validateSelectedAndNirvana()
            requireOwnedCodecWrites(
              fieldRollback, writes, "全融灵字段回滚"
            )
            restoreCodecRollback(fieldRollback, "全融灵字段回滚")
          end
        )
        if not fieldOk then
          rollbackProblems[#rollbackProblems + 1] =
            "字段：" .. tostring(fieldProblem)
        end
      end
      local appendProblem = operationOk and appendResult or appendOk
      if #rollbackProblems > 0 then
        error(string.format("全融灵追加失败：%s；事务回滚失败：%s",
          tostring(appendProblem), table.concat(rollbackProblems, "；")), 0)
      end
      if operationOk and type(appendProblem) == "string" and
         appendProblem:sub(1, #CAPACITY_NOTICE_PREFIX) ==
           CAPACITY_NOTICE_PREFIX then
        gg.alert(appendProblem ..
          "\n\n宠物字段已经恢复，本次没有追加宠物。请重新执行并减少选择。")
        return false
      end
      error("全融灵追加失败，已恢复初始化字段：" ..
            tostring(appendProblem), 0)
    end

    gg.toast(string.format(
      "全融灵完成：追加 %d 只；已跳过语义不明字段；当前数量 %d",
      #selected, appendResult
    ))
    return true
  end
  return {
    actions=actions,
    requireCapturedBookPets=requireCapturedBookPets,
    validateRecordedBookPets=validateRecordedBookPets,
    appendExternalPets=appendExternalPets,
    buildFullFusionWrites=buildFullFusionWrites,
    filterBookEntries=filterBookEntries,
  }
end)

local function validateMenuRegistry()
  for menuName, menu in pairs(menus) do
    for index, item in ipairs(menu.items) do
      if item.menu and not menus[item.menu] then
        error(string.format(
          "菜单 %s 第 %d 项引用不存在的菜单 %s",
          menuName, index, tostring(item.menu)
        ), 0)
      end
      if item.action and type(actions[item.action]) ~= "function" then
        error(string.format(
          "菜单 %s 第 %d 项缺少功能 %s",
          menuName, index, tostring(item.action)
        ), 0)
      end
    end
  end
end

local showMenuByName
showMenuByName = function(menuName)
  local menu = menus[menuName]
  if not menu then error("菜单不存在：" .. tostring(menuName), 0) end
  local labels, callbacks = {}, {}
  for index, item in ipairs(menu.items) do
    labels[index] = item[1]
    if item.menu then
      local targetMenu = item.menu
      callbacks[index] = function()
        showMenuByName(targetMenu)
      end
    else
      local targetAction = item.action
      callbacks[index] = function()
        return actions[targetAction]()
      end
    end
  end
  local owner = function() showMenuByName(menuName) end
  showMenu(owner, menu.title, labels, callbacks, menu.multiple == true)
end

actions.quit = function()
  runtime.running = false
  gg.toast("脚本已退出")
end

local function mainLoop()
  runtime.running = true
  for _, hook in ipairs(app.startupHooks) do
    local ok, problem = pcall(hook)
    if not ok then trace("startup hook failed: " .. tostring(problem)) end
  end
  showMenuByName("Main")
  if not runtime.running then
    if type(app.cleanupOwnedFreezes) == "function" then
      app.cleanupOwnedFreezes(true)
    end
    return
  end
  if not app.Listener or type(app.Listener.pollMenuVisibility) ~= "function" then
    error("统一监听模块尚未安装", 0)
  end
  local report = app.Listener.pollMenuVisibility({
    name="main_menu_visibility",
    intervalMs=100,
    suppressInitialVisible=true,
    stopOnError=true,
    onVisible=function()
      if not runtime.running then
        return app.Listener.stop("script_exit")
      end
      local menu = runtime.activeMenu or function()
        showMenuByName("Main")
      end
      menu()
      if not runtime.running then
        return app.Listener.stop("script_exit")
      end
    end,
    cleanup=function()
      if type(app.cleanupOwnedFreezes) == "function" then
        app.cleanupOwnedFreezes(true)
      end
    end,
  })
  if report.reason == "target_unavailable" then
    runtime.running = false
    if report.cleanupError then
      trace("target exit cleanup error: " .. tostring(report.cleanupError))
    end
    gg.toast("游戏进程已退出，脚本已自动关闭")
    return
  end
  if report.cleanupError then
    local listenerProblem = report.error or report.value or report.reason
    if report.reason ~= "script_exit" and listenerProblem then
      error(
        "主菜单监听异常退出：" .. tostring(listenerProblem) ..
        "；同时清理冻结项失败：" .. report.cleanupError,
        0
      )
    end
    error("脚本退出时清理冻结项失败：" .. report.cleanupError, 0)
  end
  if report.reason ~= "script_exit" then
    error("主菜单监听异常退出：" .. tostring(
      report.error or report.value or report.reason
    ), 0)
  end
end

validateMenuRegistry()
initializeRuntime()
local runOk, runProblem = xpcall(mainLoop, function(problem)
  return tostring(problem)
end)
if runtime.traceFile then
  pcall(function() runtime.traceFile:flush() end)
  pcall(function() runtime.traceFile:close() end)
  runtime.traceFile = nil
end
if not runOk then error(runProblem, 0) end
