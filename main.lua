--[[--
Vocabulary Grid plugin for KOReader.

Reads the existing Vocabulary Builder's SQLite database directly (read-only
queries + delete) so it doesn't depend on or modify vocabbuilder.koplugin.
Shows words in a configurable rows x columns grid. Tapping a word opens the
normal dictionary lookup popup (same one KOReader uses everywhere), with an
extra "Remove from grid" button injected only while the grid is open.
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Event = require("ui/event")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputDialog = require("ui/widget/inputdialog")
local VerticalSpan = require("ui/widget/verticalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextWidget = require("ui/widget/textwidget")
local TopContainer = require("ui/widget/container/topcontainer")
local Widget = require("ui/widget/widget")
local LuaSettings = require("luasettings")
local Notification = require("ui/widget/notification")
local SQ3 = require("lua-ljsqlite3/init")
local Screen = Device.screen
local Size = require("ui/size")
local Font = require("ui/font")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template

local DEFAULT_ROWS = 10
local DEFAULT_COLS = 4

local db_location = DataStorage:getSettingsDir() .. "/vocabulary_builder.sqlite3"
local settings_location = DataStorage:getSettingsDir() .. "/vocabgrid_settings.lua"
local g_settings = LuaSettings:open(settings_location)

-- Flag + reference used so we only inject the "Remove from grid" button
-- when a dictionary popup was opened FROM the grid (not from normal reading).
-- mode is either "remove" (tapped an existing tile) or "add" (used the
-- dictionary-search-to-add toolbar button).
local active_grid_widget = nil
local active_grid_mode = nil

----------------------------------------------------------------
-- Minimal, self-contained access to the vocabulary builder DB --
----------------------------------------------------------------
local VocabGridDB = {}

function VocabGridDB:listWords()
    local conn = SQ3.open(db_location)
    local results = conn:exec("SELECT word FROM vocabulary ORDER BY word COLLATE NOCASE ASC;")
    conn:close()
    local words = {}
    if results and results.word then
        for i = 1, #results.word do
            table.insert(words, results.word[i])
        end
    end
    return words
end

function VocabGridDB:deleteWord(word)
    local conn = SQ3.open(db_location)
    local stmt = conn:prepare("DELETE FROM vocabulary WHERE word = ?;")
    stmt:bind(word)
    stmt:step()
    stmt:clearbind():reset()
    conn:close()
end

----------------------------------------------------------------
-- Grid widget --
----------------------------------------------------------------
local VocabGridWidget = InputContainer:extend{
    rows = nil,
    cols = nil,
    page = 1,
}

function VocabGridWidget:init()
    self.rows = g_settings:readSetting("rows") or DEFAULT_ROWS
    self.cols = g_settings:readSetting("cols") or DEFAULT_COLS
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
    self.search_filter = nil
    self.all_words = VocabGridDB:listWords()
    self.words = self.all_words
    self:buildLayout()
end

function VocabGridWidget:applyFilter()
    if not self.search_filter or self.search_filter == "" then
        self.words = self.all_words
        return
    end
    local needle = self.search_filter:lower()
    local filtered = {}
    for _, w in ipairs(self.all_words) do
        if w:lower():find(needle, 1, true) then
            table.insert(filtered, w)
        end
    end
    self.words = filtered
end

function VocabGridWidget:perPage()
    return self.rows * self.cols
end

function VocabGridWidget:totalPages()
    return math.max(1, math.ceil(#self.words / self:perPage()))
end

function VocabGridWidget:buildLayout()
    self.title_bar = TitleBar:new{
        width = self.dimen.w,
        align = "center",
        with_bottom_line = true,
        title = T(_("Vocabulary grid (%1/%2)"), self.page, self:totalPages()),
        left_icon = "appbar.menu",
        left_icon_tap_callback = function() self:onShowSettings() end,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    -- Bigger grids (more cells) get tighter padding/gaps and smaller text,
    -- smaller grids get more breathing room. Computed up-front so the
    -- toolbar buttons below can use the exact same padding as the tiles.
    local cell_count = self.rows * self.cols
    local h_gap, v_gap, tile_font_size
    if cell_count <= 12 then
        h_gap, v_gap, tile_font_size = Size.padding.large, Size.padding.large, 20
    elseif cell_count <= 24 then
        h_gap, v_gap, tile_font_size = Size.padding.default, Size.padding.default, 18
    elseif cell_count <= 48 then
        h_gap, v_gap, tile_font_size = Size.padding.small, Size.padding.small, 16
    else
        h_gap, v_gap, tile_font_size = Size.padding.small / 2, Size.padding.small / 2, 14
    end
    h_gap = math.max(h_gap, Size.border.thin * 2)
    v_gap = math.max(v_gap, Size.border.thin * 2)

    -- Toolbar: search current vocab, and dictionary-search-to-add.
    -- No icons, same padding rhythm as the grid tiles.
    local search_btn = Button:new{
        text = self.search_filter and self.search_filter ~= "" and
            T(_("Search: \"%1\" (tap to clear)"), self.search_filter) or _("Search vocab"),
        width = math.floor(self.dimen.w / 2) - h_gap * 1.5,
        padding_h = h_gap,
        padding_v = v_gap,
        callback = function() self:onSearchVocab() end,
    }
    local add_btn = Button:new{
        text = _("Dictionary / Add word"),
        width = math.floor(self.dimen.w / 2) - h_gap * 1.5,
        padding_h = h_gap,
        padding_v = v_gap,
        callback = function() self:onDictionarySearch() end,
    }
    local toolbar = HorizontalGroup:new{
        search_btn,
        HorizontalSpan:new{ width = h_gap },
        add_btn,
    }
    local toolbar_line = LineWidget:new{
        dimen = Geom:new{ w = self.dimen.w, h = Size.line.thick },
        background = Blitbuffer.COLOR_LIGHT_GRAY,
    }
    local toolbar_group = VerticalGroup:new{
        VerticalSpan:new{ width = v_gap },
        CenterContainer:new{
            dimen = Geom:new{ w = self.dimen.w, h = toolbar:getSize().h },
            toolbar,
        },
        VerticalSpan:new{ width = v_gap },
        toolbar_line,
    }
    local toolbar_height = toolbar_group:getSize().h

    -- Bottom nav bar height, reserved BEFORE laying out the grid so it
    -- never gets pushed off-screen.
    local nav_bar_height = Size.item.height_default + Size.padding.large * 2
    local content_h = self.dimen.h - self.title_bar:getHeight() - toolbar_height - nav_bar_height
    local content_w = self.dimen.w

    local h_margin = Size.padding.large
    local v_margin = Size.padding.default
    local available_w = content_w - h_margin * 2
    local available_h = content_h - v_margin * 2

    -- Generous reserved space (border + inner padding) per tile so the
    -- border can never get visually clipped by integer rounding.
    local tile_inner_pad = 2
    local tile_reserve = (Size.border.thin + tile_inner_pad) * 2

    local tile_w = math.floor((available_w - h_gap * (self.cols - 1)) / self.cols)
    local tile_h = math.floor((available_h - v_gap * (self.rows - 1)) / self.rows)

    local per_page = self:perPage()
    local start_idx = (self.page - 1) * per_page + 1

    local rows_group = VerticalGroup:new{}
    for r = 1, self.rows do
        local row_group = HorizontalGroup:new{}
        for c = 1, self.cols do
            local idx = start_idx + (r - 1) * self.cols + (c - 1)
            local word = self.words[idx]
            local tile
            if word then
                tile = FrameContainer:new{
                    width = tile_w,
                    height = tile_h,
                    padding = tile_inner_pad,
                    margin = 0,
                    bordersize = Size.border.thin,
                    color = Blitbuffer.COLOR_BLACK,
                    background = Blitbuffer.COLOR_WHITE,
                    radius = 0,
                    Button:new{
                        text = word,
                        text_font_size = tile_font_size,
                        width = tile_w - tile_reserve,
                        height = tile_h - tile_reserve,
                        max_width = tile_w - tile_reserve,
                        padding_h = 0,
                        padding_v = 0,
                        bordersize = 0,
                        callback = function() self:onTapWord(word) end,
                    },
                }
            else
                tile = Widget:new{
                    dimen = Geom:new{ w = tile_w, h = tile_h },
                }
            end
            table.insert(row_group, tile)
            if c < self.cols then
                table.insert(row_group, HorizontalSpan:new{ width = h_gap })
            end
        end
        table.insert(rows_group, row_group)
        if r < self.rows then
            table.insert(rows_group, VerticalSpan:new{ width = v_gap })
        end
    end

    -- Grid sits top-left of its area (not vertically centered), just
    -- horizontally centered if there's leftover width from rounding.
    local grid_area = TopContainer:new{
        dimen = Geom:new{ w = content_w, h = content_h },
        FrameContainer:new{
            padding = 0,
            bordersize = 0,
            margin = 0,
            HorizontalGroup:new{
                HorizontalSpan:new{ width = h_margin },
                VerticalGroup:new{
                    VerticalSpan:new{ width = v_margin },
                    rows_group,
                },
            },
        },
    }

    local page_label = Button:new{
        text = T(_("Page %1 / %2"), self.page, self:totalPages()),
        bordersize = 0,
        enabled = false,
        width = Screen:scaleBySize(160),
    }
    local prev_btn = Button:new{
        text = "‹ " .. _("Prev"),
        width = Screen:scaleBySize(110),
        enabled = self.page > 1,
        callback = function() self:gotoPage(self.page - 1) end,
    }
    local next_btn = Button:new{
        text = _("Next") .. " ›",
        width = Screen:scaleBySize(110),
        enabled = self.page < self:totalPages(),
        callback = function() self:gotoPage(self.page + 1) end,
    }
    local nav_line = LineWidget:new{
        dimen = Geom:new{ w = self.dimen.w, h = Size.line.thick },
        background = Blitbuffer.COLOR_LIGHT_GRAY,
    }
    local nav_row = HorizontalGroup:new{
        prev_btn,
        HorizontalSpan:new{ width = Size.padding.large },
        page_label,
        HorizontalSpan:new{ width = Size.padding.large },
        next_btn,
    }
    local nav_bar = VerticalGroup:new{
        nav_line,
        VerticalSpan:new{ width = Size.padding.default },
        nav_row,
    }

    local main_area = OverlapGroup:new{
        dimen = Geom:new{ w = self.dimen.w, h = self.dimen.h },
        VerticalGroup:new{
            self.title_bar,
            toolbar_group,
            grid_area,
        },
        BottomContainer:new{
            dimen = Geom:new{ w = self.dimen.w, h = self.dimen.h },
            nav_bar,
        },
    }

    self[1] = FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        main_area,
    }
end

function VocabGridWidget:gotoPage(page)
    if page < 1 or page > self:totalPages() then return end
    self.page = page
    self:refresh()
end

function VocabGridWidget:refresh(force_full)
    self.all_words = VocabGridDB:listWords()
    self:applyFilter()
    if self.page > self:totalPages() then self.page = self:totalPages() end
    self:buildLayout()
    UIManager:setDirty(self, force_full and "full" or "ui")
end

function VocabGridWidget:onSearchVocab()
    if self.search_filter and self.search_filter ~= "" then
        -- already filtered: tapping again clears it
        self.search_filter = nil
        self.page = 1
        self:refresh(true)
        return
    end
    local dialog
    dialog = InputDialog:new{
        title = _("Search vocabulary"),
        input_hint = _("Type part of a word"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog, "full") end,
            },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    self.search_filter = dialog:getInputText()
                    UIManager:close(dialog, "full")
                    self.page = 1
                    self:refresh(true)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Look a word up in the dictionary (new word, not necessarily in the grid
-- yet). Keeps vocabbuilder's own "Add to vocabulary builder" button intact
-- so the person can add it from there; refreshes the grid afterwards in
-- case it got added.
function VocabGridWidget:onDictionarySearch()
    local dialog
    dialog = InputDialog:new{
        title = _("Dictionary search"),
        input_hint = _("Type a word to look up"),
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog, "full") end,
            },
            {
                text = _("Look up"),
                is_enter_default = true,
                callback = function()
                    local word = dialog:getInputText()
                    UIManager:close(dialog, "full")
                    if word and word ~= "" then
                        active_grid_widget = self
                        active_grid_mode = "add"
                        self.ui:handleEvent(Event:new("LookupWord", word, true))
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function VocabGridWidget:onTapWord(word)
    active_grid_widget = self
    active_grid_mode = "remove"
    self.ui:handleEvent(Event:new("LookupWord", word, true))
end

-- Builds a "Portrait mosaic mode"-styled dialog: two spinner columns
-- (Columns / Rows) with up/down arrows, a value readout, a "Default
-- values: X / Y" line, and Close / Apply buttons.
function VocabGridWidget:onShowSettings()
    local cur_cols = self.cols
    local cur_rows = self.rows
    local dialog -- forward decl, closed/reopened on every spinner tap

    local function makeSpinnerColumn(label, get_value, on_up, on_down)
        local value_text = TextWidget:new{
            text = tostring(get_value()),
            face = Font:getFace("cfont", 24),
        }
        local up_btn = Button:new{
            text = "▲",
            width = Screen:scaleBySize(120),
            callback = on_up,
        }
        local down_btn = Button:new{
            text = "▼",
            width = Screen:scaleBySize(120),
            callback = on_down,
        }
        return VerticalGroup:new{
            TextWidget:new{
                text = label,
                face = Font:getFace("cfont", 20),
                bold = true,
            },
            VerticalSpan:new{ width = Size.padding.default },
            up_btn,
            VerticalSpan:new{ width = Size.padding.default },
            CenterContainer:new{
                dimen = Geom:new{ w = Screen:scaleBySize(120), h = value_text:getSize().h },
                value_text,
            },
            VerticalSpan:new{ width = Size.padding.default },
            down_btn,
        }
    end

    local function rebuild(is_spin_update)
        if dialog then UIManager:close(dialog) end

        local cols_col = makeSpinnerColumn(_("Columns"),
            function() return cur_cols end,
            function() cur_cols = math.min(cur_cols + 1, 10); rebuild(true) end,
            function() cur_cols = math.max(cur_cols - 1, 1); rebuild(true) end)

        local rows_col = makeSpinnerColumn(_("Rows"),
            function() return cur_rows end,
            function() cur_rows = math.min(cur_rows + 1, 14); rebuild(true) end,
            function() cur_rows = math.max(cur_rows - 1, 1); rebuild(true) end)

        local spinner_row = HorizontalGroup:new{
            cols_col,
            HorizontalSpan:new{ width = Size.padding.large * 2 },
            rows_col,
        }

        local defaults_text = TextWidget:new{
            text = T(_("Default values: %1 / %2"), DEFAULT_COLS, DEFAULT_ROWS),
            face = Font:getFace("cfont", 18),
        }

        local close_btn = Button:new{
            text = _("Close"),
            bordersize = 0,
            width = Screen:scaleBySize(160),
            callback = function()
                UIManager:close(dialog, "full")
            end,
        }
        local apply_btn = Button:new{
            text = _("Apply"),
            bordersize = 0,
            width = Screen:scaleBySize(160),
            callback = function()
                self.cols = cur_cols
                self.rows = cur_rows
                g_settings:saveSetting("cols", self.cols)
                g_settings:saveSetting("rows", self.rows)
                g_settings:flush()
                UIManager:close(dialog, "full")
                self.page = 1
                self:refresh(true)
            end,
        }
        local button_row = HorizontalGroup:new{
            close_btn,
            LineWidget:new{ dimen = Geom:new{ w = Size.line.thick, h = Size.item.height_default } },
            apply_btn,
        }

        local hline = LineWidget:new{
            dimen = Geom:new{ w = Screen:scaleBySize(420), h = Size.line.thick },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        }

        local body = VerticalGroup:new{
            TextWidget:new{
                text = _("Vocabulary grid layout"),
                face = Font:getFace("tfont", 22),
                bold = true,
            },
            VerticalSpan:new{ width = Size.padding.large },
            hline,
            VerticalSpan:new{ width = Size.padding.large },
            CenterContainer:new{
                dimen = Geom:new{ w = Screen:scaleBySize(420), h = spinner_row:getSize().h },
                spinner_row,
            },
            VerticalSpan:new{ width = Size.padding.large },
            hline,
            VerticalSpan:new{ width = Size.padding.default },
            defaults_text,
            VerticalSpan:new{ width = Size.padding.large },
            hline,
            CenterContainer:new{
                dimen = Geom:new{ w = Screen:scaleBySize(420), h = Size.item.height_default },
                button_row,
            },
        }

        dialog = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = Size.border.window,
            radius = Size.radius.window,
            padding = Size.padding.large,
            CenterContainer:new{
                dimen = Geom:new{ w = body:getSize().w, h = body:getSize().h },
                body,
            },
        }
        -- wrap in a full-screen centered modal
        dialog = CenterContainer:new{
            dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
            covers_fullscreen = false,
            dialog,
        }
        UIManager:show(dialog, is_spin_update and "ui" or "full")
    end

    rebuild(false)
end

function VocabGridWidget:onClose()
    UIManager:close(self)
    return true
end

----------------------------------------------------------------
-- Plugin entry point (menu registration) --
----------------------------------------------------------------
local VocabGrid = WidgetContainer:extend{
    name = "vocabgrid",
    is_doc_only = false,
}

function VocabGrid:init()
    self.ui.menu:registerToMainMenu(self)
end

function VocabGrid:addToMainMenu(menu_items)
    menu_items.vocabgrid = {
        text = _("Vocabulary grid"),
        callback = function()
            self:onShowGrid()
        end,
    }
end

function VocabGrid:onShowGrid()
    local widget = VocabGridWidget:new{
        ui = self.ui,
    }
    UIManager:show(widget)
    return widget
end

-- "remove" mode (tapped an existing tile): strips vocabbuilder's own
-- Add/Remove button and injects our own "Remove vocabulary" button.
-- "add" mode (used the dictionary-search toolbar button on a new word):
-- leaves vocabbuilder's own Add/Remove button alone so the person can add
-- the word normally. Either way, the grid refreshes once the popup closes.
function VocabGrid:onDictButtonsReady(dict_popup, buttons)
    if not active_grid_widget then return end
    if dict_popup.is_wiki_fullpage then return end

    local grid_ref = active_grid_widget
    local mode = active_grid_mode
    active_grid_widget = nil
    active_grid_mode = nil

    -- Always refresh the grid once this popup closes, regardless of how
    -- it gets closed (close button, back gesture, swipe, etc).
    local orig_onClose = dict_popup.onClose
    dict_popup.onClose = function(...)
        grid_ref:refresh(true)
        if orig_onClose then return orig_onClose(...) end
    end

    if mode == "remove" then
        for _, row in ipairs(buttons) do
            for i = #row, 1, -1 do
                if row[i].id == "vocabulary" then
                    table.remove(row, i)
                end
            end
        end

        local word = dict_popup.lookupword
        table.insert(buttons, 1, {{
            id = "vocabgrid_remove",
            text = _("Remove vocabulary"),
            font_bold = false,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = T(_("Remove \"%1\" from your vocabulary?"), word),
                    ok_text = _("Remove"),
                    ok_callback = function()
                        VocabGridDB:deleteWord(word)
                        UIManager:close(dict_popup)
                        UIManager:show(Notification:new{
                            text = T(_("Removed \"%1\""), word),
                        })
                    end,
                })
            end,
        }})
    end
    -- mode == "add": no button changes, vocabbuilder's own button handles it.
end

return VocabGrid