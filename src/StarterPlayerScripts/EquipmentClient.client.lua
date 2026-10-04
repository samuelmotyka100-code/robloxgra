--==================================================
-- EQUIPMENT CLIENT GUI (Przycisk na ekranie + Klient)
-- StarterPlayer > StarterPlayerScripts > EquipmentClient
--
-- Klient tylko WYŚWIETLA stan przysłany przez serwer (EquipmentServer)
-- i wysyła prośby o założenie/zdjęcie. Niczego nie zmienia lokalnie.
--==================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")

local sharedModule = ReplicatedStorage:WaitForChild("EquipmentShared", 10)
if not sharedModule or not sharedModule:IsA("ModuleScript") then
	error("[EquipmentClient] Brak ModuleScript 'EquipmentShared' w ReplicatedStorage")
end
local Shared = require(sharedModule)
local ITEMS, SLOTS, SLOT_ORDER = Shared.ITEMS, Shared.SLOTS, Shared.SLOT_ORDER
local Actions = Shared.Actions

local player = Players.LocalPlayer
-- RemoteEvent tworzy serwer – szukamy go w tle (na dole skryptu), żeby
-- GUI i klawisz działały nawet wtedy, gdy serwer jeszcze nie jest gotowy.
local equipmentEvent = nil

---------------------------------------------------------
-- KONFIGURACJA
---------------------------------------------------------
local TOGGLE_KEY = Enum.KeyCode.C
local REMOTE_COOLDOWN = 0.25 -- s, ochrona przed spamowaniem serwera

local FRAME_SIZE = Vector2.new(600, 420)
local OPEN_POS = UDim2.new(0.5, -FRAME_SIZE.X / 2, 0.5, -FRAME_SIZE.Y / 2)
local OPEN_START_POS = OPEN_POS + UDim2.fromOffset(0, 20)
local OPEN_TWEEN = TweenInfo.new(0.2, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

local COLORS = {
	Background = Color3.fromRGB(22, 23, 26),
	Header = Color3.fromRGB(29, 30, 34),
	Panel = Color3.fromRGB(27, 28, 32),
	Slot = Color3.fromRGB(35, 37, 42),
	SlotEquipped = Color3.fromRGB(45, 65, 85),
	Stroke = Color3.fromRGB(65, 67, 73),
	TextBright = Color3.fromRGB(240, 240, 240),
	Text = Color3.fromRGB(220, 220, 220),
	TextMuted = Color3.fromRGB(150, 150, 150),
}

---------------------------------------------------------
-- STAN (kopia od serwera – nadpisywana przy każdym Sync)
---------------------------------------------------------
local state = { storage = {}, equipped = {} }
local loaded = false

---------------------------------------------------------
-- POMOCNICZE
---------------------------------------------------------
local function create(className, props, children)
	local inst = Instance.new(className)
	for key, value in pairs(props or {}) do
		if key ~= "Parent" then
			inst[key] = value
		end
	end
	for _, child in ipairs(children or {}) do
		child.Parent = inst
	end
	-- Parent ustawiamy na końcu (wydajniej i bez zbędnych replikacji/eventów)
	inst.Parent = props and props.Parent
	return inst
end

local function corner(radius)
	return create("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function stroke(color, transparency)
	return create("UIStroke", { Color = color, Thickness = 1, Transparency = transparency or 0 })
end

-- SetCore/SetCoreGuiEnabled potrafi się nie udać, zanim CoreScripts się załadują
local function hideBackpack()
	for _ = 1, 10 do
		local ok = pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.Backpack, false)
		if ok then
			return
		end
		task.wait(0.5)
	end
	warn("[EquipmentClient] Nie udało się ukryć domyślnego plecaka")
end

local lastRemoteTime = 0
local function canSendRemote()
	local now = os.clock()
	if now - lastRemoteTime < REMOTE_COOLDOWN then
		return false
	end
	lastRemoteTime = now
	return true
end

task.spawn(hideBackpack)

---------------------------------------------------------
-- TWORZENIE GUI
---------------------------------------------------------
local gui = create("ScreenGui", {
	Name = "EquipmentGui",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 19,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = player:WaitForChild("PlayerGui"),
})

-- 1. PRZYCISK SKRÓTU W LEWYM DOLNYM ROGU (nad Indeksem)
local shortcutButton = create("TextButton", {
	Name = "ShortcutButton",
	Size = UDim2.fromOffset(130, 48),
	Position = UDim2.new(0, 25, 1, -193),
	BackgroundColor3 = COLORS.Background,
	BorderSizePixel = 0,
	Text = "",
	AutoButtonColor = false,
	Parent = gui,
}, {
	corner(12),
	stroke(COLORS.Stroke, 0.2),
	create("TextLabel", {
		Name = "Icon",
		Size = UDim2.fromOffset(30, 30),
		Position = UDim2.new(0, 10, 0.5, -15),
		BackgroundTransparency = 1,
		Text = "🛡️",
		TextSize = 20,
	}),
	create("TextLabel", {
		Name = "Title",
		Size = UDim2.fromOffset(60, 20),
		Position = UDim2.new(0, 42, 0.5, -10),
		BackgroundTransparency = 1,
		Text = "Postać",
		TextColor3 = COLORS.Text,
		TextSize = 13,
		Font = Enum.Font.GothamMedium,
		TextXAlignment = Enum.TextXAlignment.Left,
	}),
	create("Frame", {
		Name = "KeyBadge",
		Size = UDim2.fromOffset(26, 26),
		Position = UDim2.new(1, -34, 0.5, -13),
		BackgroundColor3 = Color3.fromRGB(45, 47, 53),
		BorderSizePixel = 0,
	}, {
		corner(6),
		stroke(Color3.fromRGB(80, 83, 92)),
		create("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = TOGGLE_KEY.Name,
			TextColor3 = COLORS.TextBright,
			TextSize = 13,
			Font = Enum.Font.GothamBold,
		}),
	}),
})

-- 2. CIEMNE TŁO (Active = false, żeby prawy przycisk dalej obracał kamerą)
local overlay = create("Frame", {
	Name = "Overlay",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.new(0, 0, 0),
	BackgroundTransparency = 0.45,
	BorderSizePixel = 0,
	Active = false,
	Visible = false,
	Parent = gui,
})

-- 3. OKNO GŁÓWNE
local mainFrame = create("Frame", {
	Name = "MainFrame",
	Size = UDim2.fromOffset(FRAME_SIZE.X, FRAME_SIZE.Y),
	Position = OPEN_POS,
	BackgroundColor3 = COLORS.Background,
	BorderSizePixel = 0,
	Active = true, -- blokuje kliknięcia przechodzące do świata gry
	Visible = false,
	Parent = gui,
}, {
	corner(18),
	stroke(COLORS.Stroke, 0.2),
})

local header = create("Frame", {
	Name = "Header",
	Size = UDim2.new(1, 0, 0, 60),
	BackgroundColor3 = COLORS.Header,
	BorderSizePixel = 0,
	Parent = mainFrame,
}, {
	corner(18),
	-- Zakrywa zaokrąglenie dolnych rogów nagłówka
	create("Frame", {
		Name = "BottomFiller",
		Size = UDim2.new(1, 0, 0, 18),
		Position = UDim2.new(0, 0, 1, -18),
		BackgroundColor3 = COLORS.Header,
		BorderSizePixel = 0,
	}),
	create("TextLabel", {
		Name = "Title",
		Size = UDim2.fromOffset(300, 30),
		Position = UDim2.fromOffset(20, 15),
		BackgroundTransparency = 1,
		Text = "🛡️ EKWIPUNEK I MAGAZYN",
		TextColor3 = Color3.fromRGB(245, 245, 245),
		TextSize = 18,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Left,
	}),
})

local closeButton = create("TextButton", {
	Name = "CloseButton",
	Size = UDim2.fromOffset(36, 36),
	Position = UDim2.new(1, -46, 0, 12),
	BackgroundColor3 = Color3.fromRGB(44, 45, 50),
	BorderSizePixel = 0,
	Text = "×",
	TextColor3 = COLORS.Text,
	TextSize = 24,
	Font = Enum.Font.GothamMedium,
	ZIndex = 2,
	Parent = header,
}, {
	corner(10),
})

-- Lewa strona (Założone)
local equipContainer = create("Frame", {
	Name = "EquipContainer",
	Size = UDim2.new(0.45, 0, 1, -80),
	Position = UDim2.fromOffset(15, 70),
	BackgroundColor3 = COLORS.Panel,
	BorderSizePixel = 0,
	Parent = mainFrame,
}, {
	corner(14),
	create("UIListLayout", {
		Padding = UDim.new(0, 12),
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
	}),
})

-- Prawa strona (Magazyn)
local storageContainer = create("ScrollingFrame", {
	Name = "StorageContainer",
	Size = UDim2.new(0.5, 0, 1, -80),
	Position = UDim2.new(0.475, 0, 0, 70),
	BackgroundColor3 = COLORS.Panel,
	BorderSizePixel = 0,
	ScrollBarThickness = 6,
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y, -- zamiast ręcznego liczenia
	ScrollingDirection = Enum.ScrollingDirection.Y,
	Parent = mainFrame,
}, {
	corner(14),
	create("UIListLayout", {
		Padding = UDim.new(0, 8),
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
	}),
	create("UIPadding", {
		PaddingTop = UDim.new(0, 10),
		PaddingBottom = UDim.new(0, 10),
	}),
})

---------------------------------------------------------
-- RYSOWANIE
---------------------------------------------------------
local uiSlots = {}

local function requestEquip(itemId)
	if equipmentEvent and canSendRemote() then
		equipmentEvent:FireServer(Actions.Equip, itemId)
	end
end

local function requestUnequip(slotName)
	if equipmentEvent and state.equipped[slotName] and canSendRemote() then
		equipmentEvent:FireServer(Actions.Unequip, slotName)
	end
end

local function renderSlot(slotName)
	local btn = uiSlots[slotName]
	local item = ITEMS[state.equipped[slotName]]
	local label = SLOTS[slotName].Label

	if item then
		btn.Text = string.format("%s: %s %s", label, item.Icon, item.Name)
		btn.TextColor3 = COLORS.TextBright
		btn.BackgroundColor3 = COLORS.SlotEquipped
	else
		btn.Text = label .. ": [ PUSTY ]"
		btn.TextColor3 = COLORS.TextMuted
		btn.BackgroundColor3 = COLORS.Slot
	end
end

local emptyLabel = create("TextLabel", {
	Name = "EmptyLabel",
	Size = UDim2.new(0.92, 0, 0, 40),
	BackgroundTransparency = 1,
	TextColor3 = COLORS.TextMuted,
	Font = Enum.Font.GothamMedium,
	TextSize = 14,
	Text = "Ładowanie...",
	Parent = storageContainer,
})

local function renderStorage()
	for _, child in ipairs(storageContainer:GetChildren()) do
		if child:IsA("GuiButton") then
			child:Destroy()
		end
	end

	for order, itemId in ipairs(state.storage) do
		local item = ITEMS[itemId]
		if item then
			local btn = create("TextButton", {
				Name = itemId,
				Size = UDim2.new(0.92, 0, 0, 55),
				BackgroundColor3 = COLORS.Slot,
				BorderSizePixel = 0,
				Text = item.Icon .. "  " .. item.Name,
				TextColor3 = COLORS.Text,
				Font = Enum.Font.GothamMedium,
				TextSize = 14,
				LayoutOrder = order,
				Parent = storageContainer,
			}, {
				corner(8),
			})
			btn.Activated:Connect(function()
				requestEquip(itemId)
			end)
		end
	end

	emptyLabel.Text = loaded and "Magazyn jest pusty" or "Ładowanie..."
	emptyLabel.Visible = #state.storage == 0
end

local function renderAll()
	for _, slotName in ipairs(SLOT_ORDER) do
		renderSlot(slotName)
	end
	renderStorage()
end

-- Tworzenie UI dla slotów postaci
for order, slotName in ipairs(SLOT_ORDER) do
	local btn = create("TextButton", {
		Name = slotName,
		Size = UDim2.new(0.9, 0, 0, 55),
		BorderSizePixel = 0,
		Font = Enum.Font.GothamMedium,
		TextSize = 14,
		LayoutOrder = order,
		Parent = equipContainer,
	}, {
		corner(8),
	})

	btn.Activated:Connect(function()
		requestUnequip(slotName)
	end)

	uiSlots[slotName] = btn
end

---------------------------------------------------------
-- OTWIERANIE / ZAMYKANIE
---------------------------------------------------------
local isOpen = false
local openTween = nil

local function setOpen(open)
	if open == isOpen then
		return
	end
	isOpen = open

	if openTween then
		openTween:Cancel()
		openTween = nil
	end

	overlay.Visible = open
	mainFrame.Visible = open

	if open then
		mainFrame.Position = OPEN_START_POS
		openTween = TweenService:Create(mainFrame, OPEN_TWEEN, { Position = OPEN_POS })
		openTween:Play()
	else
		mainFrame.Position = OPEN_POS
	end
end

local function toggleEquipment()
	setOpen(not isOpen)
end

local function isPointInside(guiObject, x, y)
	local pos, size = guiObject.AbsolutePosition, guiObject.AbsoluteSize
	return x >= pos.X and x <= pos.X + size.X and y >= pos.Y and y <= pos.Y + size.Y
end

shortcutButton.Activated:Connect(toggleEquipment)
closeButton.Activated:Connect(function()
	setOpen(false)
end)

-- Kliknięcie/tapnięcie poza oknem zamyka je
overlay.InputBegan:Connect(function(input)
	local t = input.UserInputType
	if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then
		return
	end
	-- Overlay nie jest Active, więc sprawdzamy ręcznie, czy klik nie był w oknie
	if isPointInside(mainFrame, input.Position.X, input.Position.Y) then
		return
	end
	setOpen(false)
end)

-- Obsługa klawisza (CAS nie odpala akcji podczas pisania na czacie)
ContextActionService:BindAction("OpenEquipment", function(_, state)
	if state == Enum.UserInputState.Begin then
		toggleEquipment()
	end
	return Enum.ContextActionResult.Sink
end, false, TOGGLE_KEY)

---------------------------------------------------------
-- KOMUNIKACJA Z SERWEREM
---------------------------------------------------------
local function onServerEvent(action, newState)
	if action ~= Actions.Sync or type(newState) ~= "table" then
		return
	end
	state.storage = newState.storage or {}
	state.equipped = newState.equipped or {}
	loaded = true
	renderAll()
end

task.spawn(function()
	local remote = ReplicatedStorage:WaitForChild(Shared.REMOTE_NAME, 30)
	if not remote then
		warn("[EquipmentClient] Brak RemoteEvent '" .. Shared.REMOTE_NAME
			.. "' w ReplicatedStorage – czy EquipmentServer działa w ServerScriptService?")
		return
	end
	equipmentEvent = remote
	equipmentEvent.OnClientEvent:Connect(onServerEvent)
	equipmentEvent:FireServer(Actions.RequestSync)
end)

-- Po respawnie CoreGui potrafi wrócić – ukrywamy plecak ponownie.
-- (Zakładaniem rzeczy po respawnie zajmuje się serwer.)
player.CharacterAdded:Connect(function()
	task.spawn(hideBackpack)
end)

renderAll()
