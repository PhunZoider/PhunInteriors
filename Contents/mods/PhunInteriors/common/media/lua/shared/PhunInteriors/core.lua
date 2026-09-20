PhunInteriors = {
    name = "PhunInteriors",
    consts = {
        -- key we hang our own state off, on both vehicles and the global ModData
        modDataKey = "PhunInteriors",
        vehicleIdKey = "PhunInteriors_id",
        -- the same durable id for a world object holding a lease. It lives
        -- inside modData.movableData rather than at the top level; holders.lua
        -- says why, and the reason is that vanilla drops a top level key on
        -- pickup for some classes and not others.
        objectIdKey = "PhunInteriors_objectId",
        -- Why a leased world object must not be packed away: "occupied" or
        -- "contents", and absent when it may be. It lives beside the id, for
        -- the same reason, and carries the same caveat: it is a HINT, read by
        -- the client so a pickup can be refused pleasantly, and never the
        -- authority. The authority is Slots.lockReason, server side, and a
        -- stale flag heals itself the next time anybody enters or leaves.
        objectLockKey = "PhunInteriors_objectLock",
        -- set once a vehicle has held a room, so losing one can be reported
        leasedKey = "PhunInteriors_leased",
        massDeltaKey = "PhunInteriors_massDelta",
        -- object modData flag on a rain barrel a kit put up, so capture can
        -- tell it from a barrel the map author built
        reservoirKey = "PhunInteriors_reservoir",
        -- the item consumed by installing one
        reservoirItem = "PhunInteriors.RainReservoirKit",
        -- Where a tenant was standing when they went in, on the PLAYER.
        --
        -- The last resort of the three return positions, and the only one that
        -- outlives the lease -- which is the whole reason it exists. A lease
        -- says where the HOLDER is, and the tracker keeps that current because
        -- a van moves; this says where THIS VISIT began. Different facts, and
        -- this one is per player rather than per room: several tenants can be
        -- in one room having walked in from somewhere else each, so there is
        -- no single value of it a lease could ever have carried.
        --
        -- Player modData rather than our own store, and the asymmetry with the
        -- vehicle row in CLAUDE.md is the point. IsoPlayer.save reaches
        -- IsoMovingObject.save, which writes the modData KahluaTable into the
        -- character record, so this survives a restart, a reclaim, and the
        -- loss of global_mod_data.bin. A vehicle's modData survives none of
        -- that and is not even transmitted.
        entranceKey = "PhunInteriors_entrance"
    },
    data = {},
    commands = {
        playerSetup = "playerSetup",
        enter = "enter",
        -- client -> server: "put me inside the thing standing here". Carries a
        -- square and nothing else; the server reads the object off it, the
        -- same way the vehicle path names a position rather than an identity.
        enterObject = "enterObject",
        leave = "leave",
        teleport = "teleport",
        notify = "notify",
        admin = "admin",
        adminResult = "adminResult",
        -- client -> server and back: the admin room list. Separate from
        -- adminResult, which carries lines meant for a log, because this one
        -- carries a structure meant for a window and nothing should have to
        -- guess which it received.
        rooms = "rooms",
        roomsResult = "roomsResult",
        -- One room's slots and its shipped values, fetched when a row is
        -- selected rather than sent with the list.
        --
        -- The list used to carry every slot of every room, which was 120 slots
        -- on a two room map and is 960 across 81 rooms now. That payload
        -- crosses sendServerCommand on every refresh, and all but one room's
        -- worth of it is drawn by nothing. Splitting it also means the form can
        -- be given the SHIPPED values to show a field as customised, which
        -- would have been another copy of every room in the list payload.
        roomSlots = "roomSlots",
        roomSlotsResult = "roomSlotsResult",
        -- Editing. Each carries what changed and nothing else; the server
        -- re-checks admin rights and re-validates every field, because the
        -- window is an entry point and never a gate.
        editRoom = "editRoom",
        editBinding = "editBinding",
        author = "author",
        -- server -> client, so a reconnecting player learns they are inside
        state = "state",
        -- client -> server: "the vehicle with this id just moved, go and look
        -- at it". Deliberately carries no coordinates; see Transit.notePosition.
        updatePosition = "updatePosition",
        -- client -> server: "I have landed back outside, and this is the id of
        -- the vehicle I found there". Closes the exit handshake.
        arrived = "arrived",
        -- client -> server: "an admin is about to remove the vehicle with this
        -- id". A warning, not a claim; see Removal.watch.
        vehicleRemoving = "vehicleRemoving",
        -- client -> server: "put the reservoir from this kit on my roof".
        -- Carries the kit's item id and nothing else; which room is read off
        -- the occupancy.
        installReservoir = "installReservoir"
    },
    events = {
        -- Where third party mods register, in two phases: rooms first, then
        -- the vehicles that may use them.
        --
        -- Events rather than a "is PhunInteriors loaded yet" test on their
        -- side. If we are not installed they never fire and the registration
        -- never runs, so nobody has to guess how far through booting we are.
        --
        -- The split is a convention, not a constraint -- registering anything
        -- on either one works, because the indexes rebuild on first read. What
        -- it buys is a point at which the room sets are known to be complete,
        -- which is the only way to tell "that set has not registered yet" from
        -- "the mod that owns it is not installed". Before the split those were
        -- the same silence.
        --
        -- What it does NOT buy is load order independence. That comes from the
        -- author declaring the event themselves before adding to it; see the
        -- snippet in CLAUDE.md.
        OnRegisterRooms = "PhunInteriorsOnRegisterRooms",
        OnRegisterVehicles = "PhunInteriorsOnRegisterVehicles",
        OnReady = "PhunInteriorsOnReady",
        OnEnter = "PhunInteriorsOnEnter",
        OnExit = "PhunInteriorsOnExit",
        -- Client side: a fresh picture of the registry has arrived from the
        -- server. Every open editor panel re-reads on it, so a change made in
        -- one panel -- or by another admin, on a server -- shows up without
        -- anybody reopening a window. The alternative is each panel refreshing
        -- only what it thinks it changed, which is how two views of one
        -- registry come to disagree.
        OnRegistryChanged = "PhunInteriorsOnRegistryChanged"
    },
    -- registry, populated by registry.lua and by other mods on the register events
    -- rooms: id -> one room design and every place it is stamped
    -- bindings: id -> which scripts may lease which rooms
    rooms = {},
    bindings = {},
    -- optional shipped blueprints, keyed by room id. Nothing emits one by
    -- default any more; runtime capture in manifest.lua is the normal source.
    blueprints = {},
    -- What the admin editor has changed, read from PhunInteriors.json in the
    -- game's Lua folder. Sparse: a room entry names only the fields that
    -- differ from the registration, so a room the editor has never touched is
    -- absent rather than present and identical. See overrides.lua.
    overrides = {
        rooms = {},
        bindings = {}
    },
    -- Set by an edit, cleared by a write to disk. There is deliberately no
    -- autosave: an edit applies to the live registry immediately, because that
    -- is the loop the editor exists for, but it reaches the file only when
    -- somebody says so. A mistake that is still in memory is undone by Revert
    -- or by a restart; a mistake already on disk has to be undone by hand.
    unsavedEdits = false,
    -- The definition each room was FIRST registered with, deep copied before
    -- any override is applied. This is what "revert" rebuilds from, and it is
    -- the raw def rather than the built room because applying an override
    -- re-runs registerRoom on a merged def -- which is how a locations edit
    -- gets its slots, indices and count re-derived by the one piece of code
    -- that knows how, instead of by a second copy of that arithmetic here.
    roomDefs = {},
    -- derived: lowercased script name -> {bindingId = true}, rebuilt lazily
    scriptLookup = {},
    -- server side only: username -> occupancy record
    occupants = {},
    settings = {},
    ui = {},
    modules = {}
}

local Core = PhunInteriors

Core.isLocal = not isClient() and not isServer() and not isCoopHost()

for _, event in pairs(Core.events) do
    if not Events[event] then
        LuaEventManager.AddEvent(event)
    end
end

--- Open registration: rooms, then the vehicles that may use them.
--
-- Guarded, because in single player both server_events and client_events load
-- and each fires the boot sequence, so without this every handler -- ours and
-- every third party's -- runs twice. That is mostly harmless, since the
-- register calls replace rather than accumulate, but it logs "is being
-- redefined" for every set on every SP boot, which makes a warning that ought
-- to mean something into noise nobody reads.
function Core.openRegistration()
    if Core.registrationFired then
        return false
    end
    Core.registrationFired = true
    triggerEvent(Core.events.OnRegisterRooms, Core)
    triggerEvent(Core.events.OnRegisterVehicles, Core)
    return true
end

-- Every constraint this mod imposes is a switch, and the defaults are the
-- balanced ones. An admin who wants the old power fantasy turns them off.
Core.defaults = {
    Debug = false,
    WeightFactor = 50,
    ExitTax = true,
    ExitTaxGrowth = 2,
    EntryDelay = 15,
    EntryBlockedByZombies = true,
    EntryZombieRadius = 4,
    ExitShoveRadius = 6,
    RoomProtectedDays = 14,
    ScrubKeepsLoot = false,
    HardenShell = true,
    BreachEjects = true,
    AdminNoClipExempt = true,
    PowerBinding = true,
    PowerDrainFactor = 100,
}

function Core.getOption(name, default)
    local opt = getSandboxOptions():getOptionByName(Core.name .. "." .. name)
    local val = opt and opt:getValue()
    if val == nil then
        return default
    end
    return val
end

function Core.refreshSettings()
    for name, default in pairs(Core.defaults) do
        Core.settings[name] = Core.getOption(name, default)
    end
    return Core.settings
end

function Core.debugLn(str)
    if Core.settings.Debug then
        print("[" .. Core.name .. "] " .. tostring(str))
    end
end

function Core.logLn(str)
    print("[" .. Core.name .. "] " .. tostring(str))
end

-- Client -> server. In single player there is no round trip, so call the
-- handler directly. This is what keeps SP and MP on one code path.
function Core.dispatch(command, args)
    if Core.isLocal then
        local handlers = require "PhunInteriors/server_commands"
        local handler = handlers[command]
        if handler then
            handler(getPlayer(), args or {})
        end
    else
        sendClientCommand(Core.name, command, args or {})
    end
end

-- Server -> client, same deal in reverse.
function Core.respond(player, command, args)
    if Core.isLocal then
        local handlers = require "PhunInteriors/client_commands"
        local handler = handlers[command]
        if handler then
            handler(args or {})
        else
            Core.logLn("no local client handler for '" .. tostring(command) .. "'")
        end
    else
        sendServerCommand(player, Core.name, command, args or {})
    end
end

function Core.playerKey(player)
    if not player then
        return nil
    end
    return player:getUsername() or tostring(player:getOnlineID())
end

--- The lease key for an admin standing in a room without a vehicle.
--
-- Namespaced so it cannot collide with a vehicle's: every real one is a
-- getRandomUUID string, and none of those contain a colon.
--
-- Here rather than on Transit, which is where both of these started, because
-- Slots.release has to ask the question and transit.lua requires slots.lua.
-- Reaching back the other way for a pure string test would have made the cycle
-- real and load-order dependent for no gain. The key format belongs beside
-- playerKey, which is what it is built from.
function Core.adminKey(player)
    return "admin:" .. tostring(Core.playerKey(player))
end

--- Is this lease an admin port rather than a vehicle's?
function Core.isAdminLease(vehicleId)
    return type(vehicleId) == "string" and string.sub(vehicleId, 1, 6) == "admin:"
end

-- Vehicles get a stable id of our own. getId() is not durable across restarts
-- in every configuration, and we need something we can key a lease on.
function Core.vehicleId(vehicle, create)
    if not vehicle then
        return nil
    end
    local vmd = vehicle:getModData()
    if not vmd[Core.consts.vehicleIdKey] and create then
        vmd[Core.consts.vehicleIdKey] = tostring(getRandomUUID())
    end
    return vmd[Core.consts.vehicleIdKey]
end

--- Find a loaded vehicle by our own durable id, near a position.
--
-- getVehicleById cannot do this: BaseVehicle:getId() is assigned when a
-- vehicle enters the world, and one that unloads and reloads comes back with
-- a different id. The modData UUID is written into the save, so it is the
-- only handle that survives, and a vehicle whose chunk just streamed in is
-- exactly the case both sides care about -- the client re-seating a player,
-- the server charging a vehicle for what its interior holds.
function Core.vehicleNear(x, y, z, vehicleId, radius)
    local cell = getCell()
    if not cell or not vehicleId then
        return nil
    end
    radius = radius or 3
    for dx = -radius, radius do
        for dy = -radius, radius do
            local square = cell:getGridSquare(x + dx, y + dy, z)
            local vehicle = square and square:getVehicleContainer()
            if vehicle and Core.vehicleId(vehicle, false) == vehicleId then
                return vehicle
            end
        end
    end
    return nil
end

--- The vehicle nearest a position, whatever it is.
--
-- Used client side on the way out of a room, where the question is not "which
-- vehicle is mine" but "which vehicle is at the spot the server just sent me
-- to". The server has already resolved identity -- it holds the lease and it
-- read the position itself -- so the client only has to do the geometry, and
-- it reports the id it found back up so the server can verify before acting
-- on it.
--
-- This is why nothing here needs the modData UUID. Vehicle level modData is
-- never transmitted to clients (BaseVehicle carries no sync path for it, only
-- transmitPartModData), so a client side UUID match can never succeed on a
-- dedicated server.
function Core.nearestVehicle(x, y, z, radius)
    local cell = getCell()
    if not cell then
        return nil
    end
    radius = radius or 3
    local best, bestDistance = nil, nil
    for dx = -radius, radius do
        for dy = -radius, radius do
            local square = cell:getGridSquare(x + dx, y + dy, z)
            local vehicle = square and square:getVehicleContainer()
            if vehicle then
                local distance = (dx * dx) + (dy * dy)
                if not bestDistance or distance < bestDistance then
                    best, bestDistance = vehicle, distance
                end
            end
        end
    end
    return best
end

function Core.now()
    return getGameTime():getWorldAgeHours()
end

Core.refreshSettings()

Events.EveryTenMinutes.Add(function()
    Core.refreshSettings()
end)

return Core
