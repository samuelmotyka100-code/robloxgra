--==================================================
-- EKWIPUNEK – KLIENT (GUI)
-- StarterPlayer > StarterPlayerScripts > EquipmentClient (LocalScript)
--
-- Tylko wyświetla stan przysłany przez EquipmentServer i wysyła prośby
-- o założenie / zdjęcie przedmiotu. Niczego nie zmienia samodzielnie.
-- Otwieranie: przycisk "Postać" w lewym dolnym rogu albo klawisz C.
--==================================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer

---------------------------------------------------------
-- USTAWIENIA
---------------------------------------------------------
local REMOTE_NAME = "EquipmentEvent"
local TOGGLE_KEY = Enum.KeyCode.C
local REQUEST_TIMEOUT = 2 -- s, po tylu sekundach bez odpowiedzi odblokuj klikanie

local WINDOW_SIZE = Vector2.new(640, 440)
local WINDOW_POS = UDim2.new(0.5, -WINDOW_SIZE.X / 2, 0.5, -WINDOW_SIZE.Y / 2)

local TWEEN_FAST = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWEEN_OPEN = TweenInfo.new(0.2, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

local THEME = {
	Window = Color3.fromRGB(22, 23, 26),
	Header = Color3.fromRGB(29, 30, 34),
	Panel = Color3.fromRGB(27, 28, 32),
	Card = Color3.fromRGB(35, 37, 42),
	CardEquipped = Color3.fromRGB(45, 65, 85),
	Stroke = Color3.fromRGB(65, 67, 73),
	Accent = Color3.fromRGB(110, 170, 230),
	Text = Color3.fromRGB(235, 235, 235),
	TextMuted = Color3.fromRGB(150, 150, 150),
}

---------------------------------------------------------
-- STAN (kopia od serwera)
---------------------------------------------------------
local remote = nil -- RemoteEvent, gdy już się pojawi
local catalog = nil -- { slots = {...}, items = {...} } od serwera
local storage = {} -- { itemId, ... }
local equipped = {} -- { [slotId] = itemId }
local waitingUntil = 0 -- blokada klikania do czasu odpowiedzi serwera
local isOpen = false

---------------------------------------------------------
-- POMOCNICZE
---------------------------------------------------------
local function create(className, props, children)
	local instance = Instance.new(className)
	for key, value in pairs(props) do
		if key ~= "Parent" then
			instance[key] = value
		end
	end
	for _, child in ipairs(children or {}) do
		child.Parent = instance
	end
	instance.Parent = props.Parent
	return instance
end

local function corner(radius)
	return create("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function stroke(color, transparency)
	return create("UIStroke", { Color = color, Thickness = 1, Transparency = transparency or 0 })
end

local function label(props)
	props.BackgroundTransparency = 1
	props.Font = props.Font or Enum.Font.GothamMedium
	props.TextColor3 = props.TextColor3 or THEME.Text
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	return create("TextLabel", props)
end

-- Kolor bazowy trzymamy w atrybucie, żeby hover działał też po zmianie stanu
local function setCardColor(button, color)
	button:SetAttribute("BaseColor", color)
	button.BackgroundColor3 = color
end

local function addHover(button)
	button.MouseEnter:Connect(function()
		local base = button:GetAttribute("BaseColor") or button.BackgroundColor3
		TweenService:Create(button, TWEEN_FAST, { BackgroundColor3 = base:Lerp(Color3.new(1, 1, 1), 0.08) }):Play()
	end)
	button.MouseLeave:Connect(function()
		local base = button:GetAttribute("BaseColor") or button.BackgroundColor3
		TweenService:Create(button, TWEEN_FAST, { BackgroundColor3 = base }):Play()
	end)
end

local function isInside(guiObject, position)
	local topLeft, size = guiObject.AbsolutePosition, guiObject.AbsoluteSize
	return position.X >= topLeft.X and position.X <= topLeft.X + size.X
		and position.Y >= topLeft.Y and position.Y <= topLeft.Y + size.Y
end

-- SetCoreGuiEnabled potrafi się nie udać, zanim załadują się CoreScripts
local function hideDefaultBackpack()
	for _ = 1, 10 do
		if pcall(StarterGui.SetCoreGuiEnabled, StarterGui, Enum.CoreGuiType.Backpack, false) then
			return
		end
		task.wait(0.5)
	end
	warn("[EquipmentClient] Nie udało się ukryć domyślnego plecaka")
end

---------------------------------------------------------
-- GUI
---------------------------------------------------------
local screenGui = create("ScreenGui", {
	Name = "EquipmentGui",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	DisplayOrder = 19,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = player:WaitForChild("PlayerGui"),
})

-- Przycisk w lewym dolnym rogu (nad Indeksem)
local openButton = create("TextButton", {
	Name = "OpenButton",
	Size = UDim2.fromOffset(130, 48),
	Position = UDim2.new(0, 25, 1, -193),
	BackgroundColor3 = THEME.Window,
	BorderSizePixel = 0,
	AutoButtonColor = false,
	Text = "",
	Parent = screenGui,
}, {
	corner(12),
	stroke(THEME.Stroke, 0.2),
	label({ Size = UDim2.fromOffset(30, 30), Position = UDim2.new(0, 10, 0.5, -15), Text = "🛡️", TextSize = 20,
		TextXAlignment = Enum.TextXAlignment.Center }),
	label({ Size = UDim2.fromOffset(60, 20), Position = UDim2.new(0, 42, 0.5, -10), Text = "Postać", TextSize = 13 }),
	create("Frame", {
		Size = UDim2.fromOffset(26, 26),
		Position = UDim2.new(1, -34, 0.5, -13),
		BackgroundColor3 = Color3.fromRGB(45, 47, 53),
		BorderSizePixel = 0,
	}, {
		corner(6),
		stroke(Color3.fromRGB(80, 83, 92)),
		label({ Size = UDim2.fromScale(1, 1), Text = TOGGLE_KEY.Name, TextSize = 13, Font = Enum.Font.GothamBold,
			TextXAlignment = Enum.TextXAlignment.Center }),
	}),
})
setCardColor(openButton, THEME.Window)
addHover(openButton)

-- Przyciemnienie tła (Active = false – prawy przycisk dalej obraca kamerą)
local overlay = create("Frame", {
	Name = "Overlay",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.new(0, 0, 0),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Active = false,
	Visible = false,
	Parent = screenGui,
})

local windowScale = create("UIScale", { Scale = 1 })

local window = create("Frame", {
	Name = "Window",
	Size = UDim2.fromOffset(WINDOW_SIZE.X, WINDOW_SIZE.Y),
	Position = WINDOW_POS,
	BackgroundColor3 = THEME.Window,
	BorderSizePixel = 0,
	Active = true, -- kliknięcia w oknie nie przechodzą do świata gry
	Visible = false,
	Parent = screenGui,
}, {
	corner(18),
	stroke(THEME.Stroke, 0.2),
	windowScale,
})

-- Nagłówek
local header = create("Frame", {
	Name = "Header",
	Size = UDim2.new(1, 0, 0, 56),
	BackgroundColor3 = THEME.Header,
	BorderSizePixel = 0,
	Parent = window,
}, {
	corner(18),
	-- prostuje dolne rogi nagłówka
	create("Frame", {
		Size = UDim2.new(1, 0, 0, 18),
		Position = UDim2.new(0, 0, 1, -18),
		BackgroundColor3 = THEME.Header,
		BorderSizePixel = 0,
	}),
	label({ Size = UDim2.new(1, -80, 1, 0), Position = UDim2.fromOffset(20, 0), Text = "🛡️  EKWIPUNEK I MAGAZYN",
		TextSize = 18, Font = Enum.Font.GothamBold }),
})

local closeButton = create("TextButton", {
	Name = "CloseButton",
	Size = UDim2.fromOffset(36, 36),
	Position = UDim2.new(1, -46, 0, 10),
	BackgroundColor3 = Color3.fromRGB(44, 45, 50),
	BorderSizePixel = 0,
	AutoButtonColor = false,
	Text = "×",
	TextColor3 = THEME.Text,
	TextSize = 24,
	Font = Enum.Font.GothamMedium,
	ZIndex = 2,
	Parent = header,
}, {
	corner(10),
})
setCardColor(closeButton, closeButton.BackgroundColor3)
addHover(closeButton)

-- Panel z tytułem; zwraca kontener na zawartość i etykietę tytułu
local function makePanel(name, size, position, titleText, scrolling)
	local panel = create("Frame", {
		Name = name,
		Size = size,
		Position = position,
		BackgroundColor3 = THEME.Panel,
		BorderSizePixel = 0,
		Parent = window,
	}, {
		corner(14),
	})

	local title = label({
		Name = "Title",
		Size = UDim2.new(1, -24, 0, 32),
		Position = UDim2.fromOffset(14, 4),
		Text = titleText,
		TextSize = 12,
		Font = Enum.Font.GothamBold,
		TextColor3 = THEME.TextMuted,
		Parent = panel,
	})

	local content = create(scrolling and "ScrollingFrame" or "Frame", {
		Name = "Content",
		Size = UDim2.new(1, 0, 1, -40),
		Position = UDim2.fromOffset(0, 36),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = panel,
	}, {
		create("UIListLayout", {
			Padding = UDim.new(0, 8),
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		create("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 8) }),
	})

	if scrolling then
		content.ScrollBarThickness = 6
		content.ScrollBarImageColor3 = THEME.Stroke
		content.ScrollingDirection = Enum.ScrollingDirection.Y
		content.CanvasSize = UDim2.new()
		content.AutomaticCanvasSize = Enum.AutomaticSize.Y
	end

	return content, title
end

local slotList = makePanel("EquippedPanel", UDim2.new(0.42, -16, 1, -80), UDim2.fromOffset(16, 68), "ZAŁOŻONE")
local storageList, storageTitle = makePanel("StoragePanel", UDim2.new(0.58, -24, 1, -80),
	UDim2.new(0.42, 8, 0, 68), "MAGAZYN", true)

local statusLabel = label({
	Name = "Status",
	Size = UDim2.new(1, -24, 0, 40),
	Text = "Ładowanie...",
	TextSize = 14,
	TextColor3 = THEME.TextMuted,
	TextXAlignment = Enum.TextXAlignment.Center,
	LayoutOrder = 9999,
	Parent = storageList,
})

-- Karta: ikona + tytuł + podpis
local function makeCard(parent, order)
	local card = create("TextButton", {
		Size = UDim2.new(1, -24, 0, 56),
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Text = "",
		LayoutOrder = order,
		Parent = parent,
	}, {
		corner(10),
		label({ Name = "Icon", Size = UDim2.fromOffset(40, 40), Position = UDim2.new(0, 8, 0.5, -20), TextSize = 22,
			TextXAlignment = Enum.TextXAlignment.Center }),
		label({ Name = "Title", Size = UDim2.new(1, -64, 0, 20), Position = UDim2.fromOffset(54, 9), TextSize = 14,
			TextTruncate = Enum.TextTruncate.AtEnd }),
		label({ Name = "Subtitle", Size = UDim2.new(1, -64, 0, 16), Position = UDim2.fromOffset(54, 30), TextSize = 11,
			TextColor3 = THEME.TextMuted, Font = Enum.Font.Gotham }),
	})
	setCardColor(card, THEME.Card)
	addHover(card)
	return card
end

---------------------------------------------------------
-- KOMUNIKACJA
---------------------------------------------------------
local function send(action, arg)
	if not remote or not isOpen then
		return
	end
	local now = os.clock()
	if now < waitingUntil then
		return -- czekamy jeszcze na odpowiedź na poprzednie kliknięcie
	end
	waitingUntil = now + REQUEST_TIMEOUT
	remote:FireServer(action, arg)
end

---------------------------------------------------------
-- RYSOWANIE
---------------------------------------------------------
local slotCards = {} -- [slotId] = card

local function buildSlotCards()
	for order, slot in ipairs(catalog.slots) do
		local card = makeCard(slotList, order)
		card.Name = slot.Id
		card.Activated:Connect(function()
			if equipped[slot.Id] then
				send("Unequip", slot.Id)
			end
		end)
		slotCards[slot.Id] = card
	end
end

local function renderSlots()
	for _, slot in ipairs(catalog.slots) do
		local card = slotCards[slot.Id]
		local item = catalog.items[equipped[slot.Id]]

		if item then
			card.Icon.Text = item.Icon
			card.Title.Text = item.Name
			card.Title.TextColor3 = THEME.Text
			card.Subtitle.Text = slot.Label .. " · kliknij, aby zdjąć"
			setCardColor(card, THEME.CardEquipped)
		else
			card.Icon.Text = slot.Icon
			card.Title.Text = "[ pusty ]"
			card.Title.TextColor3 = THEME.TextMuted
			card.Subtitle.Text = slot.Label
			setCardColor(card, THEME.Card)
		end
	end
end

local function renderStorage()
	for _, child in ipairs(storageList:GetChildren()) do
		if child:IsA("GuiButton") then
			child:Destroy()
		end
	end

	local slotLabels = {}
	for _, slot in ipairs(catalog.slots) do
		slotLabels[slot.Id] = slot.Label
	end

	for order, itemId in ipairs(storage) do
		local item = catalog.items[itemId]
		if item then
			local card = makeCard(storageList, order)
			card.Name = itemId
			card.Icon.Text = item.Icon
			card.Title.Text = item.Name
			card.Subtitle.Text = (slotLabels[item.Slot] or item.Slot) .. " · kliknij, aby założyć"
			card.Activated:Connect(function()
				send("Equip", itemId)
			end)
		end
	end

	storageTitle.Text = ("MAGAZYN (%d)"):format(#storage)
	statusLabel.Text = "Magazyn jest pusty"
	statusLabel.Visible = #storage == 0
end

local function onServerState(payload)
	if type(payload) ~= "table" or type(payload.catalog) ~= "table" then
		return
	end

	if not catalog then
		catalog = payload.catalog
		buildSlotCards()
	end

	storage = payload.storage or {}
	equipped = payload.equipped or {}
	waitingUntil = 0

	renderSlots()
	renderStorage()
end

---------------------------------------------------------
-- OTWIERANIE / ZAMYKANIE
---------------------------------------------------------
local animationId = 0

local function setOpen(open)
	if open == isOpen then
		return
	end
	isOpen = open
	animationId += 1
	local myAnimation = animationId

	if open then
		overlay.Visible = true
		window.Visible = true
		windowScale.Scale = 0.94
		window.Position = WINDOW_POS + UDim2.fromOffset(0, 16)
		TweenService:Create(windowScale, TWEEN_OPEN, { Scale = 1 }):Play()
		TweenService:Create(window, TWEEN_OPEN, { Position = WINDOW_POS }):Play()
		TweenService:Create(overlay, TWEEN_OPEN, { BackgroundTransparency = 0.45 }):Play()

		if remote and not catalog then
			remote:FireServer("Sync") -- na wypadek, gdyby pierwszy stan się zgubił
		end
	else
		TweenService:Create(windowScale, TWEEN_FAST, { Scale = 0.94 }):Play()
		TweenService:Create(overlay, TWEEN_FAST, { BackgroundTransparency = 1 }):Play()
		task.delay(TWEEN_FAST.Time, function()
			if animationId == myAnimation then
				window.Visible = false
				overlay.Visible = false
			end
		end)
	end
end

local function toggle()
	setOpen(not isOpen)
end

openButton.Activated:Connect(toggle)
closeButton.Activated:Connect(function()
	setOpen(false)
end)

-- Kliknięcie / tapnięcie poza oknem zamyka je
overlay.InputBegan:Connect(function(input)
	local inputType = input.UserInputType
	if inputType ~= Enum.UserInputType.MouseButton1 and inputType ~= Enum.UserInputType.Touch then
		return
	end
	if not isInside(window, input.Position) then
		setOpen(false)
	end
end)

-- Klawisz (ContextActionService nie reaguje podczas pisania na czacie)
ContextActionService:BindAction("ToggleEquipment", function(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		toggle()
	end
	return Enum.ContextActionResult.Sink
end, false, TOGGLE_KEY)

---------------------------------------------------------
-- START
---------------------------------------------------------
task.spawn(hideDefaultBackpack)
player.CharacterAdded:Connect(function()
	task.spawn(hideDefaultBackpack)
end)

-- RemoteEvent tworzy serwer – czekamy w tle, żeby GUI działało od razu
task.spawn(function()
	local found = ReplicatedStorage:WaitForChild(REMOTE_NAME, 30)
	if not found or not found:IsA("RemoteEvent") then
		statusLabel.Text = "Brak połączenia z serwerem"
		warn("[EquipmentClient] Brak RemoteEvent '" .. REMOTE_NAME
			.. "' w ReplicatedStorage – czy skrypt EquipmentServer jest w ServerScriptService?")
		return
	end

	remote = found
	remote.OnClientEvent:Connect(onServerState)
	remote:FireServer("Sync")
end)
