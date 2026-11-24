# Portable Characters (Project Zomboid, build 42)

Your characters are saved on your own PC instead of inside one world, so you can make a character
once and take it to any single-player world or multiplayer server, the way characters work in
RuneScape: Dragonwilds.

- **A character screen** comes up wherever the game used to start character creation: on a new
  game, on joining a server where you have no character, and after a death. Your characters are
  listed on the left with **Create New** under the list; the selected character is shown in the
  middle and its skills, traits and history on the right.
- **Pick a saved character** and you skip the profession-and-traits screen and go straight to the
  appearance screen, filled in with that character's last settings (name, body, hair, voice,
  clothes). Press Play and the character arrives with its skills, experience, traits, known
  recipes, books read, weight, kill count and injuries, and with what it was carrying and wearing
  if the world allows that.
- **Every character has its own name**, separate from the name in game, with as many words as you
  like. **Rename** and **Delete** are on the character screen.
- **Characters are saved about every 5 minutes**, when you leave through the menu, and on death.
- **Dead characters go to a Dead tab** instead of disappearing. The world's owner decides whether
  they can be revived. A revived character comes back healthy, with its skills and traits, without
  its things (those stayed on the body).

## What the world's owner decides

Three sandbox options, on the page **Portable Characters** (in the sandbox settings of a new game,
or in the server's settings):

| Option | Default | What it does |
|---|---|---|
| Allow characters from other worlds | on | Off: everyone starts with a new character here. It is still saved and can be taken elsewhere. |
| Characters bring their things | on | Off: a character from another world arrives with the usual starting things only. |
| Dead characters can be revived | off | On: a character on the Dead tab can be played again (needs the first option). |

In multiplayer the server checks these, not the player's game.

## What it needs

- Project Zomboid **build 42.22 or newer** (made and tried on 42.22.2).
- **In multiplayer the server and every player need the mod.** The server does the work of giving a
  character its skills and things, because build 42 does not let a player's own game do that.

## Install with Mod Loader

1. In [Mod Loader](https://github.com/MichaelRyan2319/ModLoader), add the game **Project Zomboid**.
   Mod Loader suggests the right mods folder by itself: `C:\Users\<you>\Zomboid\mods`.
2. Add the mod `MichaelRyan2319/ProjectZomboid-PortableCharacters`. Mod Loader installs it and keeps
   it up to date.
3. Turn it on in the game: main menu, **Mods**, tick **Portable Characters**.
4. For a server: add **Portable Characters** to the server's mods (Host, your server's settings,
   Mods; or `PortableCharacters` in the `Mods=` line of the server's `.ini`). The mod is not on the
   Steam Workshop, so leave `WorkshopItems=` as it is; each player installs it as above.

## Install by hand

Download `PortableCharacters.zip` from the
[latest release](https://github.com/MichaelRyan2319/ProjectZomboid-PortableCharacters/releases/latest)
and unzip it into `C:\Users\<you>\Zomboid\mods` (in Explorer: `%UserProfile%\Zomboid\mods`), so that
you get `Zomboid\mods\PortableCharacters\42\mod.info`. Then turn it on as in steps 3 and 4 above.

## Good to know

- **Where the characters are**: `C:\Users\<you>\Zomboid\Lua\PortableCharacters`. `roster.json` holds
  every character's name, look, skills and traits; each `data_<id>.json` holds one character's
  recipes and things. Copy the folder to back your characters up or move them to another PC.
- **A character you already have** (from before the mod, or in a world you load) is added to your
  characters the first time you play it with the mod on.
- **One character, several worlds**: a world keeps its own copy of the player, with its own
  position. When you come back to a world after playing the character somewhere else, the mod
  brings that world's copy up to date (skills, and things if the world allows it).
- **Injuries travel with the character**: scratches, cuts, deep wounds, burns, fractures, bandages,
  stitches and splints, and bites with the infection and how far along it is. A bitten character is
  bitten everywhere; the character screen shows its condition before you pick it.
- **Keys stay in their world.** A key, a key ring or a padlock only means something where its lock
  is, so it never leaves: it is still on the character when it comes back to that world, and a
  character arriving in a new world keeps that world's own key ring.
- **Things from mods** that the other world doesn't have are left behind, and the game tells you how
  many.
- With a saved character, the clothes on the appearance screen are what it wore when it was last
  made. If the world lets characters bring their things, the character then arrives in what it was
  actually wearing.
- Some finer details of items are rebuilt as well as the game allows a mod to: clothing patches come
  back at an average quality, and a mixed drink comes back as its parts. Carried animals stay where
  they are.
- The files on your PC are plain text. Somebody who edits them can give a character anything, so a
  server that cares about that should switch "Allow characters from other worlds" off.

## Uninstall

Turn the mod off in **Mods** (and take it out of the server's mods), then remove it in Mod Loader
or delete `Zomboid\mods\PortableCharacters`. Worlds keep working: every world still has its own copy
of your character. Your saved characters stay in `Zomboid\Lua\PortableCharacters` until you delete
that folder.

## What has been tried

On build 42.22.2, in single player and against a dedicated server with one player: creating a
character, the 5-minute and leave-the-game saves, death and the Dead tab, revive (allowed and not
allowed), taking a character with its things and its injuries (a bite with its infection, a
scratch, a bandaged deep wound, a splinted fracture) into a new world, coming back to a world it had
left, reconnecting after a server restart, keys staying behind, and a server that refuses transfers.
Not tried yet: a server
with several players at once, a controller, and other mods' creation screens.

## Development

`tests/test_roster.py` checks the character files' format without the game
(`python -m pip install lupa`, then `python tests/test_roster.py`).
The release file is built with
`git -c core.autocrlf=false archive --format=zip -o dist/PortableCharacters.zip HEAD PortableCharacters`.
