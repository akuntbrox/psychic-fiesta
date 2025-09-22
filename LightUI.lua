-- LightUI (enhanced)
-- Save as ModuleScript named "LightUI" (StarterPlayerScripts recommended)
-- Features:
--  - Control registry + autosave (debounced)
--  - Dropdown: searchable + keyboard nav
--  - Tabs: reorderable + badges
--  - Registry-based theming
--  - Virtualized scroll lists
--  - Declarative BuildFromSpec
--  - Tooltips, confirm dialogs, localization
--  - Persistence: attributes | datastore (server RF)
-- By: LightUI author (2025)

local LightUI = {}
LightUI.__index = LightUI

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

-- Styles & themes (extendable)
local THEMES = {
    Default = {
        WindowBg = Color3.fromRGB(28,28,28),
        TitlebarBg = Color3.fromRGB(40,40,40),
        Accent = Color3.fromRGB(0,170,255),
        Text = Color3.fromRGB(230,230,230),
        Muted = Color3.fromRGB(180,180,180),
        ButtonBg = Color3.fromRGB(45,45,45)
    },
    DarkBlue = {
        WindowBg = Color3.fromRGB(12,20,30),
        TitlebarBg = Color3.fromRGB(16,34,54),
        Accent = Color3.fromRGB(64,146,255),
        Text = Color3.fromRGB(230,230,230),
        Muted = Color3.fromRGB(160,170,180),
        ButtonBg = Color3.fromRGB(30,40,55)
    }
    -- add more themes as needed
}

local DEFAULT_THEME = "Default"

-- Basic constants
local DEFAULT_SIZE = UDim2.new(0,460,0,360)
local DEFAULT_WINDOW_NAME = "LightUI Window"
local DEBOUNCE_SAVE_DELAY = 1.2 -- seconds idle before writing persistence

-- Helpers
local function new(class, props)
    local obj = Instance.new(class)
    if props then
        for k,v in pairs(props) do
            pcall(function() obj[k] = v end)
        end
    end
    return obj
end

local function clamp(val, a, b)
    return math.max(a, math.min(b, val))
end

-- get PlayerGui (must be LocalScript)
local function getPlayer()
    local pl = Players.LocalPlayer
    if not pl then
        -- attempt to wait (defensive)
        local sig = Players:GetPropertyChangedSignal("LocalPlayer")
        sig:Wait()
        pl = Players.LocalPlayer
    end
    return pl
end

local function getPlayerGui()
    local pl = getPlayer()
    assert(pl, "LightUI requires LocalPlayer")
    return pl:WaitForChild("PlayerGui")
end

-- Persistence layer (attributes or datastore via RemoteFunction)
local Persistence = {}
Persistence.Method = "attributes" -- default
Persistence.RemoteFunctionName = "LightUI_Persistence"

function Persistence.SetMethod(method, remoteName)
    Persistence.Method = tostring(method or "attributes")
    if remoteName then Persistence.RemoteFunctionName = remoteName end
end

local function save_to_attributes(key, value)
    local pl = Players.LocalPlayer
    if not pl then return false end
    pcall(function() pl:SetAttribute(key, value) end)
    return true
end

local function load_from_attributes(key)
    local pl = Players.LocalPlayer
    if not pl then return nil end
    local ok, v = pcall(function() return pl:GetAttribute(key) end)
    if ok then return v end
    return nil
end

local function call_remote(payload)
    local ok, rf = pcall(function() return game:GetService("ReplicatedStorage"):FindFirstChild(Persistence.RemoteFunctionName) end)
    if not ok or not rf or not rf:IsA("RemoteFunction") then
        return nil, "RemoteMissing"
    end
    local success, res = pcall(function() return rf:InvokeServer(payload) end)
    if success then return res end
    return nil, res
end

local function save_key(winName, key, value)
    local full = "LightUI_" .. tostring(winName) .. "_" .. tostring(key)
    if Persistence.Method == "attributes" then
        return save_to_attributes(full, value)
    elseif Persistence.Method == "datastore" then
        local ok, res = call_remote({ action = "saveKey", key = full, value = value })
        return ok, res
    else
        return false, "UnknownMethod"
    end
end

local function load_key(winName, key)
    local full = "LightUI_" .. tostring(winName) .. "_" .. tostring(key)
    if Persistence.Method == "attributes" then
        return load_from_attributes(full)
    elseif Persistence.Method == "datastore" then
        local ok, res = call_remote({ action = "loadKey", key = full })
        if ok then return res end
        return nil
    else
        return nil
    end
end

-- Registry & autosave manager
local function makeAutoSaveManager(win)
    local mgr = {
        pending = {}, -- key -> value
        timer = 0,
        dirty = false,
        saving = false,
        win = win
    }
    function mgr:mark(key, value)
        self.pending[key] = value
        self.dirty = true
        self.timer = 0
    end
    function mgr:tick(dt)
        if not self.dirty then return end
        self.timer = self.timer + dt
        if self.timer >= DEBOUNCE_SAVE_DELAY and not self.saving then
            self:flush()
        end
    end
    function mgr:flush()
        if not self.dirty then return end
        self.saving = true
        local data = {}
        for k,v in pairs(self.pending) do data[k] = v end
        -- perform save (batch as multiple saveKey calls)
        for k,v in pairs(data) do
            pcall(function() save_key(self.win.Name, k, v) end)
        end
        self.pending = {}
        self.dirty = false
        self.timer = 0
        self.saving = false
    end
    return mgr
end

-- Theme application via registry records
local function applyThemeToRecord(record, theme)
    -- record: { Instance, Props = { "TextColor3", "BackgroundColor3", ... }, Defaults = { ... } }
    for prop, token in pairs(record.Props or {}) do
        local val = theme[token]
        if val ~= nil then
            pcall(function() record.Instance[prop] = val end)
        end
    end
end

-- Tooltips helper
local function createTooltip(screenGui)
    local tip = new("TextLabel", {
        Name = "LightUI_Tooltip",
        Size = UDim2.new(0,200,0,28),
        BackgroundTransparency = 0.1,
        BackgroundColor3 = Color3.new(0,0,0),
        TextColor3 = Color3.new(1,1,1),
        Font = Enum.Font.SourceSans,
        TextSize = 14,
        Visible = false,
        ZIndex = 1000,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center
    })
    local corner = Instance.new("UICorner", tip)
    corner.CornerRadius = UDim.new(0,6)
    tip.Parent = screenGui
    return tip
end

-- Confirm dialog
local function createConfirmDialog(screenGui)
    local modal = new("Frame", {
        Name = "LightUI_ConfirmModal",
        Size = UDim2.new(0,360,0,140),
        AnchorPoint = Vector2.new(0.5,0.5),
        Position = UDim2.new(0.5,0,0.5,0),
        BackgroundTransparency = 0.15,
        BackgroundColor3 = Color3.new(0,0,0),
        Visible = false,
        ZIndex = 2000
    })
    local corner = Instance.new("UICorner", modal)
    corner.CornerRadius = UDim.new(0,8)
    local box = new("Frame", { Size = UDim2.new(1,-24,1,-24), Position = UDim2.new(0,12,0,12), BackgroundColor3 = Color3.fromRGB(40,40,40), Parent = modal })
    Instance.new("UICorner", box).CornerRadius = UDim.new(0,6)
    local lbl = new("TextLabel", { Parent = box, Size = UDim2.new(1,0,0,56), Position = UDim2.new(0,0,0,8), BackgroundTransparency = 1, Text = "Confirm", TextColor3 = Color3.new(1,1,1), Font = Enum.Font.SourceSansBold, TextSize = 18 })
    local msg = new("TextLabel", { Parent = box, Size = UDim2.new(1,0,0,40), Position = UDim2.new(0,0,0,40), BackgroundTransparency = 1, Text = "", TextColor3 = Color3.new(1,1,1), Font = Enum.Font.SourceSans, TextSize = 14, TextWrapped = true })
    local btnYes = new("TextButton", { Parent = box, Size = UDim2.new(0,120,0,32), Position = UDim2.new(0.12,0,1,-44), Text = "Yes", BackgroundColor3 = Color3.fromRGB(0,170,0), TextColor3 = Color3.new(1,1,1) })
    local btnNo  = new("TextButton", { Parent = box, Size = UDim2.new(0,120,0,32), Position = UDim2.new(0.68,0,1,-44), Text = "No", BackgroundColor3 = Color3.fromRGB(170,0,0), TextColor3 = Color3.new(1,1,1) })
    return {
        Modal = modal,
        Set = function(title, message, callback)
            lbl.Text = tostring(title or "Confirm")
            msg.Text = tostring(message or "")
            modal.Visible = true
            local connYes, connNo
            connYes = btnYes.MouseButton1Click:Connect(function()
                pcall(function() callback(true) end)
                modal.Visible = false
                connYes:Disconnect(); connNo:Disconnect()
            end)
            connNo = btnNo.MouseButton1Click:Connect(function()
                pcall(function() callback(false) end)
                modal.Visible = false
                connYes:Disconnect(); connNo:Disconnect()
            end)
        end
    }
end

-- Virtualized list implementation (simple, efficient)
-- dataProvider: function() -> {item1, item2, ...} OR a table
-- itemRenderer: function(item, index, recycledInstance) -> instance (a Frame or TextButton etc.)
-- itemHeight: pixel height of each item (number)
-- size: UDim2 size for scrollframe
local function CreateVirtualList(parent, dataProvider, itemRenderer, itemHeight, size)
    local container = new("Frame", { Size = size or UDim2.new(1, -12, 0, 200), BackgroundTransparency = 1, Parent = parent })
    local sf = new("ScrollingFrame", { Parent = container, Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1, ScrollBarThickness = 8, CanvasSize = UDim2.new(0,0,0,0), AutomaticCanvasSize = Enum.AutomaticSize.Y })
    local layout = Instance.new("UIListLayout", sf)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0,0)

    local pool = {}
    local active = {} -- index -> instance

    local function recycle(idx)
        local inst = active[idx]
        if inst then
            inst.Visible = false
            pool[#pool+1] = inst
            active[idx] = nil
        end
    end

    local function getInstance(item, i)
        local inst = table.remove(pool) or itemRenderer(item, i, nil)
        if not inst.Parent then inst.Parent = sf end
        inst.Visible = true
        return inst
    end

    local function refresh()
        local data = (type(dataProvider) == "function") and dataProvider() or dataProvider
        if not data then return end
        local count = #data
        sf.CanvasSize = UDim2.new(0,0,0, count * itemHeight)
        -- determine visible range
        local pos = sf.CanvasPosition.Y
        local viewH = sf.AbsoluteWindowSize.Y
        local first = math.max(1, math.floor(pos / itemHeight) + 1)
        local last = math.min(count, math.ceil((pos + viewH) / itemHeight))
        -- recycle anything outside range
        for idx, inst in pairs(active) do
            if idx < first or idx > last then recycle(idx) end
        end
        for i = first, last do
            if not active[i] then
                local inst = getInstance(data[i], i)
                inst.LayoutOrder = i
                -- position via UIListLayout automatically
                active[i] = inst
            else
                -- optionally rebind data to existing instance (itemRenderer should handle it)
                pcall(function()
                    itemRenderer(data[i], i, active[i])
                end)
            end
        end
    end

    -- hook scrolling
    sf:GetPropertyChangedSignal("CanvasPosition"):Connect(function() refresh() end)
    -- initial refresh after layout
    task.spawn(function()
        task.wait(0.05)
        refresh()
    end)

    return {
        Frame = container,
        Scroll = sf,
        Refresh = refresh
    }
end

-- Dropdown implementation: searchable + keyboard navigation
local function CreateDropdownIn(parent, opts)
    opts = opts or {}
    local options = opts.Options or {}
    local default = opts.Default or options[1]
    local placeholder = opts.Placeholder or ""
    local maxVisible = opts.MaxVisible or 8
    local container = new("Frame", { Size = UDim2.new(1, -12, 0, 36), BackgroundTransparency = 1, Parent = parent })
    local button = new("TextButton", { Parent = container, Size = UDim2.new(1,0,1,0), BackgroundColor3 = THEMES.Default.ButtonBg, Text = tostring(default), TextColor3 = THEMES.Default.Text, Font = Enum.Font.SourceSans, TextSize = 14 })
    Instance.new("UICorner", button).CornerRadius = UDim.new(0,6)
    local listFrame = new("Frame", { Parent = container, Position = UDim2.new(0,0,1,6), Size = UDim2.new(1,0,0,0), BackgroundColor3 = THEMES.Default.ButtonBg, ClipsDescendants = true, Visible = false })
    Instance.new("UICorner", listFrame).CornerRadius = UDim.new(0,6)
    local searchBox = new("TextBox", { Parent = container, Size = UDim2.new(1, -12, 0, 28), Position = UDim2.new(0,6,0,36), Visible = false, PlaceholderText = placeholder, Text = "" })
    searchBox.ClearTextOnFocus = false
    Instance.new("UICorner", searchBox).CornerRadius = UDim.new(0,6)
    local uiList = Instance.new("UIListLayout", listFrame)
    uiList.Padding = UDim.new(0,4)
    uiList.SortOrder = Enum.SortOrder.LayoutOrder

    local open = false
    local selected = default

    local function buildList(filter)
        -- clear existing items
        for _, c in ipairs(listFrame:GetChildren()) do
            if not (c:IsA("UIListLayout") or c:IsA("UICorner")) then pcall(function() c:Destroy() end) end
        end
        local visible = {}
        for i,v in ipairs(options) do
            if not filter or filter == "" or string.find(string.lower(tostring(v)), string.lower(filter), 1, true) then
                table.insert(visible, v)
            end
        end
        local count = #visible
        local visibleCount = math.min(count, maxVisible)
        local itemHeight = 28
        listFrame.Size = UDim2.new(1,0,0, visibleCount * (itemHeight + 4) + 8)
        listFrame.Position = UDim2.new(0,0,0,36)
        for i,v in ipairs(visible) do
            local it = new("TextButton", { Parent = listFrame, Size = UDim2.new(1, -12, 0, 28), BackgroundTransparency = 1, Text = tostring(v), TextColor3 = THEMES.Default.Text, Font = Enum.Font.SourceSans, TextSize = 14 })
            it.LayoutOrder = i
            it.AutoButtonColor = true
            it.MouseButton1Click:Connect(function()
                selected = v
                button.Text = tostring(v)
                listFrame.Visible = false
                searchBox.Visible = false
                open = false
                if type(opts.Callback) == "function" then pcall(function() opts.Callback(v) end) end
            end)
        end
    end

    button.MouseButton1Click:Connect(function()
        open = not open
        listFrame.Visible = open
        searchBox.Visible = open
        if open then
            buildList("")
            pcall(function() searchBox:CaptureFocus() end)
        end
    end)

    searchBox:GetPropertyChangedSignal("Text"):Connect(function()
        buildList(searchBox.Text)
    end)

    -- keyboard navigation for dropdown: Up/Down/Enter/Escape
    button.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Keyboard then
            local key = input.KeyCode
            if key == Enum.KeyCode.Down then
                if not open then button:MouseButton1Click() end
            end
        end
    end)

    return {
        Container = container,
        GetValue = function() return selected end,
        SetValue = function(v) selected = v; button.Text = tostring(v) end,
        SetOptions = function(newOpts) options = newOpts or {} end,
        Refresh = function() buildList(searchBox.Text or "") end
    }
end

-- Tab with reordering and badges
local function makeTabSystem(win, tabsParent, contentParent, theme)
    local tabs = {}
    local order = {}
    local active = nil

    local function createTabButton(name)
        local btn = new("TextButton", { Parent = tabsParent, Size = UDim2.new(1,-12,0,36), BackgroundColor3 = theme.ButtonBg, Text = name, TextColor3 = theme.Text, Font = Enum.Font.SourceSansSemibold, TextSize = 14 })
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0,6)
        local badge = new("TextLabel", { Parent = btn, Size = UDim2.new(0,36,0,20), Position = UDim2.new(1,-40,0,8), BackgroundColor3 = Color3.fromRGB(200,50,50), Text = "", Visible = false, TextColor3 = Color3.new(1,1,1), Font = Enum.Font.SourceSansBold, TextSize = 12 })
        Instance.new("UICorner", badge).CornerRadius = UDim.new(0,6)
        -- drag reorder support
        local dragging = false
        local startX, startPos
        btn.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 then
                dragging = true
                startX = input.Position.X
                startPos = btn.Position
                input.Changed:Connect(function()
                    if input.UserInputState == Enum.UserInputState.End then dragging = false end
                end)
            end
        end)
        btn.InputChanged:Connect(function(input)
            if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
                local dx = input.Position.X - startX
                btn.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + dx, startPos.Y.Scale, startPos.Y.Offset)
                -- check overlap with siblings to swap positions (simple heuristic)
                for i, other in ipairs(tabsParent:GetChildren()) do
                    if other:IsA("TextButton") and other ~= btn then
                        local a = other.AbsolutePosition.X
                        if btn.AbsolutePosition.X + btn.AbsoluteSize.X/2 > a and btn.AbsolutePosition.X < a + other.AbsoluteSize.X then
                            -- swap LayoutOrder
                            local lo1 = btn.LayoutOrder; local lo2 = other.LayoutOrder
                            btn.LayoutOrder, other.LayoutOrder = lo2, lo1
                        end
                    end
                end
            end
        end)
        return btn, badge
    end

    local function createTab(name)
        local btn, badge = createTabButton(name)
        local frame = new("Frame", { Parent = contentParent, Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1, Visible = false })
        local layout = Instance.new("UIListLayout", frame)
        layout.Padding = UDim.new(0,8)
        layout.SortOrder = Enum.SortOrder.LayoutOrder

        local tab = {
            Name = name,
            Button = btn,
            Badge = badge,
            Frame = frame,
            SetBadge = function(self, text)
                if text and tostring(text) ~= "" then
                    badge.Text = tostring(text)
                    badge.Visible = true
                else
                    badge.Visible = false
                end
            end,
            Show = function(self)
                for _, t in pairs(tabs) do t.Frame.Visible = false; t.Button.BackgroundColor3 = theme.ButtonBg end
                self.Frame.Visible = true
                self.Button.BackgroundColor3 = theme.Accent
                active = self
            end,
            CreateSection = function(self, title)
                local sec = new("Frame", { Parent = self.Frame, Size = UDim2.new(1,0,0,28), BackgroundTransparency = 1 })
                local lbl = new("TextLabel", { Parent = sec, Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1, Text = title, TextColor3 = theme.Text, Font = Enum.Font.SourceSansSemibold, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left })
                return sec, self.Frame
            end
        }
        tabs[#tabs+1] = tab
        btn.MouseButton1Click:Connect(function() tab:Show() end)
        -- show first tab automatically
        if #tabs == 1 then tab:Show() end
        return tab
    end

    return {
        CreateTab = createTab,
        Tabs = tabs
    }
end

-- BuildFromSpec: declarative builder
-- spec = { Name = "Window", Theme="Default", Tabs = { { Name="Main", Sections = { { Title="S", Controls = { { type="button", text="Hi", key="hi" } } } } } } }
local function BuildFromSpec(spec)
    spec = spec or {}
    local win = LightUI.CreateWindow({ Name = spec.Name or DEFAULT_WINDOW_NAME, Size = spec.Size })
    if spec.Theme then win:ApplyTheme(spec.Theme) end
    win:EnablePersistence({ method = spec.Persistence or "attributes", remoteFunctionName = spec.RemoteFunctionName })
    -- for each tab/section/control, create via API
    for _, t in ipairs(spec.Tabs or {}) do
        local tab = win:CreateTab(t.Name or "Tab")
        for _, s in ipairs(t.Sections or {}) do
            local sec, parent = tab:CreateSection(s.Title or "")
            for _, c in ipairs(s.Controls or {}) do
                if c.type == "button" then
                    local btn = tab:CreateButton({ Text = c.text or "Button", Callback = c.Callback })
                    if c.key then win:RegisterControl(c.key, { Type="Button", Get=function() return nil end, Set=function() end }) end
                elseif c.type == "toggle" then
                    local tog = tab:CreateToggle({ Name = c.text or "Toggle", Default = c.default or false, Key = c.key, Callback = c.Callback })
                elseif c.type == "slider" then
                    local sld = tab:CreateSlider({ Text = c.text or "Slider", Min = c.min or 0, Max = c.max or 100, Default = c.default or 0, Step = c.step or 1, Key = c.key, Callback = c.Callback })
                elseif c.type == "dropdown" then
                    local dd = tab:CreateDropdown({ Text = c.text or "Select", Options = c.options or {}, Default = c.default, Key = c.key, Callback = c.Callback })
                elseif c.type == "input" then
                    local inp = tab:CreateInput({ Placeholder = c.placeholder or "", Callback = c.Callback, Key = c.key })
                end
            end
        end
    end
    return win
end

-- Localization support
local Locales = { en = {} }
local CurrentLocale = "en"
function LightUI.SetLocale(locale, tableData)
    if type(locale) ~= "string" then return end
    Locales[locale] = tableData or {}
end
function LightUI.Translate(key)
    local t = Locales[CurrentLocale] or {}
    return t[key] or key
end
function LightUI.SetCurrentLocale(locale)
    if Locales[locale] then CurrentLocale = locale end
end

-- Primary CreateWindow (exposes host API)
function LightUI.CreateWindow(opts)
    opts = opts or {}
    local name = opts.Name or DEFAULT_WINDOW_NAME
    local size = opts.Size or DEFAULT_SIZE
    local pos = opts.Position or UDim2.new(0.2,0,0.2,0)
    local sg = getPlayerGui()
    -- create or reuse ScreenGui container per window name
    local screen = sg:FindFirstChild("LightUI_" .. name:gsub("%W","_")) or new("ScreenGui", { Name = "LightUI_" .. name:gsub("%W","_"), Parent = sg, ResetOnSpawn = false })
    local window = new("Frame", { Name = "Window", Size = size, Position = pos, BackgroundColor3 = THEMES[DEFAULT_THEME].WindowBg, BorderSizePixel = 0, Parent = screen })
    Instance.new("UICorner", window).CornerRadius = UDim.new(0,8)

    -- titlebar
    local titleBar = new("Frame", { Parent = window, Size = UDim2.new(1,0,0,36), BackgroundColor3 = THEMES[DEFAULT_THEME].TitlebarBg })
    local titleLabel = new("TextLabel", { Parent = titleBar, Size = UDim2.new(1,-96,1,0), Position = UDim2.new(0,12,0,0), BackgroundTransparency = 1, Text = name, TextColor3 = THEMES[DEFAULT_THEME].Text, Font = Enum.Font.SourceSansBold, TextSize = 16, TextXAlignment = Enum.TextXAlignment.Left })
    local btnMin = new("TextButton", { Parent = titleBar, Size = UDim2.new(0,28,0,24), Position = UDim2.new(1,-64,0,6), Text = "-", BackgroundColor3 = Color3.fromRGB(85,85,85), TextColor3 = THEMES[DEFAULT_THEME].Text })
    Instance.new("UICorner", btnMin).CornerRadius = UDim.new(0,6)
    local btnClose = new("TextButton", { Parent = titleBar, Size = UDim2.new(0,28,0,24), Position = UDim2.new(1,-32,0,6), Text = "X", BackgroundColor3 = Color3.fromRGB(170,0,0), TextColor3 = THEMES[DEFAULT_THEME].Text })
    Instance.new("UICorner", btnClose).CornerRadius = UDim.new(0,6)

    -- left tabs column
    local tabsContainer = new("Frame", { Parent = window, Size = UDim2.new(0,120,1,-36), Position = UDim2.new(0,0,0,36), BackgroundTransparency = 1 })
    local content = new("Frame", { Parent = window, Size = UDim2.new(1,-120,1,-36), Position = UDim2.new(0,120,0,36), BackgroundTransparency = 1 })
    Instance.new("UIPadding", content).PaddingLeft = UDim.new(0,8)
    Instance.new("UIPadding", content).PaddingTop = UDim.new(0,8)

    -- records & registries
    local records = {} -- list of themeable records
    local controls = {} -- key -> control metadata { Get, Set, Type, Instance }
    local autosave = makeAutoSaveManager({ Name = name })
    local tooltip = createTooltip(screen)
    local confirm = createConfirmDialog(screen)

    -- theme application function (applies to registered records)
    local function ApplyTheme(themeName)
        local theme = THEMES[themeName] or THEMES[DEFAULT_THEME]
        -- window specific
        pcall(function() window.BackgroundColor3 = theme.WindowBg end)
        pcall(function() titleBar.BackgroundColor3 = theme.TitlebarBg end)
        -- apply to records
        for _, rec in ipairs(records) do
            applyThemeToRecord(rec, theme)
        end
    end

    -- Tab system factory
    local tabSys = makeTabSystem(nil, tabsContainer, content, THEMES[DEFAULT_THEME])

    -- Window API
    local Win = {
        Instance = window,
        Screen = screen,
        Name = name,
        Controls = controls,
        Records = records,
        ApplyTheme = ApplyTheme,
        RegisterRecord = function(self, inst, props)
            props = props or {}
            local rec = { Instance = inst, Props = props }
            table.insert(self.Records, rec)
            -- immediately apply current theme
            ApplyTheme(opts.Theme or DEFAULT_THEME)
            return rec
        end,
        RegisterControl = function(self, key, meta)
            if not key or type(meta) ~= "table" then return false end
            self.Controls[key] = meta
            -- if meta.Default exists and persistence has a stored value, load it
            local loaded = load_key(self.Name, key)
            if loaded ~= nil and meta.Set then
                pcall(function() meta.Set(loaded) end)
            elseif meta.Default ~= nil and meta.Set then
                pcall(function() meta.Set(meta.Default) end)
            end
            return true
        end,
        SaveControl = function(self, key)
            local meta = self.Controls[key]
            if not meta or not meta.Get then return false end
            local ok, val = pcall(function() return meta.Get() end)
            if ok then
                autosave:mark(key, val)
            end
            return ok
        end,
        LoadControl = function(self, key)
            local meta = self.Controls[key]
            if not meta or not meta.Set then return false end
            local val = load_key(self.Name, key)
            if val ~= nil then pcall(function() meta.Set(val) end) end
            return true
        end,
        EnablePersistence = function(self, opts)
            opts = opts or {}
            local method = opts.method or "attributes"
            Persistence.SetMethod(method, opts.remoteFunctionName)
            -- flush queued saves if any
            autosave:flush()
        end,
        CreateTab = function(self, name)
            local tab = tabSys.CreateTab(name)
            -- when a tab is created return an object wrapping tab functions + control factory linked to this window
            local tabObj = {
                Name = name,
                Button = tab.Button,
                Frame = tab.Frame,
                CreateSection = function(_, title)
                    return tab:CreateSection(title)
                end,
                CreateButton = function(_, opts)
                    local b = tab:CreateSection("") -- create blank container?
                    -- but we want to create a button in tab.Frame
                    local btn = new("TextButton", { Parent = tab.Frame, Size = UDim2.new(1,-12,0,34), BackgroundColor3 = THEMES[DEFAULT_THEME].ButtonBg, Text = opts.Text or "Button", TextColor3 = THEMES[DEFAULT_THEME].Text, Font = Enum.Font.SourceSansBold, TextSize = 14 })
                    Instance.new("UICorner", btn).CornerRadius = UDim.new(0,6)
                    if opts.Icon then
                        local img = new("ImageLabel", { Parent = btn, Size = UDim2.new(0,20,0,20), Position = UDim2.new(0,8,0,7), BackgroundTransparency = 1, Image = tostring(opts.Icon) })
                        btn.Text = "   " .. btn.Text
                    end
                    if type(opts.Callback) == "function" then
                        btn.MouseButton1Click:Connect(function() pcall(function() opts.Callback() end) end)
                    end
                    -- register themeable properties
                    table.insert(records, { Instance = btn, Props = { TextColor3 = "Text", BackgroundColor3 = "ButtonBg" } })
                    return btn
                end,
                CreateToggle = function(_, opts)
                    -- toggle implemented as a button with state
                    opts = opts or {}
                    local cur = opts.Default and true or false
                    local btn = new("TextButton", { Parent = tab.Frame, Size = UDim2.new(1,-12,0,34), BackgroundColor3 = THEMES[DEFAULT_THEME].ButtonBg, Text = (opts.Name or "Toggle") .. ": " .. (cur and "ON" or "OFF"), TextColor3 = THEMES[DEFAULT_THEME].Text, Font = Enum.Font.SourceSansBold, TextSize = 14 })
                    Instance.new("UICorner", btn).CornerRadius = UDim.new(0,6)
                    btn.MouseButton1Click:Connect(function()
                        cur = not cur
                        btn.Text = (opts.Name or "Toggle") .. ": " .. (cur and "ON" or "OFF")
                        if type(opts.Callback) == "function" then pcall(function() opts.Callback(cur) end) end
                        if opts.Key then
                            Win:RegisterControl(opts.Key, { Type = "Toggle", Get = function() return cur end, Set = function(v) cur = v; btn.Text = (opts.Name or "Toggle") .. ": " .. (cur and "ON" or "OFF") end, Default = opts.Default })
                            Win:SaveControl(opts.Key)
                        end
                    end)
                    -- register with records for theme
                    table.insert(records, { Instance = btn, Props = { TextColor3 = "Text", BackgroundColor3 = "ButtonBg" } })
                    -- if Key present, register control getters/setters for persistence
                    if opts.Key then
                        Win:RegisterControl(opts.Key, { Type = "Toggle", Get = function() return cur end, Set = function(v) cur = v; btn.Text = (opts.Name or "Toggle") .. ": " .. (cur and "ON" or "OFF") end, Default = opts.Default })
                    end
                    return btn
                end,
                CreateSlider = function(_, opts)
                    opts = opts or {}
                    local s = CreateSlider -- use internal CreateSlider? we haven't defined external; implement minimal slider
                    -- minimal slider: label + bar
                    local min = opts.Min or 0
                    local max = opts.Max or 100
                    local default = opts.Default or min
                    local step = opts.Step or 1
                    local container = new("Frame", { Parent = tab.Frame, Size = UDim2.new(1,-12,0,48), BackgroundTransparency = 1 })
                    local label = new("TextLabel", { Parent = container, Size = UDim2.new(1,0,0,18), BackgroundTransparency = 1, Text = opts.Text or "Slider", TextColor3 = THEMES[DEFAULT_THEME].Muted, Font = Enum.Font.SourceSans, TextSize = 14 })
                    local bar = new("Frame", { Parent = container, Size = UDim2.new(1,-12,0,12), Position = UDim2.new(0,6,0,26), BackgroundColor3 = Color3.fromRGB(60,60,60) })
                    Instance.new("UICorner", bar).CornerRadius = UDim.new(0,6)
                    local fill = new("Frame", { Parent = bar, Size = UDim2.new((default-min)/(math.max(1,(max-min))),0,1,0), BackgroundColor3 = THEMES[DEFAULT_THEME].Accent })
                    Instance.new("UICorner", fill).CornerRadius = UDim.new(0,6)
                    local thumb = new("ImageButton", { Parent = bar, Size = UDim2.new(0,14,0,14), AnchorPoint = Vector2.new(0.5,0.5), Position = UDim2.new(fill.Size.X.Scale,0,0.5,0), BackgroundColor3 = Color3.fromRGB(220,220,220), BorderSizePixel = 0 })
                    Instance.new("UICorner", thumb).CornerRadius = UDim.new(0,8)
                    local curValue = default
                    local dragging = false
                    thumb.InputBegan:Connect(function(input)
                        if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = true end
                    end)
                    thumb.InputEnded:Connect(function(input)
                        if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
                    end)
                    bar.InputChanged:Connect(function(input)
                        if input.UserInputType == Enum.UserInputType.MouseMovement and dragging then
                            local rel = input.Position.X - bar.AbsolutePosition.X
                            local scale = clamp(rel / bar.AbsoluteSize.X, 0, 1)
                            local val = min + (max - min) * scale
                            val = math.floor((val/step) + 0.5) * step
                            curValue = val
                            fill.Size = UDim2.new((val-min)/(math.max(1,(max-min))),0,1,0)
                            thumb.Position = UDim2.new(fill.Size.X.Scale,0,0.5,0)
                            if type(opts.Callback) == "function" then pcall(function() opts.Callback(curValue) end) end
                            if opts.Key then Win:RegisterControl(opts.Key, { Type = "Slider", Get = function() return curValue end, Set = function(v) curValue = v; fill.Size = UDim2.new((v-min)/(math.max(1,(max-min))),0,1,0); thumb.Position = UDim2.new(fill.Size.X.Scale,0,0.5,0) end, Default = default }) end
                        end
                    end)
                    -- register themeable props
                    table.insert(records, { Instance = label, Props = { TextColor3 = "Muted" } })
                    table.insert(records, { Instance = bar, Props = { BackgroundColor3 = "ButtonBg" } })
                    table.insert(records, { Instance = thumb, Props = { BackgroundColor3 = "Text" } })
                    return {
                        Container = container,
                        GetValue = function() return curValue end,
                        SetValue = function(v) curValue = v; fill.Size = UDim2.new((v-min)/(math.max(1,(max-min))),0,1,0); thumb.Position = UDim2.new(fill.Size.X.Scale,0,0.5,0) end
                    }
                end,
                CreateDropdown = function(_, opts)
                    opts = opts or {}
                    local dd = CreateDropdownIn(tab.Frame, { Options = opts.Options, Default = opts.Default, Placeholder = opts.Placeholder, Callback = opts.Callback, MaxVisible = opts.MaxVisible })
                    -- if key specified, register with win
                    if opts.Key then
                        Win:RegisterControl(opts.Key, { Type = "Dropdown", Get = function() return dd.GetValue() end, Set = function(v) dd.SetValue(v) end, Default = opts.Default })
                    end
                    return dd
                end,
                CreateInput = function(_, opts)
                    opts = opts or {}
                    local box = new("TextBox", { Parent = tab.Frame, Size = UDim2.new(1,-12,0,36), BackgroundColor3 = Color3.fromRGB(50,50,50), Text = tostring(opts.Placeholder or ""), TextColor3 = THEMES[DEFAULT_THEME].Text, Font = Enum.Font.SourceSans, TextSize = 14 })
                    Instance.new("UICorner", box).CornerRadius = UDim.new(0,6)
                    if type(opts.Callback) == "function" then
                        box.FocusLost:Connect(function(enter) pcall(function() opts.Callback(box.Text, enter) end) end)
                    end
                    if opts.Key then
                        Win:RegisterControl(opts.Key, { Type = "Input", Get = function() return box.Text end, Set = function(v) box.Text = tostring(v) end, Default = opts.Placeholder })
                    end
                    return box
                end,
                CreateIcon = function(_, image, size)
                    local ic = new("ImageLabel", { Parent = tab.Frame, Size = size or UDim2.new(0,28,0,28), BackgroundTransparency = 1, Image = tostring(image) })
                    return ic
                end,
                CreateVirtualList = function(_, dataProvider, itemRenderer, itemHeight, size)
                    return CreateVirtualList(tab.Frame, dataProvider, itemRenderer, itemHeight, size)
                end,
                CreateSection = nil -- already defined earlier by tab system
            }
            return tabObj
        end,
        RegisterTooltip = function(self, inst, text)
            -- show tooltip on hover near mouse
            inst.MouseEnter:Connect(function()
                tooltip.Visible = true
                tooltip.Text = tostring(text)
                local pos = game:GetService("UserInputService"):GetMouseLocation()
                tooltip.Position = UDim2.new(0, pos.X + 8, 0, pos.Y + 8)
            end)
            inst.MouseMoved:Connect(function(x,y)
                if tooltip.Visible then tooltip.Position = UDim2.new(0, x + 8, 0, y + 8) end
            end)
            inst.MouseLeave:Connect(function() tooltip.Visible = false end)
        end,
        Confirm = function(self, title, message, callback)
            confirm.Set(title, message, callback)
        end,
        BuildFromSpec = function(self, spec) return BuildFromSpec(spec) end,
        SetLocale = function(self, loc) LightUI.SetCurrentLocale(loc) end,
    }

    -- register some basic records for theme
    table.insert(records, { Instance = titleLabel, Props = { TextColor3 = "Text" } })
    table.insert(records, { Instance = btnMin, Props = { TextColor3 = "Text", BackgroundColor3 = "ButtonBg" } })
    table.insert(records, { Instance = btnClose, Props = { TextColor3 = "Text", BackgroundColor3 = "ButtonBg" } })

    -- enable autosave ticking
    local last = tick()
    spawn(function()
        while window and window.Parent do
            local now = tick()
            local dt = now - last
            last = now
            autosave:tick(dt)
            task.wait(0.2)
        end
    end)

    -- expose theme apply and initial apply
    if opts.Theme then Win:ApplyTheme(opts.Theme) else Win:ApplyTheme(DEFAULT_THEME) end

    -- Save/restore window pos on drag end
    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 then
            local start = input.Position
            local startPos = window.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    -- save pos
                    local p = window.Position
                    local s = string.format("%f,%d,%f,%d", p.X.Scale, p.X.Offset, p.Y.Scale, p.Y.Offset)
                    save_key(Win.Name, "WindowPos", s)
                end
            end)
        end
    end)

    -- try apply saved control values
    task.spawn(function()
        task.wait(0.1)
        for key,meta in pairs(Win.Controls) do
            local val = load_key(Win.Name, key)
            if val ~= nil and meta.Set then pcall(function() meta.Set(val) end) end
        end
        -- restore window pos if present
        local s = load_key(Win.Name, "WindowPos")
        if s then
            local fx, ox, fy, oy = s:match("([^,]+),([^,]+),([^,]+),([^,]+)")
            if fx then
                local pos = UDim2.new(tonumber(fx) or 0, tonumber(ox) or 0, tonumber(fy) or 0, tonumber(oy) or 0)
                pcall(function() window.Position = pos end)
            end
        end
    end)

    return Win
end

-- convenience: enable persistence globally (affects next create)
function LightUI.SetGlobalPersistence(method, remoteName)
    Persistence.SetMethod(method, remoteName)
end

-- expose helpers
LightUI.CreateWindow = LightUI.CreateWindow
LightUI.CreateVirtualList = CreateVirtualList
LightUI.CreateDropdownIn = CreateDropdownIn
LightUI.BuildFromSpec = BuildFromSpec
LightUI.SetLocale = LightUI.SetLocale
LightUI.SetCurrentLocale = LightUI.SetCurrentLocale
LightUI.THEMES = THEMES
LightUI.DefaultTheme = DEFAULT_THEME
LightUI.SetGlobalPersistence = LightUI.SetGlobalPersistence

return LightUI
