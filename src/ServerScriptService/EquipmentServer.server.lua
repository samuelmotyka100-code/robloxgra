--==================================================
-- EQUIPMENT SERVER
-- ServerScriptService > EquipmentServer (Script)
--
-- Serwer jest jedynym źródłem prawdy: trzyma magazyn i założone
-- przedmioty każdego gracza, waliduje każde żądanie klienta,
-- zapisuje stan w DataStore i zakłada rzeczy po respawnie.
--==================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local DataStoreService = game:GetService("DataStoreService")

local sharedModule = ReplicatedStorage:WaitForChild("EquipmentShared", 10)
if not sharedModule or not sharedModule:IsA("ModuleScript") then
	error("[EquipmentServer] Brak ModuleScript 'EquipmentShared' w ReplicatedStorage")
end
local Shared = require(sharedModule)
local ITEMS, SLOTS, SLOT_ORDER = Shared.ITEMS, Shared.SLOTS, Shared.SLOT_ORDER
local Actions = Shared.Actions

local remote = ReplicatedStorage:FindFirstChild(Shared.REMOTE_NAME)
if not remote then
	remote = Instance.new("RemoteEvent")
	remote.Name = Shared.REMOTE_NAME
	remote.Parent = ReplicatedStorage
end

-- Nie czekamy na ItemStorage (to blokowałoby cały skrypt) – szukamy przy użyciu
local function getItemStorage()
	local folder = ServerStorage:FindFirstChild("ItemStorage")
	if not folder then
		warn("[EquipmentServer] Brak folderu ServerStorage.ItemStorage")
	end
	return folder
end

---------------------------------------------------------
-- KONFIGURACJA
---------------------------------------------------------
local DATASTORE_NAME = "Equipment_v1"
local LOAD_RETRIES = 3
local REQUEST_COOLDOWN = 0.2 -- s, minimalny odstęp między żądaniami gracza

-- W nieopublikowanym miejscu GetDataStore rzuca błąd – wtedy gramy bez zapisu
local storeOk, store = pcall(DataStoreService.GetDataStore, DataStoreService, DATASTORE_NAME)
if not storeOk then
	warn("[EquipmentServer] DataStore niedostępny, postęp nie będzie zapisywany: " .. tostring(store))
	store = nil
end

---------------------------------------------------------
-- STAN
---------------------------------------------------------
-- profiles[player] = { storage = {itemId, ...}, equipped = {[slot] = itemId}, canSave = bool }
local profiles = {}
-- spawned[player] = { [slot] = Instance } – sklonowane modele na postaci
local spawned = {}
local lastRequest = {}

---------------------------------------------------------
-- DANE
---------------------------------------------------------
local function dataKey(player)
	return "player_" .. player.UserId
end

-- Odrzuca nieznane/uszkodzone wpisy (np. po usunięciu przedmiotu z gry)
local function sanitize(data)
	local profile = { storage = {}, equipped = {}, canSave = true }

	if type(data) ~= "table" then
		for _, id in ipairs(Shared.STARTER_ITEMS) do
			table.insert(profile.storage, id)
		end
		return profile
	end

	if type(data.storage) == "table" then
		for _, id in ipairs(data.storage) do
			if ITEMS[id] then
				table.insert(profile.storage, id)
			end
		end
	end

	if type(data.equipped) == "table" then
		for slot, id in pairs(data.equipped) do
			if SLOTS[slot] and ITEMS[id] and ITEMS[id].Slot == slot then
				profile.equipped[slot] = id
			end
		end
	end

	return profile
end

local function loadProfile(player)
	if not store then
		local profile = sanitize(nil)
		profile.canSave = false
		return profile
	end

	for attempt = 1, LOAD_RETRIES do
		local ok, result = pcall(store.GetAsync, store, dataKey(player))
		if ok then
			return sanitize(result)
		end
		warn(("[EquipmentServer] Błąd wczytywania %s (próba %d): %s"):format(player.Name, attempt, tostring(result)))
		task.wait(2 ^ attempt)
	end

	-- Nie udało się wczytać – gramy na danych startowych, ale NIE zapisujemy,
	-- żeby nie nadpisać prawdziwego zapisu gracza.
	local profile = sanitize(nil)
	profile.canSave = false
	return profile
end

local function saveProfile(player)
	local profile = profiles[player]
	if not profile or not profile.canSave then
		return
	end

	local data = { storage = table.clone(profile.storage), equipped = table.clone(profile.equipped) }
	local ok, err = pcall(store.SetAsync, store, dataKey(player), data, { player.UserId })
	if not ok then
		warn(("[EquipmentServer] Błąd zapisu %s: %s"):format(player.Name, tostring(err)))
	end
end

local function sync(player)
	local profile = profiles[player]
	if not profile then
		return
	end
	remote:FireClient(player, Actions.Sync, {
		storage = table.clone(profile.storage),
		equipped = table.clone(profile.equipped),
	})
end

---------------------------------------------------------
-- MODELE NA POSTACI
---------------------------------------------------------
local function clearSlotInstance(player, slot)
	local playerSpawned = spawned[player]
	local inst = playerSpawned and playerSpawned[slot]
	if inst then
		inst:Destroy()
		playerSpawned[slot] = nil
	end
end

local function applySlot(player, slot)
	clearSlotInstance(player, slot)

	local profile = profiles[player]
	local id = profile and profile.equipped[slot]
	if not id then
		return
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return -- zostanie założone przy następnym respawnie
	end

	local itemStorage = getItemStorage()
	local template = itemStorage and itemStorage:FindFirstChild(id)
	if not template then
		warn(("[EquipmentServer] Brak modelu '%s' w ServerStorage.ItemStorage"):format(id))
		return
	end

	local clone = template:Clone()

	if clone:IsA("Accessory") then
		humanoid:AddAccessory(clone)
	elseif clone:IsA("Tool") then
		clone.CanBeDropped = false
		if SLOTS[slot].HoldInHand then
			humanoid:EquipTool(clone)
		else
			clone.Parent = player:FindFirstChildOfClass("Backpack")
		end
	else
		warn(("[EquipmentServer] '%s' musi być Accessory albo Tool (jest %s)"):format(id, clone.ClassName))
		clone:Destroy()
		return
	end

	spawned[player][slot] = clone
end

local function applyAll(player)
	for _, slot in ipairs(SLOT_ORDER) do
		applySlot(player, slot)
	end
end

---------------------------------------------------------
-- AKCJE
---------------------------------------------------------
local function equipItem(player, itemId)
	local profile = profiles[player]
	local item = type(itemId) == "string" and ITEMS[itemId]
	if not item then
		return
	end

	local index = table.find(profile.storage, itemId)
	if not index then
		return -- gracz nie ma tego przedmiotu w magazynie
	end

	table.remove(profile.storage, index)

	local previous = profile.equipped[item.Slot]
	if previous then
		table.insert(profile.storage, previous)
	end

	profile.equipped[item.Slot] = itemId
	applySlot(player, item.Slot)
end

local function unequipSlot(player, slot)
	local profile = profiles[player]
	if type(slot) ~= "string" or not SLOTS[slot] then
		return
	end

	local id = profile.equipped[slot]
	if not id then
		return
	end

	profile.equipped[slot] = nil
	table.insert(profile.storage, id)
	clearSlotInstance(player, slot)
end

remote.OnServerEvent:Connect(function(player, action, arg)
	if not profiles[player] then
		return -- dane jeszcze się wczytują; Sync zostanie wysłany po wczytaniu
	end

	if action == Actions.RequestSync then
		sync(player)
		return
	end

	local now = os.clock()
	if now - (lastRequest[player] or 0) < REQUEST_COOLDOWN then
		sync(player) -- przywróć klientowi właściwy stan
		return
	end
	lastRequest[player] = now

	if action == Actions.Equip then
		equipItem(player, arg)
	elseif action == Actions.Unequip then
		unequipSlot(player, arg)
	end

	sync(player)
end)

---------------------------------------------------------
-- GRACZE
---------------------------------------------------------
local function onCharacterAdded(player, character)
	-- Stare klony zniknęły razem z poprzednią postacią/Backpackiem
	spawned[player] = {}
	character:WaitForChild("Humanoid", 10)
	player:WaitForChild("Backpack", 10)
	if player.Parent and player.Character == character then
		applyAll(player)
	end
end

local function onPlayerAdded(player)
	spawned[player] = {}

	local profile = loadProfile(player)
	if not player.Parent then
		return -- gracz wyszedł podczas wczytywania
	end
	profiles[player] = profile

	player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end

	sync(player)
end

local function onPlayerRemoving(player)
	saveProfile(player)
	profiles[player] = nil
	spawned[player] = nil
	lastRequest[player] = nil
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

game:BindToClose(function()
	local pending = 0
	for player in pairs(profiles) do
		pending += 1
		task.spawn(function()
			saveProfile(player)
			pending -= 1
		end)
	end
	while pending > 0 do
		task.wait()
	end
end)
