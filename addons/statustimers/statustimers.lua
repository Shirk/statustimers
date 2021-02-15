--[[
* statustimers - Copyright (c) 2021 Heals
*
* This file is part of statustimers for Ashita.
*
* statustimers is free software: you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.
*
* statustimers is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU General Public License for more details.
*
* You should have received a copy of the GNU General Public License
* along with statustimers.  If not, see <https://www.gnu.org/licenses/>.
--]]

addon.name      = 'statustimers';
addon.author    = 'heals';
addon.version   = '1.1.0';
addon.desc      = 'Replacement for the default status timer display';
addon.link      = 'https://github.com/Shirk/statustimers';

local common = require('common');
local bit = require('bit');

----------------------------------------------------------------------------------------------------
-- local constants
----------------------------------------------------------------------------------------------------

local MAX_STATUS = 32;
local ICON_RES_SIZE = 32;

local REALUTCSTAMP_ID = 'statustimers:realutcstamp';
local ICON_CONTAINER_ID = 'statustimers:icon_container';

local THEME_ICON_TEMPLATE = '%s\\themes\\%s\\%s.bmp';

----------------------------------------------------------------------------------------------------
-- local settings and ui objects
----------------------------------------------------------------------------------------------------

local default_settings = T{
    font = {
        family = 'Arial',
        size   = 10,
        color  = 0xFFFFFFFF,
    },

    icons = {
        size  = 24,
        theme = 'default',
        -- private:
        padding = 4,
    },

    layout = {
        rows  = 2,
        pos_x = 1,
        pos_y = 1,
        -- private:
        row_spacing = 4,
        col_spacing = 4,
    },
};

local settings = T{};

local ui = T{
    icon_container = nil,
    status_icons   = {},

    init_done      = false,
    last_update    = 0,
};

----------------------------------------------------------------------------------------------------
-- status_icon helper class
--
-- This class provides a convenient way for displaying a single status timer + icon at a designated
-- bar index as well as updating and hiding it depending on the assigned status id and duraction.
----------------------------------------------------------------------------------------------------

local status_icon_base = T{
    bar_index = -1,
    status_id = 0,
    duration  = 0,
    animation = 0,
    text = {
        id  = '',
        obj = nil,
        dim = nil,
    },
    icon = {
        id  = '',
        obj = nil,
    },
};

local status_icon_mt = {
    __index = status_icon_base,
    post_render = false,
};

local status_icon = {
    methods = status_icon_base,
};

--[[
* Sensible status_icon => string conversation
]]--
status_icon_mt.__tostring = function(self)
    return string.format('%s { bar_index: %d, status_id: %d, duration: %d, active: %s }',
        self.icon.id,
        self.bar_index,
        self.status_id,
        self.duration,
        self.text.obj:GetVisible()
    );
end

--[[
* Allocate and configure associated resources for thes icon.
* _This method is not meant to be called directly_.
*
* @param {self} - the status_icon
* @param {index} - the bar slot this icon will take (starting at 1)
]]--
status_icon_base.setup = function(self, index)
    self.bar_index = index - 1;

    self.icon.id  = string.format('statustimers:status_icon[%d]:icon', self.bar_index);
    self.icon.obj = AshitaCore:GetFontManager():Create(self.icon.id);
    self.icon.obj:SetAutoResize(false);

    self.text.id  = string.format('statustimers:status_icon[%d]:text', self.bar_index);
    self.text.obj = AshitaCore:GetFontManager():Create(self.text.id);
    self.text.obj:SetFontFamily(settings.font.family);
    self.text.obj:SetFontHeight(settings.font.size);
    self.text.obj:SetColor(settings.font.color);

    return self;
end

--[[
* Clean up all resources associated with this status_icon
*
* @param {self} - the status_icon
]]--
status_icon_base.release = function(self)
    AshitaCore:GetFontManager():Delete(self.icon.id);
    AshitaCore:GetFontManager():Delete(self.text.id);
end

--[[
* Returns the bounding box for this icon
*
* The bounding box is sized to contain both the background icon and the text
* taking the settings.icons.size as well as settings.font.size into account.
*
* @param {self} - the status_icon
]]--
status_icon_base.get_size = function (self)
    if (status_icon_mt.post_render == false) then
        error('status_icon:get_size called before the first render frame!');
    end

    if (self.text.dim == nil) then
        -- calculate the initial dimensions lazy
        self.text.dim = SIZE.new();
        self.text.obj:SetVisible(false);
        self.text.obj:SetText('99m');
        self.text.obj:GetTextSize(self.text.dim);
        self.text.obj:SetText('');
    end

    local size = SIZE.new()
    size.cx = math.max(settings.icons.size, self.text.dim.cx);
    size.cy = settings.icons.size + settings.icons.padding + self.text.dim.cy;

    return size;
end

--[[
* Returns the icons bar position based on it's index
*
* @param {self} - the status_icon
]]--
status_icon_base.get_bar_pos = function (self)
    local size = self:get_size();
    local res = SIZE.new();

    local row = math.floor(self.bar_index / (MAX_STATUS / settings.layout.rows));
    local col = math.floor(self.bar_index % (MAX_STATUS / settings.layout.rows));

    res.cx = (size.cx + settings.layout.col_spacing) * col;
    res.cy = (size.cy + settings.layout.row_spacing) * row;
    return res;
end

--[[
* Places this status_icon into a container and positions it accodring to it's index
*
* @param {self} - the status_icon
* @param {container} - a FontObject that will become the parent for this status_icon
]]--
status_icon_base.place = function (self, container)
    local pos = self:get_bar_pos();

    self.icon.obj:SetParent(container);
    self.icon.obj:SetPositionX(pos.cx);
    self.icon.obj:SetPositionY(pos.cy);
    self.icon.obj:SetLocked(true);

    self.text.obj:SetParent(container);
    self.text.obj:SetPositionX(pos.cx);
    self.text.obj:SetPositionY(pos.cy + settings.icons.size);
    self.text.obj:SetLocked(true);
end

--[[
* Updates the displayed status and duration (if needed)
*
* if status_id and duration are negative the status_icon will be hidden.
*
* @param {status_id} - the id of the status effect as used by FFXI
* @param {duration} - the remaining duration of the status effect (in seconds)
]]--
status_icon_base.update = function (self, status_id, duration)
    if (status_id == -1 or duration == -1) then
        -- disabled
        self.status_id = status_id;
        self.duration  = duration;

        self.icon.obj:SetVisible(false);
        self.text.obj:SetVisible(false);
        return true;
    end

    local pos = self:get_bar_pos();
    if (self.duration ~= duration) then
        -- label needs updating
        local label = '';
        local dim = SIZE.new();

        if (duration >= 3600) then
            label = string.format('%dh', duration / 3600);
        else
            if (duration >= 60) then
                label = string.format('%dm', duration / 60);
            else
                label = string.format('%d', duration + 1);
            end
        end

        self.duration = duration;
        self.text.obj:SetText(label);
        self.text.obj:SetVisible(true);
        self.text.obj:GetTextSize(dim);
        self.text.obj:SetPositionX(pos.cx + ((self:get_size().cx - dim.cx) / 2));
        self.text.obj:SetVisible(duration > 5);
    end

    if (self.status_id ~= status_id) then
        -- icon needs updating
        local scale = settings.icons.size / ICON_RES_SIZE;

        self.status_id = status_id;
        self.animation = 0;
        self:set_icon_from_theme(status_id);
        self.icon.obj:GetBackground():SetScaleX(scale);
        self.icon.obj:GetBackground():SetScaleY(scale);
        self.icon.obj:SetPositionX(pos.cx + ((self:get_size().cx - settings.icons.size) / 2));
        self.icon.obj:GetBackground():SetVisible(true);
        self.icon.obj:GetBackground():SetColor(0xFFFFFFFF);
        self.icon.obj:SetVisible(true);
    end

    return true;
end

--[[
* Update the items transparency animation (only has any effect for the last 15sec)
*
* @param {self} - the status_icon
]]--
status_icon_base.update_animation = function(self)
    if (self:is_active() == false) then
        return;
    end

    -- let's be a bit fancy for the last 15sec (this causes the icon to blink)
    if (self.duration <= 15) then
        local color = self.icon.obj:GetBackground():GetColor();
        local alpha = bit.rshift(color, 24);
        local delta = bit.lshift(15, 24);

        if (self.animation == 0) then
            if (alpha > 0x2F) then
                color = color - delta;
            else
                self.animation = 1;
            end
        elseif (self.animation == 1) then
            if (alpha < 0xFF) then
                color = color + delta;
            else
                self.animation = 0;
            end
        end

        self.icon.obj:GetBackground():SetColor(color);
    end
end

--[[
 * Set the displayed image for this icon based on the status_id.
 *
 * If the theme 'default' is specified the game resources will be used.
 *
 * If a custom theme is specified a two-stage lookup is performed:
 * - 1st check for '<addon.path>\\themes\\<icons.theme>\\<status_id>.bmp'
 * - 2nd check for '<addon.path>\\themes\\<icons.theme>\\0.bmp'
 *
 * Should either of these refer to a valid file on disk it will be used.
 * If neither of the two paths exists the game resources will be used.
 *
 * @param {self} - the status_icon
 * @param {status_id} - the status id as used by FFXI
]]--
status_icon_base.set_icon_from_theme = function(self, status_id)
    if (settings.icons.theme ~= 'default') then
        -- check for a custom icon theme
        local icon_path = string.format(THEME_ICON_TEMPLATE, addon.path, settings.icons.theme, status_id);
        local f = io.open(icon_path, 'rb');
        if (f ~= nil) then
            f:close();
        else
            -- the icon we're looking for doesn't exist, check for 0.bmp as fallback
            icon_path = string.format(THEME_ICON_TEMPLATE, addon.path, settings.icons.theme, 0);
            f = io.open(icon_path, 'rb');
            if (f ~= nil) then
                f:close();
            else
                icon_path = nil;
            end
        end

        if (icon_path ~= nil) then
            self.icon.obj:GetBackground():SetTextureFromFile(icon_path);
        end

        return;
    end

    -- no custom theme / no fallback, use the default icons
    local icon_data = AshitaCore:GetResourceManager():GetStatusIconById(status_id);
    if (icon_data ~= nil) then
        self.icon.obj:GetBackground():SetTextureFromMemory(icon_data.Bitmap, #icon_data.Bitmap, 0xFF000000);
    end
end

--[[
* Query if this icon is displaying an active status or not.
*
* @param {self} - the status_icon
]]--
status_icon_base.is_active = function(self)
    return (self.status_id ~= -1 and self.duration > 0);
end

--[[
* Wrapper to hit test both the image and label of this icon
*
* @param {self} - the status_icon
* @param {x} - the x coordinate to test for
* @param {y} - the y coordinate to test for
]]--
status_icon_base.hit_test = function(self, x, y)
    if (self:is_active()) then
        return self.text.obj:HitTest(x, y) or self.icon.obj:HitTest(x, y);
    end
    return false;
end

--[[
* Try to cancel this status effect by sending a Cancel package
*
* @param {self} - the status_icon
]]--
status_icon_base.try_cancel = function(self)
    if (self:is_active()) then
        local icon_data = AshitaCore:GetResourceManager():GetStatusIconById(self.status_id);
        if (icon_data.CanCancel == 1) then
            local status_hi = bit.rshift(self.status_id, 8);
            local status_lo = bit.band(self.status_id, 0xFF);

            AshitaCore:GetPacketManager():AddOutgoingPacket(0xF1, { 0x00, 0x00, 0x00, 0x00, status_lo, status_hi, 0x00, 0x00 });
        else
            print('status is not cancellable')
        end
    end
end

--[[
* Returns a new status_icon
*
* @param {index} - the bar index this icon is assigned to
]]--
status_icon.new = function (index)
    return setmetatable(status_icon_base:copy(true), status_icon_mt):setup(index);
end

----------------------------------------------------------------------------------------------------
-- config helpers
----------------------------------------------------------------------------------------------------

--[[
* Load an existing addon configuration and merge it with the provided defaults.
* Returns the a table containing the merged configuration.
*
* @param {defaults} - a table holding the default settings
]]--
local load_merged_settings = function(defaults)
    local config = AshitaCore:GetConfigurationManager();
    local ini_file = string.format('%s.ini', addon.name);
    local s = defaults:copy(true);
    if (config:Load(addon.name, ini_file)) then
        s.font.family  = config:GetString(addon.name, 'font',   'family', defaults.font.family);
        s.font.size    = config:GetUInt16(addon.name, 'font',   'size',   defaults.font.size);
        s.font.color   = config:GetString(addon.name, 'font',   'color',  string.format('0x%08x', defaults.font.color));
        s.font.color   = tonumber(s.font.color); -- required to parse hex strings
        s.icons.theme  = config:GetString(addon.name, 'icons',  'theme',  defaults.icons.theme);
        s.icons.size   = config:GetUInt16(addon.name, 'icons',  'size',   defaults.icons.size);
        s.layout.rows  = config:GetUInt16(addon.name, 'layout', 'rows',   defaults.layout.rows);
        s.layout.pos_x = config:GetUInt32(addon.name, 'layout', 'pos_x',  defaults.layout.pos_x);
        s.layout.pos_y = config:GetUInt32(addon.name, 'layout', 'pos_y',  defaults.layout.pos_y);
    end
    return s;
end

--[[
* Save the passed configuration table to disk.
*
* @param {data} - the updated settings to store in the addon's ini file
]]--
local save_settings = function(data)
    local config = AshitaCore:GetConfigurationManager();
    local ini_file = string.format('%s.ini', addon.name);

    config:Delete(addon.name, ini_file);
    config:SetValue(addon.name, 'font',   'family', data.font.family);
    config:SetValue(addon.name, 'font',   'size',   tostring(data.font.size));
    config:SetValue(addon.name, 'font',   'color',  string.format('0x%08x', data.font.color));
    config:SetValue(addon.name, 'icons',  'theme',  data.icons.theme);
    config:SetValue(addon.name, 'icons',  'size',   tostring(data.icons.size));
    config:SetValue(addon.name, 'layout', 'rows',   tostring(data.layout.rows));
    config:SetValue(addon.name, 'layout', 'pos_x',  tostring(data.layout.pos_x));
    config:SetValue(addon.name, 'layout', 'pos_y',  tostring(data.layout.pos_y));
    config:Save(addon.name, ini_file);
end

----------------------------------------------------------------------------------------------------
-- status id and duration helpers
----------------------------------------------------------------------------------------------------

--[[
* Return the current utc timestamp the game is using (from memory)
]]--
local get_real_utcstamp = function()
    local pointer = AshitaCore:GetPointerManager():Get(REALUTCSTAMP_ID);
    -- this needs to be dereferenced twice - thanks Thorny
    pointer = ashita.memory.read_uint32(pointer);
    pointer = ashita.memory.read_uint32(pointer);

    return ashita.memory.read_uint32(pointer + 0x0C);
end

--[[
* Return the current status id for the given index or -1 if no data is avilable.
*
* @param {index} - the status table index (starting at 1 up to MAX_STATUS)
]]--
local get_status_id = function(index)
    if (AshitaCore:GetMemoryManager() ~= nil) then
        if (AshitaCore:GetMemoryManager():GetPlayer() ~= nil) then
            local icon = AshitaCore:GetMemoryManager():GetPlayer():GetStatusIcons()[index];
            if (icon ~= nil) then
                return icon;
            end
        end
    end
    return -1;
end

--[[
* Return the remaining duration (in seconds) for the given status effect
* or -1 if no data is avilable.
*
* @param {index} - the status table index (starting at 1 up to MAX_STATUS)
]]--
local get_status_duration = function(index)
    if (AshitaCore:GetMemoryManager() ~= nil) then
        if (AshitaCore:GetMemoryManager():GetPlayer() ~= nil) then
            local vanabasestamp = 0x3C307D70;
            local timestamp = get_real_utcstamp();
            local raw_duration = AshitaCore:GetMemoryManager():GetPlayer():GetStatusTimers()[index];

            raw_duration = (raw_duration / 60) + 572662306 + vanabasestamp;
            if (raw_duration > timestamp and ((raw_duration - timestamp) / 3600) <= 99) then
                return raw_duration - timestamp;
            end
        end
    end
    return -1;
end

----------------------------------------------------------------------------------------------------
-- UI creation, setup, update and teardown
----------------------------------------------------------------------------------------------------

--[[
* Create the UI and allocate all required objects
]]--
local create_ui = function()
    for i = 1, MAX_STATUS, 1 do
        ui.status_icons[i] = status_icon.new(i);
    end

    ui.icon_container = AshitaCore:GetFontManager():Create(ICON_CONTAINER_ID);
    ui.icon_container:SetVisible(true);
    ui.icon_container:SetAutoResize(false);
    ui.icon_container:GetBackground():SetColor(0x00000000);
    ui.icon_container:GetBackground():SetVisible(true);
end

--[[
* Setup the UI objects and initial layout.
*
* These function must be called in or after the first render frame
* or the required size calculations will fail.
*
* Returns true on first call, false on any later call.
]]--
local setup_ui = function()
    if (ui.init_done == true) then
        return false;
    end

    status_icon_mt.post_render = true;

    for i = 1, MAX_STATUS, 1 do
        ui.status_icons[i]:place(ui.icon_container);
    end

    ui.icon_container:SetPositionX(settings.layout.pos_x);
    ui.icon_container:SetPositionY(settings.layout.pos_y);
    ui.init_done = true;
    return true;
end

--[[
* Update the active status icons.
*
* This function can be called at an arbitrary frequency to update the UI position.
* Status items will still only be updated once per second.
]]--
local update_ui = function()
    local perform_updates = false;
    local dimensions = nil;

    if (ui.last_update ~= os.clock()) then
        perform_updates = true;
        dimensions = SIZE.new();
    end

    for i = 1, MAX_STATUS, 1 do
        ui.status_icons[i]:update_animation();

        if (perform_updates == true) then
            ui.status_icons[i]:update(get_status_id(i), get_status_duration(i));

            if (ui.status_icons[i]:is_active()) then
                local pos = ui.status_icons[i]:get_bar_pos();
                local size = ui.status_icons[i]:get_size();

                dimensions.cx = math.max(dimensions.cx, pos.cx + size.cx);
                dimensions.cy = math.max(dimensions.cy, pos.cy + size.cy)
            end
        end
    end

    if (dimensions ~= nil) then
        -- update the container size to wrap only the visible status icons
        ui.icon_container:GetBackground():SetWidth(dimensions.cx);
        ui.icon_container:GetBackground():SetHeight(dimensions.cy);

        settings.layout.pos_x = ui.icon_container:GetPositionX();
        settings.layout.pos_y = ui.icon_container:GetPositionY();

        ui.last_update = os.clock();
    end
end

--[[
* Release the UI and all allocated objects relating to it.
]]--
local release_ui = function()
    for i = 1, MAX_STATUS, 1 do
        ui.status_icons[i]:release();
    end
    AshitaCore:GetFontManager():Delete(ICON_CONTAINER_ID);
end

--[[
* Try to cancel the status effect for the status icon at x,y.
* Returns true if an icon was found.
*
* @param {x} - the x coordinate of the hit test
* @param {y} - the y coordinate of the hit test
]]--
local try_cancel_status = function(x, y)
    local top_left = SIZE.new();
    local bot_right = SIZE.new();

    top_left.cx = ui.icon_container:GetPositionX();
    top_left.cy = ui.icon_container:GetPositionY();
    bot_right.cx = top_left.cx + ui.icon_container:GetBackground():GetWidth();
    bot_right.cy = top_left.cy + ui.icon_container:GetBackground():GetHeight();

    if (x >= top_left.cx and x <= bot_right.cx and
        y >= top_left.cy and y <= bot_right.cy) then
        for i = 1, MAX_STATUS, 1 do
            if (ui.status_icons[i]:hit_test(x, y)) then
                ui.status_icons[i]:try_cancel()
                return true;
            end
        end
    end
    return false;
end

----------------------------------------------------------------------------------------------------
-- Ashita addon callbacks
----------------------------------------------------------------------------------------------------

ashita.events.register('load', 'statustimers_load', function ()
    AshitaCore:GetPointerManager():Add(REALUTCSTAMP_ID, 'FFXiMain.dll', '8B0D????????8B410C8B49108D04808D04808D04808D04C1C3', 2, 0);

    if (AshitaCore:GetPointerManager():Get(REALUTCSTAMP_ID) == nil) then
        print('unable to locate required memory signatures');
        return false;
    end

    settings = load_merged_settings(default_settings);
    create_ui();
end);

ashita.events.register('unload', 'statustimers_unload', function ()
    release_ui();
    save_settings(settings);
    AshitaCore:GetPointerManager():Delete(REALUTCSTAMP_ID);
end);

ashita.events.register('mouse', 'statustimers_mouse', function (e)
    if (e.message == 0x205) then
        if (try_cancel_status(e.x, e.y)) then
            e.blocked = true;
        end
    end
end);

ashita.events.register('d3d_endscene', 'statustimers_endscene', function (isRenderingBackBuffer)
    if (isRenderingBackBuffer == false) then
        return
    end

    if (setup_ui() == false) then
        update_ui();
    end
end);
