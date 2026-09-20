if isServer() then
    return
end
require "PhunInteriors/core"
local Core = PhunInteriors

-- ---------------------------------------------------------------------------
-- The client's copy of what the server last said about the registry.
--
-- One cache, read by every editor panel, written only by the roomsResult
-- handler. The registry exists client side too -- rooms and bindings are
-- registered on both halves -- and this is deliberately NOT that: who holds
-- which slot, which fields an admin has patched, and whether the file on disk
-- is behind all live on the server and cannot be derived here. A panel drawing
-- half its rows from the local registry and half from the payload would
-- disagree with itself the moment anything changed.
--
-- It also backs Core.isShippedKey and Core.isOverriddenKey, which is the
-- contract the vendored list panel asks for. Those are the three-state
-- question -- stock, modified, custom -- that draws the stripe down the left
-- of every row.
-- ---------------------------------------------------------------------------

local State = {}
Core.ui.state = State

-- The last roomsResult payload, or nil before the first one arrives.
State.registry = nil
-- roomId -> the last roomSlotsResult for it. Kept per room rather than as a
-- single "current" record so that clicking back to a room already looked at
-- draws immediately instead of blanking while a second request flies.
State.detail = {}

--- Take a fresh payload and tell every open panel.
function State.receive(payload)
    State.registry = payload
    -- Detail is invalidated wholesale: a room's slot states are exactly what a
    -- refresh is likely to have changed, and a panel showing a stale lease
    -- beside a fresh room row is worse than one showing nothing for a moment.
    State.detail = {}
    triggerEvent(Core.events.OnRegistryChanged, payload)
end

function State.receiveDetail(payload)
    if payload and payload.room then
        State.detail[payload.room] = payload
    end
    triggerEvent(Core.events.OnRegistryChanged, State.registry)
end

--- The room row for `id`, out of the last payload.
function State.room(id)
    for _, room in ipairs(State.registry and State.registry.rooms or {}) do
        if room.id == id then
            return room
        end
    end
    return nil
end

function State.binding(id)
    for _, binding in ipairs(State.registry and State.registry.bindings or {}) do
        if binding.id == id then
            return binding
        end
    end
    return nil
end

--- Was this row registered by lua, as opposed to invented in the editor?
---
--- The name and the two-function shape come from PhunMart, because the
--- vendored list panel calls them: together they give three states rather than
--- two, and the third -- a definition that exists only because an admin made
--- it -- is the one worth marking differently, since nothing will bring it
--- back if the file is deleted.
function Core.isShippedKey(kind, key)
    if kind == "rooms" then
        local room = State.room(key)
        return room ~= nil and room.state ~= "new"
    elseif kind == "bindings" then
        local binding = State.binding(key)
        -- A binding made in the editor is reported by the server with a source
        -- of PhunInteriors.json; anything else was registered by somebody's
        -- lua. There is no `state = "new"` for bindings because a binding has
        -- no shipped definition to diff against -- it is replaced whole.
        return binding ~= nil and binding.source ~= "PhunInteriors.json"
    end
    return true
end

--- Has this row been edited away from what its lua registered?
function Core.isOverriddenKey(kind, key)
    if kind == "rooms" then
        local room = State.room(key)
        return room ~= nil and room.state == "overridden"
    elseif kind == "bindings" then
        local binding = State.binding(key)
        return binding ~= nil and binding.state == "overridden"
    end
    return false
end

-- ---------------------------------------------------------------------------
-- The cross-reference feature, switched off.
--
-- The vendored list panel can show "used by" for a definition other
-- definitions point at, which in PhunMart is a genuine graph -- a price used
-- by items used by pools used by shops. Here the graph is one edge deep, from
-- a binding to a room, and the room list already prints every script that
-- reaches it, so the feature would be a second way to read one column.
--
-- Stubbed rather than deleted from the panel, so the vendored file stays a
-- near-verbatim copy that a later fix can be dropped onto. canBeReferenced
-- answering false is the switch: showsReferences short circuits on it and
-- nothing else in the feature is reached.
-- ---------------------------------------------------------------------------
Core.references = {
    canBeReferenced = function()
        return false
    end,
    find = function()
        return {}
    end,
    summarise = function()
        return ""
    end
}

return State
