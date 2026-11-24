"""Checks the character files' format and the roster logic without the game.

Needs lupa (python -m pip install lupa). Run: python tests/test_roster.py
The game's file and time functions are replaced by small stand-ins; the mod's own Lua files are
loaded as they are.
"""
import os
import sys

from lupa import LuaRuntime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUA = os.path.join(ROOT, "PortableCharacters", "42", "media", "lua")

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute(r'''
PortableCharacters = nil
function isServer() return false end
function isClient() return false end
local stamp = 1000
function getTimestamp() stamp = stamp + 1 return stamp end
function getTimestampMs() stamp = stamp + 1 return stamp * 1000 end
function ZombRand(a, b) return a end
FILES = {}
function getFileWriter(name, create, append)
  local buf = {}
  return { write = function(self, s) buf[#buf+1] = s end, close = function(self) FILES[name] = table.concat(buf) end }
end
function getFileReader(name, create)
  local text = FILES[name]
  if not text then return nil end
  local lines, i = {}, 0
  for line in string.gmatch(text, "[^" .. string.char(10) .. "]+") do lines[#lines+1] = line end
  return { readLine = function(self) i = i + 1 return lines[i] end, close = function() end }
end
function require(name) return true end
''')
for part in ("shared/PortableCharacters/PC_Core.lua", "shared/PortableCharacters/PC_Json.lua",
             "client/PortableCharacters/PC_Roster.lua"):
    with open(os.path.join(LUA, part), encoding="utf-8") as f:
        lua.execute(f.read())

out = lua.execute(r'''
local J = PortableCharacters.Json
local R = PortableCharacters.Roster
local results = {}
local function check(name, cond) results[#results+1] = (cond and "ok   " or "FAIL ") .. name end
local NL, Q, BS = string.char(10), string.char(34), string.char(92)
local tricky = "x" .. Q .. "y" .. BS .. "z" .. NL .. "end"
local sample = { a = 1, b = tricky, c = { 1, 2, 3 }, d = { k = true, f = false, n = 1.5 }, e = {}, big = 123456789012, neg = -3.25, uni = "héllo – ok" }
local text = J.encode(sample)
local back = J.decode(text)
check("round trip number", back.a == 1 and back.big == 123456789012 and back.neg == -3.25 and back.d.n == 1.5)
check("round trip string", back.b == sample.b and back.uni == sample.uni)
check("round trip array", #back.c == 3 and back.c[3] == 3)
check("round trip bool", back.d.k == true and back.d.f == false)
check("empty table", type(back.e) == "table" and next(back.e) == nil)
check("int has no dot", string.find(text, Q .. "a" .. Q .. ":1[,}]") ~= nil)
check("one line", string.find(text, NL, 1, true) == nil)
check("bad json gives nil", J.decode("{oops") == nil and J.decode("") == nil)
check("whitespace", J.decode(' { "x" : [ 1 , 2 ] } ').x[2] == 2)
check("control char", J.decode(J.encode({ s = "a" .. string.char(1) .. "b" })).s == "a" .. string.char(1) .. "b")
check("nested", J.decode(J.encode({ items = { { t = "Base.Axe", items = { { t = "Base.Nails", u = 3 } } } } })).items[1].items[1].u == 3)

local c1 = R.create("  Zaeto the Wise  ", { forename = "Bob", surname = "Smith", perks = { Woodwork = { l = 3, x = 10 } } }, { recipes = { "A" } })
local c2 = R.create(nil, { forename = "Ann", surname = "Lee" }, {})
check("label trimmed", c1.label == "Zaeto the Wise")
check("label falls back to name", c2.label == "Ann Lee")
check("ids differ", c1.id ~= c2.id)
check("two living", R.count(false) == 2 and R.count(true) == 0)
R.rename(c1.id, "New Name With Many Words")
local rev = R.update(c1.id, { forename = "Bob", surname = "Smith", perks = { Woodwork = { l = 4, x = 99 } } }, { recipes = { "A", "B" } })
check("rev counts up", rev == 2)
R.markDead(c2.id, { hours = 5 })
check("dead tab", R.count(false) == 1 and R.count(true) == 1)
R.markAlive(c2.id)
check("revived", R.count(false) == 2 and R.count(true) == 0)
R.markDead(c2.id, { hours = 5 })
R.load(true)
local again = R.get(c1.id)
check("reload keeps name", again and again.label == "New Name With Many Words" and again.rev == 2)
check("reload keeps skills", again.snap.perks.Woodwork.l == 4)
check("reload keeps dead", R.get(c2.id).dead == true)
check("data file", #R.loadData(c1.id).recipes == 2)
check("total level", PortableCharacters.totalLevel(again.snap) == 4)
R.delete(c1.id)
R.load(true)
check("deleted", R.get(c1.id) == nil and next(R.loadData(c1.id)) == nil)
FILES["PortableCharacters/roster.json"] = "{broken"
R.load(true)
check("broken roster copied aside", FILES["PortableCharacters/roster_unreadable.json"] == "{broken")
return table.concat(results, NL)
''')
print(out)
sys.exit(1 if "FAIL" in out else 0)
