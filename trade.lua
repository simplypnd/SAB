--[[
  Steal A Brainrot - Player-to-player auto-trade script (executor)
  Run in a Roblox executor (e.g. Synapse, KRNL).
  Features: whitelist auto-accept, show other player's add/remove, optional auto-offer/ready/accept.
]]

-- ============== CONFIG ==============
local CONFIG = {
  -- Only auto-accept invites from these usernames (strings).
  -- Example: { "FriendName", "AnotherFriend" } (this compares against Roblox usernames, not display names)
  AUTO_ACCEPT_WHITELIST = { "SesaPingge" },

  -- What to offer: "none" | "all" | number (first N brainrots)
  AUTO_OFFER = "none",

  AUTO_READY_AFTER_OFFER = false,
  AUTO_ACCEPT_WHEN_BOTH_READY = false,

  ACTION_DELAY_SEC = 0.3,
  SHOW_OTHER_OFFER_CHANGES = true,
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
  for _, v in ipairs(CONFIG.AUTO_ACCEPT_WHITELIST) do
    if type(v) == "string" and v == username then
      return true
    end
  end
  return false
end

local function delay(sec)
  if sec and sec > 0 then task.wait(sec) end
end

-- ============== AUTO-ACCEPT (WHITELIST) ==============
CreateInvite.OnClientEvent:Connect(function(inviteId, inviteData)
  if type(inviteData) ~= "table" or not inviteData.from then return end
  local now = workspace:GetServerTimeNow()
  if inviteData.expires and now > inviteData.expires then return end
  local fromUsername = getUsernameFromUserId(inviteData.from)
  if not fromUsername or not isWhitelistedUsername(fromUsername) then return end

  delay(CONFIG.ACTION_DELAY_SEC)
  local ok, err = pcall(function()
    AcceptInvite:InvokeServer(ACCEPT_INVITE_GUID, inviteId)
  end)
  if ok then
    print("[SAB AutoTrade] Auto-accepted trade from:", fromUsername)
  else
    warn("[SAB AutoTrade] AcceptInvite failed:", err)
  end
end)

-- ============== TRADE STATE & OTHER PLAYER OFFER DIFF ==============
local tradeReplicator = ReplicatorClient.get("Trade_" .. tostring(LocalPlayer.UserId))
local previousOtherOfferKeys = {}
local currentTradeOtherIndex = nil

tradeReplicator:ListenRaw(function(raw)
  if raw == nil then
    previousOtherOfferKeys = {}
    currentTradeOtherIndex = nil
    return
  end

  local activeData = tradeReplicator:TryIndex({ "active", "data" })
  if not activeData then
    previousOtherOfferKeys = {}
    currentTradeOtherIndex = nil
    return
  end

  local users = tradeReplicator:TryIndex({ "active", "data", "users" })
  local players = tradeReplicator:TryIndex({ "active", "data", "players" })
  if type(users) ~= "table" or type(players) ~= "table" then return end

  local myIndex, otherIndex, otherUserId
  for idx, uid in pairs(users) do
    if uid == LocalPlayer.UserId then
      myIndex = idx
    else
      otherIndex = idx
      otherUserId = uid
    end
  end

  if not otherIndex then return end
  currentTradeOtherIndex = otherIndex

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
    local added = {}
    local removed = {}
    for k in pairs(newKeys) do
      if not previousOtherOfferKeys[k] then
        table.insert(added, newEntriesByKey[k] and (newEntriesByKey[k].Index or k) or k)
      end
    end
    for k in pairs(previousOtherOfferKeys) do
      if not newKeys[k] then
        table.insert(removed, k)
      end
    end
    for _, name in ipairs(added) do
      print("[SAB AutoTrade] Other player added:", name)
    end
    for _, key in ipairs(removed) do
      -- Key format: UUID:Index:Mutation:Traits (4 segments)
      local segs = {}
      for s in (key .. ":"):gmatch("(.-):") do table.insert(segs, s) end
      local idx = (segs[2] and segs[2] ~= "") and segs[2] or key
      print("[SAB AutoTrade] Other player removed:", idx)
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
    local lastChange = tradeReplicator:TryIndex({ "active", "data", "lastChange" })
    local isProcessing = tradeReplicator:TryIndex({ "active", "data", "isProcessing" })
    local now = workspace:GetServerTimeNow()
    local canReady = type(lastChange) == "number" and (now >= lastChange + 5) and not isProcessing

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

print("[SAB AutoTrade] Loaded. Whitelist auto-accept and other-player offer changes enabled.")
