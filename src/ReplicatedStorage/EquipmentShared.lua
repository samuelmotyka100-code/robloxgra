--==================================================
-- EQUIPMENT SHARED (wspólna konfiguracja klient/serwer)
-- ReplicatedStorage > EquipmentShared (ModuleScript)
--==================================================

local EquipmentShared = {}

EquipmentShared.REMOTE_NAME = "EquipmentEvent"

-- Akcje przesyłane przez RemoteEvent
EquipmentShared.Actions = {
	RequestSync = "RequestSync", -- klient -> serwer: poproś o aktualny stan
	Equip = "Equip", -- klient -> serwer: (itemId)
	Unequip = "Unequip", -- klient -> serwer: (slotName)
	Sync = "Sync", -- serwer -> klient: (state)
}

-- Kolejność slotów w GUI
EquipmentShared.SLOT_ORDER = { "Hat", "Weapon", "Tool", "Artifact" }

-- HoldInHand: Tool z tego slotu trafia do ręki postaci (tylko jeden slot
-- może to mieć – Roblox pozwala trzymać naraz tylko jedno narzędzie).
-- Pozostałe Toole lądują w (ukrytym) Backpacku.
EquipmentShared.SLOTS = {
	Hat = { Label = "Głowa" },
	Weapon = { Label = "Broń", HoldInHand = true },
	Tool = { Label = "Narzędzie" },
	Artifact = { Label = "Artefakt" },
}

-- Klucz = nazwa modelu w ServerStorage/ItemStorage.
-- Model może być Accessory (np. kapelusz) albo Tool (np. nóż, łopata).
EquipmentShared.ITEMS = {
	TravelerHat = { Name = "Kapelusz podróżnika", Slot = "Hat", Icon = "👒" },
	HuntingKnife = { Name = "Nóż myśliwski", Slot = "Weapon", Icon = "🗡️" },
	RustyShovel = { Name = "Zardzewiała łopata", Slot = "Tool", Icon = "⛏️" },
}

-- Przedmioty, które dostaje nowy gracz
EquipmentShared.STARTER_ITEMS = { "TravelerHat", "HuntingKnife", "RustyShovel" }

return EquipmentShared
