--!strict
-- Size limits that depend on each other, kept in one place so that raising one
-- cannot leave the other behind.
--
-- A scene commit is the largest single argument a client sends, and the server
-- turns away any packet over MAX_PACKET_BYTES before decoding it. If the commit
-- cap grew past the packet cap, a commit inside its own limit would be dropped
-- whole, with nothing to say why.

const Limits = {}

-- What one scene commit may carry. Decoding walks the buffer and does nothing
-- else until it is through, so this is what bounds the work a commit costs.
Limits.MAX_COMMIT_BYTES = 524288

-- The largest packet the server decodes from a client: twice a full commit, so
-- the commit and the channel id, lengths and other arguments around it always
-- fit.
Limits.MAX_PACKET_BYTES = Limits.MAX_COMMIT_BYTES * 2

return table.freeze(Limits)
