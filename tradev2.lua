--[[
  Steal A Brainrot - Player-to-player auto-trade script (executor)
  Run in a Roblox executor (e.g. Synapse, KRNL).
  Features: whitelist auto-accept, show other player's add/remove, optional auto-offer/ready/accept.
]]

-- ============== CONFIG ==============
local CONFIG = {
  -- Only auto-accept invites from these Roblox usernames (strings).
  -- Example: { "FriendName", "AnotherFriend" } (usernames, not display names)
  WHITELIST_USERNAMES = { "SesaPingge" },

  -- What to offer: "none" | "all" | number (first N brainrots)
  AUTO_OFFER = "none",

  AUTO_READY_AFTER_OFFER = false,
  AUTO_ACCEPT_WHEN_BOTH_READY = false,

  ACTION_DELAY_SEC = 0.3,
  SHOW_OTHER_OFFER_CHANGES = true,

  -- On-screen notifications (recommended vs console spam)
  GUI_NOTIFICATIONS = true,
  GUI_MAX_LINES = 6,
  GUI_LINE_LIFETIME_SEC = 6,

  -- Optional: hook-based safety layer (auto-detect; falls back if unsupported)
  USE_HOOKS = true,
  HOOK_BLOCK_NON_WHITELIST_ACCEPT = true,
  HOOK_BLOCK_PREMATURE_READY_ACCEPT = true,
  HOOK_BLOCK_MANUAL_OFFER_CHANGES_WHEN_AUTO_OFFER_NONE = false,
}

-- Remote GUIDs (from game TradeController)
local ACCEPT_INVITE_GUID = "57624f2b-8aa9-4974-bb7a-08f058af33ef"
local ADD_BRAINROT_GUID = "6b5f15fb-5cb9-4d07-a031-bbff8e641eda"
local REMOVE_BRAINROT_GUID = "1a5f9c76-711f-4c90-8117-2ffd3fa21c6d"
local READY_GUID = "d73acf93-6f32-44df-b813-0f6b32c7afd9"
local ACCEPT_GUID = "918ee0f5-e98f-413f-b76e-baee47b021cb"

-- ============== GAME REFS ==============
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local Net, ReplicatorClient, Synchronizer
do
  local packages = ReplicatedStorage:WaitForChild("Packages", 10)
  if not packages then
    warn("[SAB AutoTrade] ReplicatedStorage.Packages not found. Is the game loaded?")
    return
  end
  local ok1, r1 = pcall(require, packages:WaitForChild("Net", 5))
  local ok2, r2 = pcall(require, packages:WaitForChild("ReplicatorClient", 5))
  local ok3, r3 = pcall(require, packages:WaitForChild("Synchronizer", 5))
  if not (ok1 and r1) then
    warn("[SAB AutoTrade] Failed to require Net:", r1)
    return
  end
  if not (ok2 and r2) then
    warn("[SAB AutoTrade] Failed to require ReplicatorClient:", r2)
    return
  end
  if not (ok3 and r3) then
    warn("[SAB AutoTrade] Failed to require Synchronizer:", r3)
    return
  end
  Net = r1
  ReplicatorClient = r2
  Synchronizer = r3
end

-- ============== REMOTES ==============
local CreateInvite = Net:RemoteEvent("TradeService/CreateInvite")
local AcceptInvite = Net:RemoteFunction("TradeService/AcceptInvite")
local AddBrainrot = Net:RemoteFunction("TradeService/AddBrainrot")
local RemoveBrainrot = Net:RemoteFunction("TradeService/RemoveBrainrot")
local ReadyEvent = Net:RemoteEvent("TradeService/Ready")
local AcceptEvent = Net:RemoteEvent("TradeService/Accept")

-- ============== HELPERS ==============
local function safeRequire(obj)
  if not obj then return nil end
  local ok, res = pcall(require, obj)
  if ok then return res end
  return nil
end

local function brainrotKey(entry)
  if type(entry) ~= "table" then return nil end
  return string.format("%s:%s:%s:%s",
    tostring(entry.UUID or ""),
    tostring(entry.Index or ""),
    tostring(entry.Mutation or ""),
    table.concat(entry.Traits or {}, ","))
end

local userIdToUsernameCache = {}

local function getUsernameFromUserId(userId)
  if type(userId) ~= "number" then return nil end
  if userIdToUsernameCache[userId] then return userIdToUsernameCache[userId] end

  -- Fast path: if they're in this server, use Player.Name
  local p = Players:GetPlayerByUserId(userId)
  if p and p.Name then
    userIdToUsernameCache[userId] = p.Name
    return p.Name
  end

  -- Fallback: resolve via Roblox API
  local ok, name = pcall(function()
    return Players:GetNameFromUserIdAsync(userId)
  end)
  if ok and type(name) == "string" then
    userIdToUsernameCache[userId] = name
    return name
  end
  return nil
end

local function isWhitelistedUsername(username)
  if type(username) ~= "string" then return false end
  for _, v in ipairs(CONFIG.WHITELIST_USERNAMES) do
    if type(v) == "string" and v == username then
      return true
    end
  end
  return false
end

local function delay(sec)
  if sec and sec > 0 then task.wait(sec) end
end

-- Best-effort mapping for nicer names in notifications
local AnimalsData = nil
do
  local datas = ReplicatedStorage:FindFirstChild("Datas")
  if datas then
    AnimalsData = safeRequire(datas:FindFirstChild("Animals"))
  end
end

local function brainrotDisplay(entryOrIndex)
  local idx = nil
  if type(entryOrIndex) == "table" then
    idx = entryOrIndex.Index
  else
    idx = entryOrIndex
  end
  if type(idx) ~= "string" then
    return tostring(idx or "???")
  end
  if type(AnimalsData) == "table" and type(AnimalsData[idx]) == "table" then
    return tostring(AnimalsData[idx].DisplayName or idx)
  end
  return idx
end

-- Simple on-screen notification queue (executor-safe)
local function makeNotifier()
  if not CONFIG.GUI_NOTIFICATIONS then
    return function(msg)
      print(msg)
    end
  end

  local gui = Instance.new("ScreenGui")
  gui.Name = "SAB_AutoTrade_GUI"
  gui.ResetOnSpawn = false
  gui.IgnoreGuiInset = true
  pcall(function()
    gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")
  end)

  local holder = Instance.new("Frame")
  holder.Name = "Holder"
  holder.BackgroundTransparency = 1
  holder.Size = UDim2.new(0, 420, 0, 240)
  holder.Position = UDim2.new(0, 12, 0.25, 0)
  holder.Parent = gui

  local layout = Instance.new("UIListLayout")
  layout.FillDirection = Enum.FillDirection.Vertical
  layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
  layout.VerticalAlignment = Enum.VerticalAlignment.Top
  layout.SortOrder = Enum.SortOrder.LayoutOrder
  layout.Padding = UDim.new(0, 6)
  layout.Parent = holder

  local lines = {}

  local function pushLine(text)
    local frame = Instance.new("Frame")
    frame.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
    frame.BackgroundTransparency = 0.25
    frame.BorderSizePixel = 0
    frame.Size = UDim2.new(1, 0, 0, 28)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(60, 60, 70)
    stroke.Thickness = 1
    stroke.Parent = frame

    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.new(1, -12, 1, 0)
    label.Position = UDim2.new(0, 6, 0, 0)
    label.Font = Enum.Font.Gotham
    label.TextSize = 14
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextColor3 = Color3.fromRGB(255, 255, 255)
    label.Text = tostring(text)
    label.Parent = frame

    frame.Parent = holder
    table.insert(lines, 1, frame)

    while #lines > (CONFIG.GUI_MAX_LINES or 6) do
      local old = table.remove(lines)
      if old then old:Destroy() end
    end

    task.delay(CONFIG.GUI_LINE_LIFETIME_SEC or 6, function()
      if frame and frame.Parent then
        frame:Destroy()
        for i = #lines, 1, -1 do
          if lines[i] == frame then
            table.remove(lines, i)
            break
          end
        end
      end
    end)
  end

  return function(msg)
    pushLine(msg)
  end
end

local notify = makeNotifier()

-- Track invites so hook-mode can decide whitelist on AcceptInvite calls
local pendingInvites = {}

-- Trade helpers used by automation and hook-mode gating
local function getTradeTables(tradeRep)
  if not tradeRep then return nil end
  local users = tradeRep:TryIndex({ "active", "data", "users" })
  local playersTbl = tradeRep:TryIndex({ "active", "data", "players" })
  if type(users) ~= "table" or type(playersTbl) ~= "table" then
    return nil
  end
  return users, playersTbl
end

local function getMyAndOtherIndex(tradeRep)
  local users, _ = getTradeTables(tradeRep)
  if not users then return nil end
  local myIdx, otherIdx, otherUid
  for idx, uid in pairs(users) do
    if uid == LocalPlayer.UserId then
      myIdx = idx
    else
      otherIdx = idx
      otherUid = uid
    end
  end
  return myIdx, otherIdx, otherUid
end

local function canReadyOrAccept(tradeRep)
  if not tradeRep then return false end
  local lastChange = tradeRep:TryIndex({ "active", "data", "lastChange" })
  local isProcessing = tradeRep:TryIndex({ "active", "data", "isProcessing" })
  local now = workspace:GetServerTimeNow()
  return type(lastChange) == "number" and (now >= lastChange + 5) and not isProcessing
end

-- ============== AUTO-ACCEPT (WHITELIST) ==============
CreateInvite.OnClientEvent:Connect(function(inviteId, inviteData)
  if type(inviteData) ~= "table" or not inviteData.from then return end
  local now = workspace:GetServerTimeNow()
  if inviteData.expires and now > inviteData.expires then return end
  pendingInvites[inviteId] = inviteData
  local fromUsername = getUsernameFromUserId(inviteData.from)
  if not fromUsername or not isWhitelistedUsername(fromUsername) then return end

  delay(CONFIG.ACTION_DELAY_SEC)
  local ok, err = pcall(function()
    AcceptInvite:InvokeServer(ACCEPT_INVITE_GUID, inviteId)
  end)
  if ok then
    notify(("[SAB] Auto-accepted trade from @%s"):format(fromUsername))
  else
    warn("[SAB AutoTrade] AcceptInvite failed:", err)
  end
end)

-- ============== TRADE STATE & OTHER PLAYER OFFER DIFF ==============
local tradeReplicator = ReplicatorClient.get("Trade_" .. tostring(LocalPlayer.UserId))
local previousOtherOfferKeys = {}
local currentTradeOtherIndex = nil
local currentOtherUsername = nil

tradeReplicator:ListenRaw(function(raw)
  if raw == nil then
    previousOtherOfferKeys = {}
    currentTradeOtherIndex = nil
    currentOtherUsername = nil
    return
  end

  local activeData = tradeReplicator:TryIndex({ "active", "data" })
  if not activeData then
    previousOtherOfferKeys = {}
    currentTradeOtherIndex = nil
    currentOtherUsername = nil
    return
  end

  local _, otherIndex, otherUserId = getMyAndOtherIndex(tradeReplicator)

  if not otherIndex then return end
  currentTradeOtherIndex = otherIndex
  currentOtherUsername = getUsernameFromUserId(otherUserId or -1)
  notify(("[SAB] Trade detected%s"):format(currentOtherUsername and (" with @"..currentOtherUsername) or ""))

  local _, players = getTradeTables(tradeReplicator)
  if not players then return end
  local otherPlayerData = players[otherIndex]
  if type(otherPlayerData) ~= "table" then return end
  local otherOffer = type(otherPlayerData.offer) == "table" and otherPlayerData.offer.brainrots or {}
  if type(otherOffer) ~= "table" then otherOffer = {} end

  -- Build initial snapshot of other's offer (Observe callback will do diff on subsequent changes)
  local newKeys = {}
  for _, entry in pairs(otherOffer) do
    if type(entry) == "table" then
      local k = brainrotKey(entry)
      if k then newKeys[k] = true end
    end
  end
  previousOtherOfferKeys = newKeys
end)

-- Observe players so we get updates when other offer changes
tradeReplicator:Observe({ "active", "data", "players" }, function(players)
  if type(players) ~= "table" or not currentTradeOtherIndex then return end
  local otherPlayerData = players[currentTradeOtherIndex]
  if type(otherPlayerData) ~= "table" then return end
  local otherOffer = type(otherPlayerData.offer) == "table" and otherPlayerData.offer.brainrots or {}
  if type(otherOffer) ~= "table" then otherOffer = {} end

  local newKeys = {}
  local newEntriesByKey = {}
  for _, entry in pairs(otherOffer) do
    if type(entry) == "table" then
      local k = brainrotKey(entry)
      if k then
        newKeys[k] = true
        newEntriesByKey[k] = entry
      end
    end
  end

  if CONFIG.SHOW_OTHER_OFFER_CHANGES and next(previousOtherOfferKeys) then
    for k in pairs(newKeys) do
      if not previousOtherOfferKeys[k] then
        local entry = newEntriesByKey[k]
        local name = brainrotDisplay(entry)
        notify(("[SAB] %sAdded: %s"):format(currentOtherUsername and ("@"..currentOtherUsername.." ") or "", name))
      end
    end
    for k in pairs(previousOtherOfferKeys) do
      if not newKeys[k] then
        local segs = {}
        for s in (k .. ":"):gmatch("(.-):") do table.insert(segs, s) end
        local idx = (segs[2] and segs[2] ~= "") and segs[2] or k
        notify(("[SAB] %sRemoved: %s"):format(currentOtherUsername and ("@"..currentOtherUsername.." ") or "", brainrotDisplay(idx)))
      end
    end
  end

  previousOtherOfferKeys = newKeys
end)

-- ============== OPTIONAL: LIVE TRADE AUTOMATION ==============
if CONFIG.AUTO_OFFER ~= "none" or CONFIG.AUTO_READY_AFTER_OFFER or CONFIG.AUTO_ACCEPT_WHEN_BOTH_READY then
  local sync = nil
  task.spawn(function()
    sync = Synchronizer:Wait(LocalPlayer)
  end)

  tradeReplicator:Observe({ "active", "data", "players" }, function(players)
    if type(players) ~= "table" or not sync then return end
    local users = tradeReplicator:TryIndex({ "active", "data", "users" })
    if type(users) ~= "table" then return end
    local myIndex
    for idx, uid in pairs(users) do
      if uid == LocalPlayer.UserId then myIndex = idx break end
    end
    if not myIndex then return end

    local myData = players[myIndex]
    if type(myData) ~= "table" then return end
    local myOffer = type(myData.offer) == "table" and myData.offer.brainrots or {}
    if type(myOffer) ~= "table" then myOffer = {} end
    local canReady = canReadyOrAccept(tradeReplicator)

    -- Auto-offer
    if CONFIG.AUTO_OFFER ~= "none" then
      local podiums = sync:Get("AnimalPodiums")
      if type(podiums) == "table" then
        local offeredKeys = {}
        for _, b in pairs(myOffer) do
          if type(b) == "table" then
            local k = brainrotKey(b)
            if k then offeredKeys[k] = true end
          end
        end
        local count = 0
        local limit = CONFIG.AUTO_OFFER == "all" and 999 or (type(CONFIG.AUTO_OFFER) == "number" and CONFIG.AUTO_OFFER or 0)
        for podiumIndex, entry in pairs(podiums) do
          if limit > 0 and count >= limit then break end
          if type(entry) == "table" and not entry.Machine then
            local k = brainrotKey(entry)
            if k and not offeredKeys[k] then
              delay(CONFIG.ACTION_DELAY_SEC)
              local ok, err = pcall(function()
                AddBrainrot:InvokeServer(ADD_BRAINROT_GUID, podiumIndex, entry)
              end)
              if ok then
                offeredKeys[k] = true
                count = count + 1
              else
                warn("[SAB AutoTrade] AddBrainrot failed:", err)
              end
            end
          end
        end
      end
    end

    -- Auto-ready
    if CONFIG.AUTO_READY_AFTER_OFFER and canReady and not myData.ready then
      delay(CONFIG.ACTION_DELAY_SEC)
      pcall(function()
        ReadyEvent:FireServer(READY_GUID)
      end)
    end

    -- Auto-accept when both ready
    if CONFIG.AUTO_ACCEPT_WHEN_BOTH_READY and not myData.accepted then
      local allReady = true
      for _, p in pairs(players) do
        if type(p) == "table" and not p.ready then allReady = false break end
      end
      if allReady and canReady then
        delay(CONFIG.ACTION_DELAY_SEC)
        pcall(function()
          AcceptEvent:FireServer(ACCEPT_GUID)
        end)
      end
    end
  end)
end

-- ============== OPTIONAL: HOOK SAFETY LAYER (AUTO-DETECT) ==============
do
  if CONFIG.USE_HOOKS then
    local env = (getfenv and getfenv()) or _G
    local hookNamecall = rawget(env, "hookmetamethod")
    local getNamecallMethod = rawget(env, "getnamecallmethod")
    local getRawMt = rawget(env, "getrawmetatable")

    if type(hookNamecall) ~= "function" or type(getNamecallMethod) ~= "function" or type(getRawMt) ~= "function" then
      notify("[SAB] Hooks unavailable (running no-hook mode)")
    else
      local mt = getRawMt(game)
      if not mt then
        notify("[SAB] Hooks unavailable (no raw metatable)")
      else
        local old
        old = hookNamecall(game, "__namecall", function(self, ...)
          local method = getNamecallMethod()
          local args = { ... }

          -- AcceptInvite gating
          if CONFIG.HOOK_BLOCK_NON_WHITELIST_ACCEPT and method == "InvokeServer" and self == AcceptInvite then
            local guid = args[1]
            local inviteId = args[2]
            if guid == ACCEPT_INVITE_GUID and inviteId ~= nil then
              local data = pendingInvites[inviteId]
              if type(data) == "table" and type(data.from) == "number" then
                local uname = getUsernameFromUserId(data.from)
                if not (uname and isWhitelistedUsername(uname)) then
                  notify(("[SAB] Blocked non-whitelist accept%s"):format(uname and (" (@" .. uname .. ")") or ""))
                  return false, "Blocked by SAB whitelist"
                end
              end
            end
          end

          -- Ready/Accept cooldown gating
          if CONFIG.HOOK_BLOCK_PREMATURE_READY_ACCEPT and method == "FireServer" then
            if self == ReadyEvent and args[1] == READY_GUID then
              if not canReadyOrAccept(tradeReplicator) then
                notify("[SAB] Blocked READY (cooldown)")
                return nil
              end
            elseif self == AcceptEvent and args[1] == ACCEPT_GUID then
              if not canReadyOrAccept(tradeReplicator) then
                notify("[SAB] Blocked ACCEPT (cooldown)")
                return nil
              end
            end
          end

          -- Offer change blocking when auto-offer is disabled
          if CONFIG.HOOK_BLOCK_MANUAL_OFFER_CHANGES_WHEN_AUTO_OFFER_NONE and CONFIG.AUTO_OFFER == "none" and method == "InvokeServer" then
            if (self == AddBrainrot and args[1] == ADD_BRAINROT_GUID) or (self == RemoveBrainrot and args[1] == REMOVE_BRAINROT_GUID) then
              notify("[SAB] Blocked manual offer change (AUTO_OFFER=none)")
              return false, "Blocked by SAB offer lock"
            end
          end

          return old(self, ...)
        end)

        notify("[SAB] Hook safety layer enabled")
      end
    end
  end
end

notify("[SAB] Loaded (whitelist + offer change UI ready)")
