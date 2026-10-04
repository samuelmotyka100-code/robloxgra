--==================================================
-- EKWIPUNEK – SERWER
-- ServerScriptService > EquipmentServer (Script)
--
-- Serwer jest jedynym źródłem prawdy: przechowuje magazyn i założone
-- przedmioty, sprawdza każde żądanie klienta, zakłada modele na postać
-- (również po respawnie) i zapisuje postęp w DataStore.
--
-- Wymagania w Studio:
--   ServerStorage > ItemStorage > (modele przedmiotów: Accessory albo Tool)
--   Nazwa modelu = klucz w tabeli ITEMS poniżej.
--==================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local DataStoreService = game:GetService("DataStoreService")

---------------------------------------------------------
-- 1. REMOTE – tworzony jako pierwszy, bo klient na niego czeka
---------------------------------------------------------
local REMOTE_NAME = "EquipmentEvent"

local remote = ReplicatedStorage:FindFirstChild(REMOTE_NAME)
if remote and not remote:IsA("RemoteEvent") then
	remote:Destroy()
	remote = nil
end
if not remote then
	remote = Instance.new("RemoteEvent")
	remote.Name = REMOTE_NAME
	remote.Parent = ReplicatedStorage
end

---------------------------------------------------------
-- 2. KONFIGURACJA
---------------------------------------------------------
local DATASTORE_NAME = "Equipment_v1"
local ITEM_FOLDER_NAME = "ItemStorage"
local REQUEST_COOLDOWN = 0.2 -- s, minimalny odstęp między żądaniami gracza
local LOAD_RETRIES = 3

-- Kolejność = kolejność w GUI.
-- HoldInHand: Tool z tego slotu trafia do ręki. Roblox pozwala trzymać
-- tylko jedno narzędzie naraz, więc ustaw to dla maksymalnie jednego slotu.
local SLOTS = {
	{ Id = "Hat", Label = "Głowa", Icon = "🎩" },
	{ Id = "Weapon", Label = "Broń", Icon = "⚔️", HoldInHand = true },
	{ Id = "Tool", Label = "Narzędzie", Icon = "🧰" },
	{ Id = "Artifact", Label = "Artefakt", Icon = "💎" },
}

-- Klucz = nazwa modelu w ServerStorage.ItemStorage
local ITEMS = {
	TravelerHat = { Name = "Kapelusz podróżnika", Slot = "Hat", Icon = "👒" },
	HuntingKnife = { Name = "Nóż myśliwski", Slot = "Weapon", Icon = "🗡️" },
	RustyShovel = { Name = "Zardzewiała łopata", Slot = "Tool", Icon = "⛏️" },
}

-- Co dostaje nowy gracz
local STARTER_ITEMS = { "TravelerHat", "HuntingKnife", "RustyShovel" }

---------------------------------------------------------
-- 3. PRZYGOTOWANIE
---------------------------------------------------------
local slotById = {}
for _, slot in ipairs(SLOTS) do
	slotById[slot.Id] = slot
end

for id, item in pairs(ITEMS) do
	if not slotById[item.Slot] then
		warn(("[EquipmentServer] Przedmiot '%s' ma nieznany slot '%s'"):format(id, tostring(item.Slot)))
	end
end

-- Katalog wysyłany klientowi – klient nie musi mieć własnej kopii konfiguracji
local CATALOG = { slots = SLOTS, items = ITEMS }

-- W nieopublikowanym miejscu GetDataStore rzuca błąd – wtedy gramy bez zapisu
local store
do
	local ok, result = pcall(DataStoreService.GetDataStore, DataStoreService, DATASTORE_NAME)
	if ok then
		store = result
	else
		warn("[EquipmentServer] DataStore niedostępny – postęp nie będzie zapisywany: " .. tostring(result))
	end
end

---------------------------------------------------------
-- 4. STAN GRACZY
---------------------------------------------------------
-- profiles[player] = { storage = {itemId...}, equipped = {[slotId] = itemId}, canSave = bool }
local profiles = {}
-- worn[player] = { [slotId] = Instance } – sklonowane modele na postaci
local worn = {}
local lastRequest = {}

local function newProfile()
	local profile = { storage = {}, equipped = {}, canSave = true }
	for _, id in ipairs(STARTER_ITEMS) do
		if ITEMS[id] then
			table.insert(profile.storage, id)
		end
	end
	return profile
end

-- Usuwa z zapisu przedmioty/sloty, których już nie ma w grze
local function profileFromData(data)
	if type(data) ~= "table" then
		return newProfile()
	end

	local profile = { storage = {}, equipped = {}, canSave = true }

	if type(data.storage) == "table" then
		for _, id in ipairs(data.storage) do
			if ITEMS[id] then
				table.insert(profile.storage, id)
			end
		end
	end

	if type(data.equipped) == "table" then
		for slotId, id in pairs(data.equipped) do
			local item = ITEMS[id]
			if item and item.Slot == slotId and slotById[slotId] then
				profile.equipped[slotId] = id
			end
		end
	end

	return profile
end

local function dataKey(player)
	return "player_" .. player.UserId
end

local function loadProfile(player)
	if not store then
		local profile = newProfile()
		profile.canSave = false
		return profile
	end

	for attempt = 1, LOAD_RETRIES do
		local ok, result = pcall(store.GetAsync, store, dataKey(player))
		if ok then
			return profileFromData(result)
		end
		warn(("[EquipmentServer] Wczytywanie %s nieudane (próba %d): %s"):format(player.Name, attempt, tostring(result)))
		if attempt < LOAD_RETRIES then
			task.wait(2 ^ attempt)
		end
	end

	-- Nie nadpisujemy prawdziwego zapisu danymi startowymi
	local profile = newProfile()
	profile.canSave = false
	return profile
end

local function saveProfile(player)
	local profile = profiles[player]
	if not store or not profile or not profile.canSave then
		return
	end

	local data = { storage = table.clone(profile.storage), equipped = table.clone(profile.equipped) }
	local ok, err = pcall(store.SetAsync, store, dataKey(player), data, { player.UserId })
	if not ok then
		warn(("[EquipmentServer] Zapis %s nieudany: %s"):format(player.Name, tostring(err)))
	end
end

local function sync(player)
	local profile = profiles[player]
	if not profile then
		return
	end
	remote:FireClient(player, {
		catalog = CATALOG,
		storage = table.clone(profile.storage),
		equipped = table.clone(profile.equipped),
	})
end

---------------------------------------------------------
-- 5. MODELE NA POSTACI
---------------------------------------------------------
local function removeWorn(player, slotId)
	local playerWorn = worn[player]
	local instance = playerWorn and playerWorn[slotId]
	if instance then
		instance:Destroy()
		playerWorn[slotId] = nil
	end
end

local function wear(player, slotId)
	removeWorn(player, slotId)

	local profile = profiles[player]
	local itemId = profile and profile.equipped[slotId]
	if not itemId then
		return
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return -- zostanie założone przy respawnie
	end

	local folder = ServerStorage:FindFirstChild(ITEM_FOLDER_NAME)
	local template = folder and folder:FindFirstChild(itemId)
	if not template then
		warn(("[EquipmentServer] Brak modelu ServerStorage.%s.%s"):format(ITEM_FOLDER_NAME, itemId))
		return
	end

	local clone = template:Clone()

	if clone:IsA("Accessory") then
		humanoid:AddAccessory(clone)
	elseif clone:IsA("Tool") then
		clone.CanBeDropped = false
		if slotById[slotId].HoldInHand then
			humanoid:EquipTool(clone)
		else
			clone.Parent = player:FindFirstChildOfClass("Backpack")
		end
	else
		warn(("[EquipmentServer] '%s' musi być Accessory albo Tool, a jest %s"):format(itemId, clone.ClassName))
		clone:Destroy()
		return
	end

	worn[player][slotId] = clone
end

local function wearAll(player)
	for _, slot in ipairs(SLOTS) do
		wear(player, slot.Id)
	end
end

---------------------------------------------------------
-- 6. AKCJE GRACZA
---------------------------------------------------------
local function equip(player, itemId)
	local profile = profiles[player]
	local item = type(itemId) == "string" and ITEMS[itemId]
	if not item or not slotById[item.Slot] then
		return
	end

	local index = table.find(profile.storage, itemId)
	if not index then
		return -- gracz tego nie posiada
	end
	table.remove(profile.storage, index)

	local previous = profile.equipped[item.Slot]
	if previous then
		table.insert(profile.storage, previous)
	end

	profile.equipped[item.Slot] = itemId
	wear(player, item.Slot)
end

local function unequip(player, slotId)
	local profile = profiles[player]
	if type(slotId) ~= "string" then
		return
	end

	local itemId = profile.equipped[slotId]
	if not itemId then
		return
	end

	profile.equipped[slotId] = nil
	table.insert(profile.storage, itemId)
	removeWorn(player, slotId)
end

remote.OnServerEvent:Connect(function(player, action, arg)
	if not profiles[player] then
		return -- dane jeszcze się wczytują; stan zostanie wysłany po wczytaniu
	end

	if action == "Sync" then
		sync(player)
		return
	end

	local now = os.clock()
	if now - (lastRequest[player] or 0) < REQUEST_COOLDOWN then
		sync(player) -- odrzucone – przywróć klientowi właściwy stan
		return
	end
	lastRequest[player] = now

	if action == "Equip" then
		equip(player, arg)
	elseif action == "Unequip" then
		unequip(player, arg)
	end

	sync(player)
end)

---------------------------------------------------------
-- 7. GRACZE
---------------------------------------------------------
local function onCharacterAdded(player, character)
	-- Poprzednie klony zniknęły razem ze starą postacią i Backpackiem
	worn[player] = {}
	character:WaitForChild("Humanoid", 10)
	player:WaitForChild("Backpack", 10)
	if player.Parent and player.Character == character then
		wearAll(player)
	end
end

local function onPlayerAdded(player)
	worn[player] = {}

	local profile = loadProfile(player)
	if not player.Parent then
		return -- wyszedł w trakcie wczytywania
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
	worn[player] = nil
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
