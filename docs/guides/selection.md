# Selection

Client side, and purely local: the server never hears about it. Entries are
pruned on read, so an object destroyed by someone else drops out on its own.

```luau
-- client
Prism.Selection:Set({objectA, objectB})
Prism.Selection:Add(runtimeId)
Prism.Selection:Contains(objectA)

local disconnect = Prism.Selection:OnChange(function(selected)
    panel:Render(selected)
end)
```

`Get` returns the selected objects in the order they were added, which is the
order an editor reads as "the active one is last". `Query(fn)` filters that
list.
