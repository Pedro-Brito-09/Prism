--!strict
-- Minimal test harness. No dependencies or runner to install: require it,
-- declare groups and tests, call Report at the end.

const Harness = {}
Harness.__index = Harness

export type Suite = {
    Passed: number,
    Failed: number,
    Skipped: number,
    Group: string,
    Current: string,
    Errors: {string},
    Failures: {string},
    Skips: {string},
    SkipReason: string?,

    Describe: (self: Suite, Name: string) -> (),
    Test: (self: Suite, Name: string, Fn: () -> ()) -> (),
    Fail: (self: Suite, Message: string) -> (),
    Skip: (self: Suite, Reason: string) -> (),
    Eq: (self: Suite, Actual: any, Expected: any, What: string?) -> (),
    Ok: (self: Suite, Value: any, What: string?) -> (),
    Throws: (self: Suite, Fn: () -> (), What: string?) -> (),
    Eventually: (self: Suite, Check: () -> any, Timeout: number?, What: string?, Interval: number?) -> any,
    Report: (self: Suite) -> boolean,
}

const function Show(Value: any): string
    if typeof(Value) == "buffer" then
        return `buffer({buffer.len(Value)})`
    end

    return tostring(Value)
end

function Harness:Describe(Name: string)
    self.Group = Name
    print(`\n-- {Name}`)
end

function Harness:Test(Name: string, Fn: () -> ())
    self.Current = Name
    self.Errors = {}
    self.SkipReason = nil

    const Ok, Err = pcall(Fn)
    if not Ok then
        table.insert(self.Errors, `threw: {Err}`)
    end

    -- A test that recorded a failure and then skipped is still a failure. The
    -- skip used to be checked first and hid the error.
    if self.SkipReason and #self.Errors == 0 then
        self.Skipped += 1
        const Message = `[{self.Group}] {Name}: {self.SkipReason}`
        table.insert(self.Skips, Message)
        print(`  SKIP  {Name} ({self.SkipReason})`)
        return
    end

    if #self.Errors == 0 then
        self.Passed += 1
        print(`  PASS  {Name}`)
        return
    end

    self.Failed += 1
    print(`  FAIL  {Name}`)
    for _, Message in self.Errors do
        print(`          {Message}`)
        table.insert(self.Failures, `[{self.Group}] {Name}: {Message}`)
    end
end

function Harness:Fail(Message: string)
    table.insert(self.Errors, Message)
end

function Harness:Skip(Reason: string)
    self.SkipReason = Reason
end

function Harness:Eq(Actual: any, Expected: any, What: string?)
    if Actual ~= Expected then
        self:Fail(`{What or "value"}: expected {Show(Expected)}, got {Show(Actual)}`)
    end
end

function Harness:Ok(Value: any, What: string?)
    if not Value then
        self:Fail(`{What or "value"}: expected truthy, got {Show(Value)}`)
    end
end

function Harness:Throws(Fn: () -> (), What: string?)
    if (pcall(Fn)) then
        self:Fail(`{What or "call"}: expected an error, none raised`)
    end
end

function Harness:Eventually(Check: () -> any, Timeout: number?, What: string?, Interval: number?): any
    const Deadline = os.clock() + (Timeout or 5)
    local Last = "false"

    repeat
        const Ok, Result = pcall(Check)
        if Ok and Result then
            return Result
        end

        Last = if Ok then Show(Result) else `error: {Result}`
        task.wait(Interval or 0.05)
    until os.clock() >= Deadline

    self:Fail(`{What or "condition"}: timed out (last result: {Last})`)
    return nil
end

function Harness:Report(): boolean
    const Total = self.Passed + self.Failed + self.Skipped
    print(`\n{string.rep("=", 56)}`)
    print(`  {self.Passed}/{Total} passed, {self.Failed} failed, {self.Skipped} skipped`)

    if self.Failed > 0 then
        print(`\n  Failures:`)
        for _, Failure in self.Failures do
            print(`    {Failure}`)
        end
    end

    print(`{string.rep("=", 56)}\n`)
    return self.Failed == 0
end

function Harness.new(): Suite
    return setmetatable({
        Passed = 0,
        Failed = 0,
        Skipped = 0,
        Group = "",
        Current = "",
        Errors = {},
        Failures = {},
        Skips = {},
        SkipReason = nil,
    }, Harness) :: any
end

return Harness
