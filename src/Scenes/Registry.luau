--!strict
-- Where the live scenes are kept, and nothing else.
--
-- Objects has to find a scene to place a new object in, and to resolve a handle
-- back to the scene holding it. Scenes has to build objects. Each requiring the
-- other is a cycle, so the table they share sits on its own and requires
-- nothing -- which is also why the scene type is loose here: naming it would
-- pull Scenes/Types back in and rebuild the cycle one level up.

return {
    ById = {} :: {[number]: any},
    ByName = {} :: {[string]: any},

    -- By the id a scene is saved under, which outlives the session where the
    -- other two do not.
    ByGuid = {} :: {[string]: any},

    -- Every live copy across every scene, keyed by its own id. Kept flat rather
    -- than reached through the scene holding it because a caller naming a copy
    -- -- a transaction says which copy each object it creates belongs in --
    -- resolves one per operation, and walking every scene's copies to answer
    -- would make that cost the size of the world.
    Instances = {} :: {[number]: any},

    -- Set by Scenes/Server as it registers the implicit scene. Objects.new with
    -- no scene of its own lands here, which is what keeps plain object creation
    -- working exactly as it did before scenes existed.
    Default = (nil :: any) :: any,
}
